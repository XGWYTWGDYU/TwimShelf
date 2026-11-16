// What other programs hand to TwimShelf: 发送到 (the Send To menu: TwimShelf.exe --import <files>),
// the taskbar's 下载帖子 (--quick-download), and media dropped on the window. The same durable
// handoff as the Flutter app, in the same folders, so nothing waiting is lost by the upgrade:
//   %LOCALAPPDATA%\org.twimshelf\Shares\Requests\<id>.json   a launch's arguments (any process)
//   …\Inbox\<id>\                                            a batch: copies of the files, _links.json
//   …\Links\<id>.json                                         links waiting for the download queue
//   …\Kept\<id>\                                              files an import kept (problems)
//   …\Staging\<id>\                                           what the share page downloaded
// Only the first process (the one holding the mutex) drains; a second launch writes its request
// and exits. Every batch waits for the share page, as on Windows before.
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using TwimShelf.Core;

namespace TwimShelf.Services;

public abstract record ShareEvent;
/// Durable until AcknowledgeLinks after the download queue accepted them.
public sealed record ShareLinksReady(string Id, List<string> Links, string? Folder) : ShareEvent;
/// A batch waiting for the share page (which ends in Confirm or Discard).
public sealed record ShareNeedsChoice(string Id, string Directory, List<string> Files, List<string> Links) : ShareEvent;
public sealed record ShareQuickDownload : ShareEvent;
public sealed record ShareFilesImported(string Id, ImportReport Report) : ShareEvent;
/// Shares that could not be taken in now (they stay, and are tried again); Message says why.
public sealed record ShareInboxFailure(int Pending, string? Message = null) : ShareEvent;

public static partial class SharedLinks
{
    static readonly HashSet<string> Hosts = ["twitter.com", "x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com"];

    [GeneratedRegex(@"(?<![a-z0-9_.@/])(?:https?://)?(?:(?:www|mobile|m)\.)?(?:twitter\.com|x\.com|fxtwitter\.com|fixupx\.com|vxtwitter\.com|fixvx\.com)/[^\s<>()]+", RegexOptions.IgnoreCase)]
    private static partial Regex Candidates();
    [GeneratedRegex(@"^(www|mobile|m)\.")]
    private static partial Regex Prefix();
    [GeneratedRegex(@"^[A-Za-z0-9_]+$")]
    private static partial Regex User();
    [GeneratedRegex(@"^[0-9]+")]
    private static partial Regex Digits();

    /// Post links in a text, normalized to https://x.com/<user>/status/<id> (tracking dropped).
    public static List<string> Parse(string text)
    {
        var result = new List<string>();
        foreach (Match m in Candidates().Matches(text))
        {
            var value = m.Value;
            if (!Uri.TryCreate(value.Contains("://") ? value : "https://" + value, UriKind.Absolute, out var uri)) continue;
            if (uri.UserInfo.Length > 0 || !uri.IsDefaultPort) continue;
            var host = Prefix().Replace(uri.Host.ToLowerInvariant(), "");
            if (!Hosts.Contains(host)) continue;
            var parts = uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.UnescapeDataString).ToArray();
            string? user = null, rawId = null;
            if (parts.Length >= 4 && string.Join('/', parts.Take(3)) == "i/web/status") { user = "i"; rawId = parts[3]; }
            else if (parts.Length >= 3 && parts[0] == "i" && parts[1] == "status") { user = "i"; rawId = parts[2]; }
            else if (parts.Length >= 3 && parts[1].ToLowerInvariant() is "status" or "statuses") { user = parts[0]; rawId = parts[2]; }
            if (user == null || !User().IsMatch(user)) continue;
            var id = Digits().Match(rawId!).Value;
            if (id.Length == 0 || id.Length > 20) continue;
            var link = $"https://x.com/{user}/status/{id}";
            if (!result.Contains(link)) result.Add(link);
        }
        return result;
    }
}

public sealed partial class ShareInbox
{
    public static string Root
    {
        get
        {
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
#if DEBUG
            return Path.Combine(local, "org.twimshelf", "Shares-Debug");
#else
            return Path.Combine(local, "org.twimshelf", "Shares");
#endif
        }
    }

