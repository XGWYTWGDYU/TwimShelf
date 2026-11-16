// LAN sync: the account key (in the data folder's secrets, as the Flutter app kept it), the core's
// listener, and the core's discovery, which finds the account's other devices and syncs with them.
using Microsoft.UI.Dispatching;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Models;

public sealed class SyncModel
{
#if DEBUG
    // a test build never pairs with (or syncs into) the user's real devices
    public const string ServiceType = "_twlib-debug._tcp";
#else
    public const string ServiceType = "_twlib._tcp";
#endif
    const string KeyName = "sync.key";

    public event Action? Changed;
    /// Another device's changes arrived: the library reloads, without telling the others again.
    public event Action? RemoteChanges;

    public SyncStatus? Status { get; private set; }
    public DiscoveryStatus? Discovery { get; private set; }
    public string? AccountKey { get; private set; }
    public string? Note { get; set; }
    long? _changes;
    DispatcherQueueTimer? _poll;

    public static string DeviceName { get; } = Environment.MachineName.Length > 0 ? Environment.MachineName : "Windows";
    public const string DeviceKind = "windows";

    public bool Joined => !string.IsNullOrEmpty(AccountKey);

    public async Task Start()
    {
        try { AccountKey = await Secrets.Read(KeyName); } catch { AccountKey = null; }
        StartCore();
        _poll = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _poll.Interval = TimeSpan.FromMilliseconds(1500);
        _poll.Tick += (_, _) => _ = Refresh();
        _poll.Start();
        await Refresh();
    }

    void StartCore()
    {
        try
        {
            TlCore.SyncStart(AccountKey ?? "", DeviceName);
            TlCore.DiscoveryStart(ServiceType, DeviceName, DeviceKind);
            Note = null;
        }
        // shown on the sync page (the listener or the discovery could not start)
        catch (Exception e) { Note = e.Message; }
    }

    async Task Refresh()
    {
        try
        {
            var (s, d) = await TlCore.Run(() => (TlCore.SyncStatus(), TlCore.DiscoveryStatus()));
            var joinKey = s.Join.AccountKey;
            if (joinKey != null && joinKey != AccountKey) await Adopt(joinKey);
            if (_changes != null && s.Changes > _changes) RemoteChanges?.Invoke();
            _changes = s.Changes;
            Status = s;
            Discovery = d;
            Changed?.Invoke();
        }
        catch { }
    }

    async Task Adopt(string key)
    {
        try { await Secrets.Write(KeyName, key); } catch { return; }
        AccountKey = key;
        TlCore.DiscoveryStop();
        StartCore();
    }

    /// The account's other devices found on the network.
    public List<DiscoveredPeer> AccountPeers
    {
        get
        {
            var mine = Status?.AccountId;
            return mine == null ? [] : [.. (Discovery?.Peers ?? []).Where(p => p.Account == mine)];
        }
    }

    /// The joinable devices, one group per account, largest group first.
    public List<(string Account, List<DiscoveredPeer> Peers)> JoinableAccounts =>
        [.. (Discovery?.Peers ?? []).Where(p => p.Account != null && p.Reachable)
            .GroupBy(p => p.Account!)
            .Select(g => (g.Key, g.OrderBy(p => p.Name, StringComparer.CurrentCulture).ToList()))
            .OrderByDescending(g => g.Item2.Count).ThenBy(g => g.Item2[0].Name, StringComparer.CurrentCulture)];

    public async Task CreateAccount()
    {
        var key = TlCore.SyncNewAccount();
        try { await Secrets.Write(KeyName, key); } catch { return; }
        AccountKey = key;
        TlCore.DiscoveryStop();
        StartCore();
        await Refresh();
    }

    /// 清除所有数据: the device leaves the account, or the next start would pull it all back.
    public async Task<bool> ForgetAccount()
    {
        var removed = true;
        try { await Secrets.Delete(KeyName); } catch { removed = false; }
        AccountKey = null;
        try { TlCore.DiscoveryStop(); TlCore.SyncReset(); } catch { }
        StartCore();
        await Refresh();
        return removed;
    }

    public async Task Leave()
    {
        try { await Secrets.Delete(KeyName); } catch { return; }
        AccountKey = null;
        TlCore.DiscoveryStop();
        StartCore();
        await Refresh();
    }

    /// After a failed data folder move: discovery runs again.
    public void Restart() { try { TlCore.DiscoveryStop(); } catch { } StartCore(); }

    public string BeginPairing() => TlCore.SyncPairBegin();
    public void CancelPairing() => TlCore.SyncPairCancel();
    public void Join(DiscoveredPeer peer, string code) => TlCore.SyncJoin(peer.Host!, peer.Port!.Value, code.Trim());
    public void SyncNow() => TlCore.DiscoverySyncNow();

    /// The library changed here: the others hear of it in a few seconds.
    public static void LocalChange()
    {
        try { TlCore.DiscoveryChanged(); } catch { }
    }

    public void Stop()
    {
        _poll?.Stop();
        try { TlCore.DiscoveryStop(); } catch { }
    }
}
