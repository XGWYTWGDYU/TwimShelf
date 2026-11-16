// 下载帖子: the durable link queue (<library>\downloads.queue.json, the Flutter app's file and
// format) and the core's download job. Links are written to the queue before anything that sent
// them is acknowledged; the queue never holds cookies. Queue changes and core handoffs are serial.
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Models;

public sealed class DownloadServiceException(string key) : Exception(key)
{
    public string MessageKey => Message;
}

public sealed record QueuedDownload(string Url, string? Source, bool Revive, bool MarkRecent, string? Folder)
{
    public string Identity => Url[(Url.LastIndexOf('/') + 1)..];

    public JsonObject ToJson() => new()
    {
        ["url"] = Url, ["source"] = Source, ["revive"] = Revive, ["folder"] = Folder, ["markRecent"] = MarkRecent,
    };

    public static QueuedDownload FromJson(JsonNode j)
    {
        var url = (string)j["url"]!;
        var normalized = SharedLinks.Parse(url);
        if (normalized.Count != 1 || normalized[0] != url) throw new FormatException("downloads.invalidQueue");
        return new QueuedDownload(url, (string?)j["source"], (bool)j["revive"]!, (bool)j["markRecent"]!, (string?)j["folder"]);
    }
}

public enum DownloadPhase { Idle, Queued, Running, Pausing, Paused, Cancelling, Cancelled, Failed }

public sealed class DownloadService
{
    readonly string _file;
    readonly SemaphoreSlim _gate = new(1, 1);
    readonly DispatcherQueue _ui;
    DispatcherQueueTimer? _timer;
    readonly HashSet<long> _reported = [];
    bool _polling;

    List<QueuedDownload> _queue = [];
    HashSet<string> _acceptedShares = [];
    string _mode = "active";
    DownloadRoute _route = DownloadRoute.Auto;

    public event Action? Changed;
    public Action<DownloadStatus>? OnFinished { get; set; }
    int _concurrency = 3, _intervalMs = 500;
    string? _folder;
    /// These three are saved as they change (and the extension's receiver follows them at once).
    public int Concurrency { get => _concurrency; set { _concurrency = value; Settle(); } }
    public int IntervalMs { get => _intervalMs; set { _intervalMs = value; Settle(); } }
    public string? Folder { get => _folder; set { _folder = value; Settle(); } }
    void Settle() { Notify(); _ = Serial(Commit); }
    public DownloadStatus? Status { get; private set; }
    public Exception? LastError { get; private set; }
    /// Saved settings or links this version cannot read: kept aside under this name, not deleted.
    public string? DamagedQueue { get; private set; }
    public IReadOnlyList<QueuedDownload> Queue => _queue;

    public string? ErrorKey => LastError switch
    {
        null => null,
        DownloadServiceException d => d.MessageKey,
        _ => "common.couldNotStartDownload",
    };

    public DownloadRoute Route
    {
        get => _route;
        set
        {
            _route = value;
            Notify();
            _ = Serial(Commit);
        }
    }

    public DownloadPhase Phase
    {
        get
        {
            if (Status?.Running == true)
                return _mode switch { "paused" => DownloadPhase.Pausing, "cancelled" => DownloadPhase.Cancelling, _ => DownloadPhase.Running };
            if (LastError != null) return DownloadPhase.Failed;
            if (_mode == "paused" || (Status?.Paused ?? 0) > 0) return DownloadPhase.Paused;
            if (_queue.Count > 0) return DownloadPhase.Queued;
            if (_mode == "cancelled") return DownloadPhase.Cancelled;
            if (Status?.Outcome == "failed") return DownloadPhase.Failed;
            return DownloadPhase.Idle;
        }
    }

    DownloadService(string libraryDir)
    {
        _file = Path.Combine(libraryDir, "downloads.queue.json");
        _ui = DispatcherQueue.GetForCurrentThread();
    }

    public static async Task<DownloadService> Create(string libraryDir, Action<DownloadStatus>? onFinished)
    {
        var s = new DownloadService(libraryDir) { OnFinished = onFinished };
        await s.Serial(s.Load);
        // links saved but not yet handed to the core (the app was closed meanwhile): they go on, as
        // asked for, rather than showing as downloading with nothing running
        if (s._queue.Count > 0 && s._mode == "active" && s.Status?.Running != true) _ = s.Start().ContinueWith(_ => { });
        return s;
    }

    /// Called every second or so: a download the browser extension started straight in the core
    /// is noticed (its progress, and the library reloading when it ends).
    public async Task Watch()
    {
        if (_timer != null || _polling) return;
        DownloadStatus? s;
        try { s = await TlCore.Run(TlCore.DownloadStatus); } catch { return; }
        if (s?.Running == true || (s?.Generation ?? 0) != (Status?.Generation ?? 0)) await Poll();
    }

    void Notify()
    {
        if (_ui.HasThreadAccess) Changed?.Invoke();
        else _ui.TryEnqueue(() => Changed?.Invoke());
    }