    public event Action<ShareEvent>? Events;
    /// Shares waiting for the page: one that came in before the page's listener was there is here.
    public List<ShareNeedsChoice> PendingChoices { get; } = [];
    readonly HashSet<string> _asked = [];
    readonly HashSet<string> _dropped = [];
    readonly List<FileSystemWatcher> _watchers = [];
    readonly SemaphoreSlim _gate = new(1, 1);
    bool _again, _disposed;
    Microsoft.UI.Dispatching.DispatcherQueue? _ui;
    Timer? _debounce;

    [GeneratedRegex(@"^[A-Za-z0-9_-]+$")]
    private static partial Regex SafeId();

    void Emit(ShareEvent e)
    {
        if (_disposed) return;
        if (_ui == null || _ui.HasThreadAccess) Events?.Invoke(e);
        else _ui.TryEnqueue(() => Events?.Invoke(e));
    }

    // ---- the launch side (any process) -------------------------------------------------------

    /// A launch with --import or --quick-download leaves its request for the first process.
    public static void QueueArguments(string[] args)
    {
        var importing = args.Any(a => a == "--import" || a.StartsWith("--import=") || a == "--quick-download");
        if (!importing || args is ["--import"]) return;
        var dir = Path.Combine(Root, "Requests");
        Directory.CreateDirectory(dir);
        var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
        var data = new JsonObject
        {
            ["version"] = 1,
            ["workingDirectory"] = Environment.CurrentDirectory,
            ["arguments"] = new JsonArray([.. args.Select(a => (JsonNode?)JsonValue.Create(a))]),
        };
        var partial = Path.Combine(dir, id + ".partial");
        using (var f = new FileStream(partial, FileMode.CreateNew, FileAccess.Write))
        {
            f.Write(Encoding.UTF8.GetBytes(data.ToJsonString()));
            f.Flush(true);
        }
        File.Move(partial, Path.Combine(dir, id + ".json"));
    }

    /// This user's (and build's) name for the single-instance lock and its show event: a stable FNV-1a
    /// of the per-user root, as before (separates debug and release).
    public static string InstanceName
    {
        get
        {
            ulong hash = 14695981039346656037UL;
            foreach (var c in Root) { hash ^= c; hash *= 1099511628211UL; }
            return @"Local\TwimShelf-" + hash;
        }
    }

    /// The first process holds this while it runs; a second launch only leaves its request.
    public static Mutex? AcquirePrimary()
    {
        var m = new Mutex(false, InstanceName, out var created);
        if (created) return m;
        m.Dispose();
        return null;
    }

    // ---- the first process ----------------------------------------------------------------------

    public void Start()
    {
        _ui = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        foreach (var name in new[] { "Requests", "Inbox" })
        {
            var dir = Path.Combine(Root, name);
            Directory.CreateDirectory(dir);
            var w = new FileSystemWatcher(dir) { IncludeSubdirectories = false, NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName };
            var request = name == "Requests";
            void Wake(string path)
            {
                var file = Path.GetFileName(path);
                if (request ? !file.EndsWith(".json") : !SafeId().IsMatch(file)) return;
                _debounce?.Dispose();
                _debounce = new Timer(_ => _ = Drain(), null, 100, Timeout.Infinite);
            }
            w.Created += (_, e) => Wake(e.FullPath);
            w.Renamed += (_, e) => Wake(e.FullPath);
            w.EnableRaisingEvents = true;
            _watchers.Add(w);
        }
        try { JumpList.Install(Strings.L("shortcut.downloadPosts")); }
        catch { Emit(new ShareInboxFailure(0)); }
        _ = Drain();
    }

    public async Task Drain()
    {
        if (_disposed) return;
        if (!await _gate.WaitAsync(0)) { _again = true; return; }
        try
        {
            do
            {
                _again = false;
                await Task.Run(DrainOnce);
            } while (_again && !_disposed);
        }
        finally { _gate.Release(); }
    }

