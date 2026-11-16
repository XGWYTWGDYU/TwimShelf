// The open library, shared by every page: opening it, its counts and folders, and a Revision that
// moves whenever its content changed (an action here, an import, a sync from another device), so
// pages reload. Core calls that take time run off the UI thread.
using Microsoft.UI.Dispatching;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Models;

public sealed class LibraryModel
{
    public static LibraryModel Current { get; private set; } = null!;

    public string Directory { get; }
    public LibraryStats? Stats { get; private set; }
    public FolderOverview? Folders { get; private set; }
    /// Moves whenever the library changed; pages reload what they show.
    public int Revision { get; private set; }
    public event Action? Changed;

    /// A post to show in 浏览 (a grid's 在浏览中查看帖子).
    public event Action<FeedItem>? RevealRequested;
    public void Reveal(FeedItem item) => RevealRequested?.Invoke(item);
    /// 在浏览中查看: 浏览 with this filter.
    public event Action<FeedFilter>? FilterRequested;
    public void ShowInBrowse(FeedFilter f) => FilterRequested?.Invoke(f);

    public ShareInbox Shares { get; } = new();
    public SyncModel Sync { get; } = new();
    public DownloadService Downloads { get; private set; } = null!;
    public AI.AiTagging Ai { get; private set; } = null!;
    long _epoch = -1;
    DispatcherQueueTimer? _poll;

    LibraryModel(string dir) => Directory = dir;

    public static async Task<LibraryModel> Open()
    {
        var dir = DataHome.LibraryDir;
        System.IO.Directory.CreateDirectory(dir);
        var language = L10n.LanguageTag;
        var ok = await TlCore.Run(() =>
        {
            TlCore.SetLanguage(language);
            TlCore.SetAppName(L10n.AppName);
            return TlCore.Open(dir);
        });
        if (!ok) throw new CoreException(Strings.L("app.openFailed"));
        await Secrets.ApplyStoredCookies();
        var m = new LibraryModel(dir);
        Current = m;
        Thumbnails.Init();
        // what cannot be decoded joins 只看损坏 and the check's count
        Thumbnails.OnFailed += id => _ = TlCore.Run(() => { try { TlCore.ReportThumbnailFailed(id); } catch { } });
        m.Shares.Events += e => { if (e is ShareFilesImported) _ = m.Refresh(); };
        m.Ai = await AI.AiTagging.Create(m);
        await m.Refresh(local: false);
        m.Downloads = await DownloadService.Create(dir, finished => { Thumbnails.ForgetFailures(); _ = m.Refresh(); });
        Extension.Receiver.Start(m.Downloads);
        m.Downloads.Attach(m.Shares);
        m.Shares.Start();
        // a wipe (from a test, the extension) is noticed by the core's epoch
        m._poll = DispatcherQueue.GetForCurrentThread().CreateTimer();
        m._poll.Interval = TimeSpan.FromSeconds(1);
        m._poll.Tick += (_, _) => { _ = m.CheckEpoch(); _ = m.Downloads.Watch(); };
        m._poll.Start();
        // another device's changes: reload, without announcing them as this device's
        m.Sync.RemoteChanges += () => { Thumbnails.ForgetFailures(); _ = m.Refresh(local: false); };
        if (Environment.GetEnvironmentVariable("TL_SYNC_OFF") == null) _ = m.Sync.Start();
        return m;
    }

    async Task CheckEpoch()
    {
        long e;
        try { e = await TlCore.Run(TlCore.Epoch); } catch { return; }
        // the epoch counts wipes (work started before one can no longer write), not changes
        if (e != _epoch)
        {
            _epoch = e;
            await Refresh();
        }
    }

    /// Reloads counts and folders and tells the pages to reload. A change made here (the default)
    /// is also announced to the account's other devices, which sync in a few seconds.
    public async Task Refresh(bool local = true, bool startTagging = true)
    {
        if (local) SyncModel.LocalChange();
        if (startTagging) _ = Ai.StartIfEnabled();
        try
        {
            var (s, f, e) = await TlCore.Run(() => (TlCore.Stats(), TlCore.FolderOverview(), TlCore.Epoch()));
            Stats = s;
            Folders = f;
            _epoch = e;
        }
        catch { }
        Revision++;
        Changed?.Invoke();
    }

    public Task<List<FeedItem>> Feed(FeedRequest request) => TlCore.Run(() => TlCore.Feed(request));

    public Task<List<FeedItem>> Bin() => TlCore.Run(() => TlCore.TrashList().Select(t => new FeedItem
    {
        MediaId = t.MediaId, PostId = t.PostId, Ordinal = t.Ordinal, Kind = t.Kind, Path = t.Path,
        Text = t.Text, AuthorName = t.AuthorName, ScreenName = t.ScreenName, Url = t.Url, Tags = t.Tags,
    }).ToList());

    bool _downloadingBeforeMove;

    /// Before the data folder moves: nothing downloads, tags or syncs while it is copied. (What
    /// still arrives — the browser extension, a sync already under way — is not lost to the copy:
    /// it is made from a database snapshot taken first, and every file that snapshot refers to.)
    public async Task StopWriting()
    {
        _downloadingBeforeMove = Downloads.Phase is DownloadPhase.Running or DownloadPhase.Queued;
        await Ai.StopForWipe();
        await Downloads.PauseForMove();
        TlCore.DiscoveryStop();
    }

    /// The move failed: what StopWriting stopped goes on here.
    public async Task ResumeWriting()
    {
        Sync.Restart();
        if (_downloadingBeforeMove) { try { await Downloads.Resume(); } catch { } }
        _ = Ai.StartIfEnabled();
    }

    /// 清除所有数据: what the core keeps, and what this app keeps around it. The AI settings stay
    /// unless the models go too. Gives back what could not be removed.
    public async Task<List<string>> WipeEverything(bool includeModels)
    {
        var problems = new HashSet<string>();
        await Ai.StopForWipe();
        await Downloads.DiscardAll();
        // the API keys first: they are found through the external models, which the core's wipe
        // removes (afterwards none would be left to find, and the keys would stay)
        await Ai.Forget(settings: includeModels);
        await TlCore.Run(() => TlCore.Wipe(includeModels));
        // this app's own caches: grid thumbnails, video posters, converted pictures
        if (!Thumbnails.Clear()) problems.Add(Strings.L("common.notDone"));
        await Shares.Wipe();
        TlCore.SetCookies("", "");
        foreach (var key in new[] { "auth_token", "ct0" })
        {
            try { await Secrets.Delete(key); } catch { problems.Add(Strings.L("secrets.unavailable")); }
        }
        if (!await Sync.ForgetAccount()) problems.Add(Strings.L("secrets.unavailable"));
        Prefs.Instance.Wipe(keepAI: !includeModels);
        await Refresh(local: false);
        return [.. problems];
    }

    public void Close()
    {
        _poll?.Stop();
        Sync.Stop();
        Downloads?.Dispose();
        Shares.Dispose();
        Ai?.Close();
    }
}