    async Task Serial(Func<Task> action, bool rethrow = false)
    {
        await _gate.WaitAsync();
        try
        {
            LastError = null;
            await action();
            Notify();
        }
        catch (Exception e)
        {
            LastError = e;
            Notify();
            if (rethrow) throw;
        }
        finally { _gate.Release(); }
    }

    Task Run(Func<Task> action) => Serial(action, rethrow: true);

    async Task Load()
    {
        JsonNode? data = null;
        try
        {
            if (File.Exists(_file))
            {
                data = JsonNode.Parse(await File.ReadAllTextAsync(_file));
                if ((int?)data?["version"] != 1) throw new FormatException("downloads.invalidQueue");
                var queue = data!["queue"]!.AsArray().Select(v => QueuedDownload.FromJson(v!)).ToList();
                if (queue.Select(e => e.Identity).Distinct().Count() != queue.Count) throw new FormatException("downloads.duplicateQueue");
                var mode = (string)data["mode"]!;
                if (mode is not ("active" or "paused" or "cancelled")) throw new FormatException("downloads.invalidQueue");
                _queue = queue;
                _mode = mode;
                _route = (string?)data["route"] switch { "fx" => DownloadRoute.Fx, "cookie" => DownloadRoute.Cookie, _ => DownloadRoute.Auto };
                _concurrency = Math.Clamp((int?)data["concurrency"] ?? 3, 1, 16);
                _intervalMs = Math.Clamp((int?)data["intervalMs"] ?? 500, 0, 600000);
                _folder = (string?)data["folder"];
                _acceptedShares = [.. data["acceptedShares"]!.AsArray().Select(v => (string)v!)];
            }
        }
        catch (Exception e)
        {
            // a damaged file must not keep the library from opening: it is kept, and the page says so
            var kept = $"{_file}.damaged-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}";
            try { File.Move(_file, kept); DamagedQueue = kept; } catch { }
            LastError = e;
            _queue = [];
            _acceptedShares = [];
        }
        await Refresh();
    }

    async Task Commit() => await Commit(null, null, null);

