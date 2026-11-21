// 局域网同步: the account (make one, or join another device's with the code it shows), this device and
// the account's devices, adding a device, leaving — the other apps' 同步 page.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class SyncSettings : SettingsSubpage
{
    readonly LibraryModel _library;
    SyncModel Sync => _library.Sync;
    string _shownKey = "";

    public override string Title => L("common.lanSync");

    public SyncSettings(LibraryModel library)
    {
        _library = library;
        Sync.Changed += OnChanged;
    }

    public override void Closed() => Sync.Changed -= OnChanged;

    /// The 1.5 s status redraws the page only when what it shows has changed.
    void OnChanged()
    {
        if (Key() != _shownKey) Build();
    }

    string Key()
    {
        var s = Sync.Status;
        var d = Sync.Discovery;
        return string.Join('|', Sync.Joined, Sync.Note, s?.Syncing > 0, s?.Join.Running, s?.Join.Error, d?.NetworkOk, d?.Error, d?.Running,
            string.Join(',', (d?.Peers ?? []).Select(p => $"{p.Device}{p.Name}{p.Account}{p.Reachable}")),
            string.Join(',', (s?.Peers ?? []).Select(p => $"{p.Device}{p.LastSync}{p.LastError}")));
    }

    public static (string Glyph, string? Name) DeviceType(string? kind) => kind switch
    {
        "mac" => ("", "macOS"),
        "iphone" => ("", "iPhone"),
        "ipad" => ("", "iPad"),
        "android-phone" => ("", "Android"),
        "android-tablet" => ("", "Android"),
        "windows" => ("", "Windows"),
        "linux" => ("", "Linux"),
        _ => ("", null),
    };

    void NetworkProblem()
    {
        var d = Sync.Discovery;
        // sync could not start at all (its listener or the discovery failed): said, not a search forever
        if (Sync.Note is { } note) { Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Title = L("sync.noLocalNetwork"), Message = note }); return; }
        if (d == null) return;
        if (!d.Running) { Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = L("sync.noLocalNetwork"), Message = L(d.Error ?? "sync.err.paused") }); return; }
        if (d.NetworkOk && d.Error == null) return;
        Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = L("sync.noLocalNetwork"), Message = L(d.Error ?? "sync.err.paused") });
    }

    public override void Build()
    {
        _shownKey = Key();
        Clear();
        var s = Sync.Status;
        if (s == null) { Card(L("sync.state.reading")); return; }
        if (!Sync.Joined)
        {
            Header(L("sync.first"));
            Action(L("sync.create"), null, "", () => _ = Sync.CreateAccount());
            Footer(L("sync.first.footer"));
            var groups = Sync.JoinableAccounts;
            string GroupTitle((string Account, List<DiscoveredPeer> Peers) g) =>
                L("sync.accountId", g.Account[..Math.Min(8, g.Account.Length)].ToUpperInvariant()) + " · " + string.Join(L("list.separator"), g.Peers.Select(p => p.Name));
            void JoinCard(DiscoveredPeer p)
            {
                var (glyph, name) = DeviceType(p.Kind);
                var b = new Button { Content = L("sync.joinEllipsis") };
                b.Click += (_, _) => _ = Join(p);
                var card = Card(p.Name, name, glyph, b);
                if (Clawd.On && Clawd.ForDevice(p.Kind) is { } crab) card.HeaderIcon = Clawd.Icon(crab, 24);
            }
            Header(groups.Count == 1 ? $"{L("sync.joinExisting")} · {GroupTitle(groups[0])}" : L("sync.joinExisting"));
            NetworkProblem();
            if (groups.Count == 0 && Body.Children[^1] is not InfoBar) Card(L("sync.searching"), null, null, new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            if (groups.Count == 1) foreach (var p in groups[0].Peers) JoinCard(p);
            if (s.Join.Running) Card(L("sync.pairing"));
            if (s.Join.Error != null) Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Title = L("sync.joinFailed"), Message = s.Join.Error });
            if (groups.Count > 1)
                foreach (var g in groups) { Header(GroupTitle(g)); foreach (var p in g.Peers) JoinCard(p); }
            Footer(L("sync.joinExisting.footer"));
            return;
        }
        Header(L("sync.status"));
        // only when there is someone to sync with (with no discovery or no device it did nothing)
        var now = new Button { Content = L("sync.now"), IsEnabled = Sync.Note == null && Sync.Discovery?.Running == true && Sync.AccountPeers.Count > 0 };
        now.Click += (_, _) => Sync.SyncNow();
        var thisCard = Card(s.Syncing > 0 ? L("sync.syncingEllipsis") : L("sync.state.on"), string.Join(" · ", new[] { L("sync.thisDevice"), "Windows", s.DeviceName }), s.Syncing > 0 ? "" : "", now);
        if (Clawd.On && s.Syncing == 0) thisCard.HeaderIcon = Clawd.Icon("laptop", 24);
        NetworkProblem();
        Footer(L("sync.joined.message"));

        Header(L("sync.devices"));
        var peers = Sync.AccountPeers;
        if (peers.Count == 0) Card(L("sync.noOthers"));
        foreach (var p in peers)
        {
            var (glyph, name) = DeviceType(p.Kind);
            var info = s.Peers.FirstOrDefault(x => x.Device == p.Device);
            var card = Card(p.Name, string.Join(" · ", new[] { name, PeerLine(p, info) }.Where(x => x != null)), glyph);
            // in the mascot mode the crab with a phone or a computer
            if (Clawd.On && Clawd.ForDevice(p.Kind) is { } crab) card.HeaderIcon = Clawd.Icon(crab, 24);
        }
        Footer(L("sync.devices.footer"));

        Header(L("sync.addDevice"));
        Action(L("sync.showCodeEllipsis"), L("sync.addDevice.footer"), "", () => _ = ShowCode());

        Header(L("sync.leaveEllipsis"));
        Action(L("sync.leaveEllipsis"), L("sync.leave.footer"), "", () => _ = Leave(), danger: true);
    }

    static string PeerLine(DiscoveredPeer p, PeerInfo? info)
    {
        var state = p.Reachable ? L("sync.online") : L("sync.offline");
        if (info == null || info.LastSync == 0) return state;
        var at = DateTimeOffset.FromUnixTimeSeconds(info.LastSync).LocalDateTime;
        var when = at.Date == DateTime.Today ? at.ToString("t") : at.ToString("d");
        return info.LastError is { } err ? $"{state} · {L("sync.failed", err)}" : $"{state} · {L("sync.syncedAgo", when)}";
    }

    async Task ShowCode()
    {
        string code;
        try { code = Sync.BeginPairing(); }
        catch (Exception e) { Dialogs.Toast(W, L("sync.error", e.Message)); return; }
        var shown = DateTime.Now;
        var codeText = new TextBlock { Text = code, Style = (Style)Application.Current.Resources["DisplayTextBlockStyle"], CharacterSpacing = 300, IsTextSelectionEnabled = true, HorizontalAlignment = HorizontalAlignment.Center };
        var left = new TextBlock { Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center };
        var d = new ContentDialog
        {
            Title = L("sync.showCode"),
            Content = new StackPanel { Spacing = 12, Children = { new TextBlock { Text = L("sync.showCode.detail"), TextWrapping = TextWrapping.Wrap }, codeText, left } },
            CloseButtonText = L("common.done"),
        };
        void Update()
        {
            var st = Sync.Status;
            var fresh = st?.PairingCode == code;
            var expired = st != null && st.PairingCode == null && (DateTime.Now - shown).TotalSeconds > 2;
            var secs = fresh ? st!.PairingSecondsLeft ?? 0 : 300;
            if (expired) { codeText.Text = L("sync.code.expired"); codeText.Style = (Style)Application.Current.Resources["BodyTextBlockStyle"]; left.Text = ""; }
            else left.Text = L("sync.code.expires", secs / 60, secs % 60);
        }
        Update();
        Sync.Changed += Update;
        await Dialogs.ShowAsync(W, d);
        Sync.Changed -= Update;
        Sync.CancelPairing();
    }

    async Task Join(DiscoveredPeer peer)
    {
        var text = new TextBox { PlaceholderText = L("sync.enterCode"), MaxLength = 6, InputScope = new Microsoft.UI.Xaml.Input.InputScope { Names = { new Microsoft.UI.Xaml.Input.InputScopeName(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } } };
        var d = new ContentDialog { Title = L("sync.joinOf", peer.Name), Content = text, PrimaryButtonText = L("sync.join"), CloseButtonText = L("common.cancel"), DefaultButton = ContentDialogButton.Primary };
        text.BeforeTextChanging += (_, e) => e.Cancel = e.NewText.Any(c => !char.IsAsciiDigit(c));
        if (await Dialogs.ShowAsync(W, d) != ContentDialogResult.Primary || text.Text.Trim().Length == 0) return;
        try { Sync.Join(peer, text.Text); }
        catch (Exception e) { Dialogs.Toast(W, L("sync.error", e.Message)); }
    }

    async Task Leave()
    {
        var c = await Dialogs.Choose(W, L("sync.leave.title"), L("sync.leave.message"), L("sync.leave.keep"), L("sync.leave.deleteAll"));
        if (c == 0) await Sync.Leave();
        // the same as 清除所有数据 in 设置, with its confirmation: it leaves the account too
        if (c == 1) await SettingsRoot.Wipe(_library);
    }
}