    List<string> Pending(string inbox)
    {
        if (!Directory.Exists(inbox)) return [];
        var ready = new List<string>();
        foreach (var d in Directory.EnumerateDirectories(inbox))
        {
            var name = Path.GetFileName(d);
            if (name.EndsWith(".partial"))
            {
                if (DateTime.Now - Directory.GetLastWriteTime(d) > TimeSpan.FromDays(1)) Directory.Delete(d, true);
            }
            else if (SafeId().IsMatch(name)) ready.Add(d);
        }
        ready.Sort(StringComparer.Ordinal);
        return ready;
    }

    void DrainOnce()
    {
        var pending = 0;
        try
        {
            var failures = PublishRequests();
            if (failures > 0) Emit(new ShareInboxFailure(failures, _lastFailure));
            var inbox = Path.Combine(Root, "Inbox");
            var links = Path.Combine(Root, "Links");
            var imported = new HashSet<string>();
            while (!_disposed)
            {
                var ready = new List<string>();
                foreach (var b in Pending(inbox))
                {
                    var bid = Path.GetFileName(b);
                    if (imported.Contains(bid)) continue;
                    if (File.Exists(Path.Combine(b, "_share.json"))) ready.Add(b);
                    else if (_asked.Add(bid)) Announce(bid, b);
                }
                pending = ready.Count;
                if (ready.Count == 0) break;
                var batch = ready[0];
                var id = Path.GetFileName(batch);
                imported.Add(id);
                // the choice is read (and taken out of the batch, which is imported as files); if the
                // import fails it goes back, so the batch is tried again, and the dialog hears why
                var choice = Path.Combine(batch, "_share.json");
                string? choiceText = null;
                try
                {
                    foreach (var e in Directory.EnumerateFileSystemEntries(batch, "*", SearchOption.AllDirectories))
                        if (File.GetAttributes(e).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("shareInbox.symlink");
                    string? folder = null;
                    var album = true;
                    if (File.Exists(choice))
                    {
                        choiceText = File.ReadAllText(choice);
                        var chosen = JsonNode.Parse(choiceText)!;
                        var name = (string?)chosen["folder"] ?? "";
                        folder = name.Length == 0 ? null : name;
                        album = chosen["dropped"]?.GetValue<bool>() != true;
                        var left = chosen["links"]?.AsArray().Select(n => (string?)n ?? "").Where(s => s.Length > 0).ToList() ?? [];
                        if (left.Count > 0)
                        {
                            Directory.CreateDirectory(links);
                            File.WriteAllText(Path.Combine(links, id + ".json"), new JsonArray([.. left.Select(s => (JsonNode?)JsonValue.Create(s))]).ToJsonString());
                            if (folder != null) File.WriteAllText(Path.Combine(links, id + ".folder"), folder);
                        }
                        File.Delete(choice);
                    }
                    var pack = Path.Combine(batch, "post.tlpack");
                    if (File.Exists(pack))
                    {
                        if (folder != null) EnsureFolder(folder);
                        var report = TlCore.ImportPack(pack, folder ?? "");
                        if (report.Incomplete != null) throw new CoreException(report.Incomplete);
                        File.Delete(pack);
                        Emit(new ShareFilesImported(id, report));
                    }
                    var metadata = Path.Combine(batch, "_links.json");
                    if (File.Exists(metadata))
                    {
                        Directory.CreateDirectory(links);
                        File.Move(metadata, Path.Combine(links, id + ".json"), true);
                    }
                    if (!Directory.EnumerateFileSystemEntries(batch).Any()) Directory.Delete(batch);
                    else
                    {
                        if (folder != null) EnsureFolder(folder);
                        var report = TlCore.ImportLooseDir(batch, folder, consume: true, keepTo: Path.Combine(Root, "Kept", id), album: album);
                        Emit(new ShareFilesImported(id, report));
                        if (Directory.Exists(batch)) throw new IOException("shareInbox.notConsumed");
                    }
                    lock (_batchErrors) _batchErrors.Remove(id);
                }
                catch (Exception e)
                {
                    lock (_batchErrors) _batchErrors[id] = e.Message;
                    try { if (choiceText != null && Directory.Exists(batch) && !File.Exists(choice)) File.WriteAllText(choice, choiceText); } catch { }
                    throw;
                }
            }
            if (Directory.Exists(links))
            {
                foreach (var file in Directory.EnumerateFiles(links, "*.json").Order(StringComparer.Ordinal))
                {
                    var id = Path.GetFileNameWithoutExtension(file);
                    if (!SafeId().IsMatch(id)) continue;
                    if (new FileInfo(file).Length > 1024 * 1024) throw new FormatException("shareInbox.linksTooLarge");
                    var urls = new List<string>();
                    foreach (var v in JsonNode.Parse(File.ReadAllText(file))!.AsArray())
                        foreach (var u in SharedLinks.Parse((string?)v ?? throw new FormatException("shareInbox.invalidLinks")))
                            if (!urls.Contains(u)) urls.Add(u);
                    if (urls.Count == 0) throw new FormatException("shareInbox.invalidLinks");
                    var named = Path.Combine(links, id + ".folder");
                    Emit(new ShareLinksReady(id, urls, File.Exists(named) ? File.ReadAllText(named) : null));
                }
            }
        }
        catch (Exception e)
        {
            Emit(new ShareInboxFailure(Math.Max(1, pending), e.Message));
        }
    }

    static void EnsureFolder(string name)
    {
        try { TlCore.CreateFolder(name); } catch { /* it is there already */ }
    }

    /// The links of a share went into the durable download queue: they are no longer waiting here.
    public Task AcknowledgeLinks(string id) => Task.Run(() =>
    {
        if (!SafeId().IsMatch(id)) return;
        foreach (var ext in new[] { ".json", ".folder" })
        {
            var f = Path.Combine(Root, "Links", id + ext);
            if (File.Exists(f)) File.Delete(f);
        }
    });

    string? _lastFailure;

    int PublishRequests()
    {
        var requests = Path.Combine(Root, "Requests");
        if (!Directory.Exists(requests)) return 0;
        var failures = 0;
        foreach (var f in Directory.EnumerateFiles(requests, "*.json").Order(StringComparer.Ordinal))
        {
            try { Publish(f); } catch (Exception e) { failures++; _lastFailure = e.Message; }
        }
        return failures;
    }

    /// Several files may follow --import; everything after -- is literal.
    public static List<string> ParseImportArguments(IReadOnlyList<string> arguments)
    {
        var result = new List<string>();
        bool importing = false, literal = false;
        foreach (var a in arguments)
        {
            if (a.Contains('\0')) throw new FormatException("shareInbox.arguments");
            if (!literal && a == "--import") importing = true;
            else if (!literal && a.StartsWith("--import=")) { importing = true; result.Add(a[9..]); }
            else if (importing && !literal && a == "--") literal = true;
            else if (importing)
            {
                if (!literal && a.StartsWith("--")) throw new FormatException("shareInbox.arguments");
                result.Add(a);
            }
        }
        if (importing && (result.Count == 0 || result.Any(s => s.Length == 0))) throw new FormatException("shareInbox.arguments");
        return result;
    }

    static readonly HashSet<string> MediaExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".avif", ".bmp", ".tif", ".tiff",
        ".mp4", ".mov", ".m4v", ".webm", ".mkv", ".avi", ".3gp",
    };