    async Task Commit(List<QueuedDownload>? queue, HashSet<string>? shares, string? mode)
    {
        var nextQueue = queue ?? _queue;
        var nextShares = shares ?? _acceptedShares;
        var nextMode = mode ?? _mode;
        var o = new JsonObject
        {
            ["version"] = 1,
            ["route"] = _route switch { DownloadRoute.Fx => "fx", DownloadRoute.Cookie => "cookie", _ => "auto" },
            ["mode"] = nextMode,
            ["concurrency"] = Math.Clamp(Concurrency, 1, 16),
            ["intervalMs"] = Math.Clamp(IntervalMs, 0, 600000),
            ["folder"] = Folder,
            ["queue"] = new JsonArray([.. nextQueue.Select(e => (JsonNode)e.ToJson())]),
            ["acceptedShares"] = new JsonArray([.. nextShares.Select(s => (JsonNode?)JsonValue.Create(s))]),
        };
        Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
        var tmp = $"{_file}.{DateTime.UtcNow.Ticks}.{Random.Shared.Next()}.partial";
        try
        {
            await using (var f = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write))
            {
                await f.WriteAsync(System.Text.Encoding.UTF8.GetBytes(o.ToJsonString()));
                f.Flush(true);
            }
            File.Move(tmp, _file, true);
        }
        finally { if (File.Exists(tmp)) File.Delete(tmp); }
        _queue = nextQueue;
        _acceptedShares = nextShares;
        _mode = nextMode;
        Notify();
    }

    List<QueuedDownload> Adding(IEnumerable<string> values, string? source = null, bool revive = true, bool recent = false, string? folder = null)
    {
        var entries = new Dictionary<string, QueuedDownload>();
        foreach (var e in _queue) entries[e.Identity] = e;
        var order = _queue.Select(e => e.Identity).ToList();
        foreach (var value in values)
        {
            var urls = SharedLinks.Parse(value);
            if (urls.Count == 0) throw new DownloadServiceException("settings.links.unrecognized");
            foreach (var url in urls)
            {
                var entry = new QueuedDownload(url, source, revive, recent, folder);
                if (entries.TryGetValue(entry.Identity, out var previous))
                    entries[entry.Identity] = new QueuedDownload(previous.Url, previous.Source ?? source, previous.Revive || revive, previous.MarkRecent || recent, previous.Folder ?? folder);
                else
                {
                    entries[entry.Identity] = entry;
                    order.Add(entry.Identity);
                }
            }
        }
        return [.. order.Select(i => entries[i])];
    }

    public Task EnqueueLinks(IEnumerable<string> links, string? source = null) => Run(async () =>
    {
        await Commit(Adding(links, source), null, _mode == "cancelled" ? "active" : null);
        if (Status?.Running == true && _mode == "active") await Handoff();
    });

    /// Links pasted by hand: queued, then the download goes.
    public async Task StartLinks(IEnumerable<string> links)
    {
        await EnqueueLinks(links);
        await Start();
    }

    public Task ImportBookmarks(string path) => Run(async () =>
    {
        var urls = await TlCore.Run(() => TlCore.BookmarkUrls(path));
        await Commit(Adding(urls, path, revive: false, recent: true), null, _mode == "cancelled" ? "active" : null);
        if (Status?.Running == true && _mode == "active") await Handoff();
    });

    DownloadRequest Request(List<QueuedDownload> batch) => new()
    {
        Urls = [.. batch.Select(e => e.Url)],
        Route = _route,
        Concurrency = Math.Clamp(Concurrency, 1, 16),
        IntervalMs = Math.Clamp(IntervalMs, 0, 600000),
        Folder = batch.Count > 0 ? batch[0].Folder ?? Folder : Folder,
        Revive = batch.Count > 0 && batch[0].Revive,
        MarkRecent = batch.Count > 0 && batch[0].MarkRecent,
    };

    async Task Handoff()
    {
        while (_queue.Count > 0)
        {
            var first = _queue[0];
            var batch = _queue.TakeWhile(e => e.Revive == first.Revive && e.MarkRecent == first.MarkRecent && e.Folder == first.Folder).ToList();
            var request = Request(batch);
            await TlCore.Run(() => TlCore.StartDownload(request)); // return means the core has every URL
            try { await Commit([.. _queue.Skip(batch.Count)], null, null); }
            finally { await Refresh(); }
        }
    }

    async Task ApplyCookies()
    {
        var ok = await Secrets.ApplyStoredCookies();
        if (_route == DownloadRoute.Cookie && !ok) throw new DownloadServiceException("settings.cookie.keychainRefused");
    }

    public Task Start() => Run(async () =>
    {
        if (_queue.Count == 0 && (_mode == "paused" || (Status?.Paused ?? 0) > 0)) throw new DownloadServiceException("settings.resume");
        await ApplyCookies();
        try
        {
            await Commit(null, null, "active");
            if (_queue.Count == 0)
            {
                var r = Request([]);
                await TlCore.Run(() => TlCore.StartDownload(r));
            }
            else await Handoff();
        }
        finally { await Refresh(); }
    });

    public Task Pause() => Run(async () =>
    {
        await Commit(null, null, "paused");
        await TlCore.Run(() => TlCore.StopDownload(true));
        await Refresh();
    });

    public Task Resume() => Run(async () =>
    {
        await ApplyCookies();
        try
        {
            await Commit(null, null, "active");
            var r = Request([]);
            await TlCore.Run(() => TlCore.ResumeDownload(r));
            await Refresh();
            await Handoff();
        }
        finally { await Refresh(); }
    });

    /// The data folder is about to move: what runs stops, and goes on from the new place.
    public Task PauseForMove() => Run(async () =>
    {
        await TlCore.Run(() => TlCore.StopDownload(true));
        await Refresh();
    });

    /// 清除所有数据: nothing left to send, the record of accepted shares gone.
    public Task DiscardAll() => Run(async () =>
    {
        await Commit([], [], "active");
        await TlCore.Run(() => TlCore.StopDownload(false));
        await Refresh();
    });

    public Task Cancel() => Run(async () =>
    {
        // explicit cancellation discards unsent links: persisted before the stop
        await Commit([], null, "cancelled");
        await TlCore.Run(() => TlCore.StopDownload(false));
        await Refresh();
    });

    public Task Poll() => Serial(Refresh);

    async Task Refresh()
    {
        Status = await TlCore.Run(TlCore.DownloadStatus);
        if (Status?.Running == true)
        {
            if (_timer == null)
            {
                _ui.TryEnqueue(() =>
                {
                    if (_timer != null) return;
                    _timer = _ui.CreateTimer();
                    _timer.Interval = TimeSpan.FromSeconds(1);
                    _timer.Tick += async (_, _) =>
                    {
                        if (_polling) return;
                        _polling = true;
                        try { await Poll(); } finally { _polling = false; }
                    };
                    _timer.Start();
                });
            }
        }
        else if (_timer != null)
        {
            var t = _timer;
            _timer = null;
            _ui.TryEnqueue(t.Stop);
        }
        var current = Status;
        if (current is { Running: false, Total: > 0, Generation: > 0 } && current.Outcome is "succeeded" or "partial" or "failed" or "cancelled" && _reported.Add(current.Generation))
        {
            var f = OnFinished;
            if (f != null) _ui.TryEnqueue(() => f(current));
        }
        Notify();
    }

    /// Links shared here: into the queue durably, then acknowledged (never lost on the way).
    public async Task AcceptSharedLinks(ShareLinksReady e, Func<string, Task> acknowledge)
    {
        await Run(async () =>
        {
            if (!_acceptedShares.Contains(e.Id))
                await Commit(Adding(e.Links, "share:" + e.Id, folder: e.Folder), [.. _acceptedShares, e.Id], _mode == "cancelled" ? "active" : null);
        });
        await acknowledge(e.Id);
    }

    public void Attach(ShareInbox inbox)
    {
        inbox.Events += e =>
        {
            if (e is ShareLinksReady links) _ = AcceptSharedLinks(links, inbox.AcknowledgeLinks).ContinueWith(t => { if (t.Exception != null) { LastError = t.Exception.InnerException; Notify(); } });
        };
    }

    public void Dispose() => _timer?.Stop();
}