    void Publish(string request)
    {
        var id = Path.GetFileNameWithoutExtension(request);
        if (!SafeId().IsMatch(id)) throw new FormatException("shareInbox.id");
        var done = Path.Combine(Root, "RequestsDone", id + ".done");
        var batch = Path.Combine(Root, "Inbox", id);
        if (!File.Exists(done) && !Directory.Exists(batch))
        {
            if (new FileInfo(request).Length > 1024 * 1024) throw new FormatException("shareInbox.size");
            var data = JsonNode.Parse(File.ReadAllText(request))!;
            if ((int?)data["version"] != 1) throw new FormatException("shareInbox.version");
            var args = data["arguments"]!.AsArray().Select(n => (string?)n ?? "").ToList();
            if (args.Contains("--quick-download"))
            {
                Emit(new ShareQuickDownload());
                File.Delete(request);
                return;
            }
            var cwd = (string?)data["workingDirectory"] ?? "";
            var items = ParseImportArguments(args);
            if (items.Count == 0) throw new FormatException("shareInbox.empty");
            var partial = batch + ".partial";
            Directory.CreateDirectory(Path.GetDirectoryName(batch)!);
            if (Directory.Exists(partial)) Directory.Delete(partial, true);
            Directory.CreateDirectory(partial);
            try
            {
                var links = new List<string>();
                var index = 0;
                foreach (var item in items)
                {
                    var urls = SharedLinks.Parse(item);
                    if (urls.Count > 0 && !item.StartsWith("file:", StringComparison.OrdinalIgnoreCase)) { links.AddRange(urls); continue; }
                    var source = item.StartsWith("file:", StringComparison.OrdinalIgnoreCase) ? new Uri(item).LocalPath : Path.GetFullPath(item, cwd);
                    var info = new FileInfo(source);
                    if (!info.Exists || info.Attributes.HasFlag(FileAttributes.ReparsePoint)) throw new IOException("shareInbox.regularFile");
                    if (!MediaExtensions.Contains(info.Extension) && !MediaSniff.IsMedia(source)) throw new FormatException("shareInbox.media");
                    var raw = Regex.Replace(info.Name, "[^A-Za-z0-9._-]", "_");
                    var name = raw.Length > 160 ? raw[^160..] : raw;
                    File.Copy(source, Path.Combine(partial, $"{index++}_{name}"));
                }
                if (links.Count > 0)
                    File.WriteAllText(Path.Combine(partial, "_links.json"), new JsonArray([.. links.Distinct().Select(s => (JsonNode?)JsonValue.Create(s))]).ToJsonString());
                Directory.Move(partial, batch);
            }
            catch
            {
                if (Directory.Exists(partial)) Directory.Delete(partial, true);
                throw;
            }
        }
        Directory.CreateDirectory(Path.GetDirectoryName(done)!);
        if (!File.Exists(done)) File.WriteAllText(done, "1");
        File.Delete(request);
    }

    void Announce(string id, string batch)
    {
        var choice = Read(id, batch);
        lock (PendingChoices) PendingChoices.Add(choice);
        Emit(choice);
    }

    static ShareNeedsChoice Read(string id, string batch)
    {
        var files = new List<string>();
        var links = new List<string>();
        foreach (var e in Directory.EnumerateFiles(batch))
        {
            var name = Path.GetFileName(e);
            if (name == "_links.json")
            {
                foreach (var v in JsonNode.Parse(File.ReadAllText(e))!.AsArray())
                    links.AddRange(SharedLinks.Parse((string?)v ?? ""));
            }
            else if (name != "_share.json") files.Add(e);
        }
        files.Sort(StringComparer.Ordinal);
        return new ShareNeedsChoice(id, batch, files, links);
    }

    /// Media dragged onto the window: copied into the inbox and offered on the share page. Nothing
    /// reaches the library before 导入, and the originals stay where they are.
    public async Task ImportDropped(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0) return;
        var id = "drop-" + DateTime.UtcNow.Ticks / 10;
        var inbox = Path.Combine(Root, "Inbox");
        var partial = Path.Combine(inbox, id + ".partial");
        await Task.Run(() =>
        {
            Directory.CreateDirectory(partial);
            var n = 0;
            try
            {
                foreach (var p in paths)
                {
                    if (Directory.Exists(p))
                        foreach (var f in Directory.EnumerateFiles(p, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }))
                            File.Copy(f, Path.Combine(partial, $"{n++}_{Path.GetFileName(f)}"));
                    else File.Copy(p, Path.Combine(partial, $"{n++}_{Path.GetFileName(p)}"));
                }
            }
            catch
            {
                Directory.Delete(partial, true);
                throw;
            }
            Directory.Move(partial, Path.Combine(inbox, id));
        });
        lock (_dropped) _dropped.Add(id);
        await Drain();
    }

    string StagingOf(string id) => Path.Combine(Root, "Staging", id);

    /// The share page downloads the links of share id into a staging folder, not the library.
    public Task<ShareStaged> Stage(string id, List<string> links)
    {
        var dir = StagingOf(id);
        Directory.CreateDirectory(dir);
        return TlCore.Run(() => TlCore.ShareStage(dir, links));
    }

    /// The person chose: what was shared goes into the library, in folder (or none).
    public async Task Confirm(ShareNeedsChoice batch, string? folder, bool staged)
    {
        lock (PendingChoices) PendingChoices.Remove(batch);
        await Task.Run(() =>
        {
            var staging = StagingOf(batch.Id);
            if (staged) TlCore.SharePack(staging, Path.Combine(batch.Directory, "post.tlpack"));
            var links = Path.Combine(batch.Directory, "_links.json");
            if (File.Exists(links)) File.Delete(links);
            bool dropped;
            lock (_dropped) dropped = _dropped.Remove(batch.Id);
            File.WriteAllText(Path.Combine(batch.Directory, "_share.json"), new JsonObject
            {
                ["version"] = 1, ["folder"] = folder ?? "", ["dropped"] = dropped, ["links"] = new JsonArray(),
            }.ToJsonString());
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
        });
        await Drain();
        // the import itself failed: said in the dialog (which stays), the batch kept for another try
        string? error;
        lock (_batchErrors) _batchErrors.Remove(batch.Id, out error);
        if (error != null) throw new IOException(Strings.L(error));
    }

    readonly Dictionary<string, string> _batchErrors = [];

    /// Closed without choosing: nothing was added anywhere.
    public async Task Discard(ShareNeedsChoice batch)
    {
        lock (PendingChoices) PendingChoices.Remove(batch);
        await Task.Run(() =>
        {
            foreach (var d in new[] { batch.Directory, StagingOf(batch.Id) })
                if (Directory.Exists(d)) Directory.Delete(d, true);
        });
        _asked.Remove(batch.Id);
    }

    /// 清除所有数据: what is waiting here and what was kept from earlier shares.
    public Task Wipe() => Task.Run(() =>
    {
        foreach (var name in new[] { "Inbox", "Kept", "Links", "Staging", "Requests", "RequestsDone" })
        {
            var d = Path.Combine(Root, name);
            if (Directory.Exists(d)) Directory.Delete(d, true);
        }
        lock (PendingChoices) PendingChoices.Clear();
        _asked.Clear();
    });

    /// Where this app keeps copies of what it imported (an import record may delete those with it).
    public static List<string> OwnedRoots() => [Root];

    public void Dispose()
    {
        _disposed = true;
        foreach (var w in _watchers) w.Dispose();
        _debounce?.Dispose();
    }
}

/// Is a file an image or a video, by its first bytes (a name may not say).
public static class MediaSniff
{
    public static bool IsMedia(string path)
    {
        Span<byte> h = stackalloc byte[16];
        using var f = File.OpenRead(path);
        var n = f.Read(h);
        if (n < 12) return false;
        if (h[0] == 0xFF && h[1] == 0xD8) return true;                         // JPEG
        if (h[0] == 0x89 && h[1] == 0x50 && h[2] == 0x4E && h[3] == 0x47) return true; // PNG
        if (h[0] == 'G' && h[1] == 'I' && h[2] == 'F') return true;              // GIF
        if (h[0] == 'R' && h[1] == 'I' && h[2] == 'F' && h[3] == 'F' && (h[8] == 'W' || h[8] == 'A')) return true; // WEBP, AVI
        if (h[4] == 'f' && h[5] == 't' && h[6] == 'y' && h[7] == 'p') return true; // MP4, MOV, HEIC, AVIF
        if (h[0] == 0x1A && h[1] == 0x45 && h[2] == 0xDF && h[3] == 0xA3) return true; // WebM, MKV
        if (h[0] == 'B' && h[1] == 'M') return true;                             // BMP
        return false;
    }
}
