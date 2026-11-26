// The Rust core, called through its C ABI (Native.g.cs). Complex values cross as UTF-8 JSON in an
// {"ok": …} / {"error": "…"} envelope; every returned string is freed with tl_string_free. The
// same calls as flutter/tl_core/lib/tl_core.dart. Calls block: the UI runs them with Task.Run
// (the *Async helpers), as the Flutter app runs them in another isolate.
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization.Metadata;

namespace TwimShelf.Core;

public sealed class CoreException(string message) : Exception(message);

/// Why the core could not tag a picture: Kind is badUrl, http, noModel, empty, invalidResponse,
/// transport, timeout, cancelled, unreadable, badTags, noTags, noGpu or engine.
public sealed class AiException(string kind, int? status, string detail) : Exception(kind)
{
    public string Kind { get; } = kind;
    public int? Status { get; } = status;
    public string Detail { get; } = detail;
}

/// A thumbnail the core could not decode (handled without reading a localized message).
public sealed class ThumbnailNotDecodableException() : Exception("not_decodable");

public static unsafe class TlCore
{
    static CoreJson J => CoreJson.Default;

    // ---- envelope -------------------------------------------------------------------------

    static JsonElement Ok(nint p)
    {
        if (p == 0) throw new CoreException("core.noResult");
        try
        {
            var bytes = MemoryMarshal.CreateReadOnlySpanFromNullTerminated((byte*)p).ToArray();
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            if (root.TryGetProperty("error", out var e)) throw new CoreException(e.GetString() ?? "");
            if (!root.TryGetProperty("ok", out var ok)) throw new CoreException("core.emptyResult");
            return ok.Clone();
        }
        finally
        {
            Native.tl_string_free(p);
        }
    }

    static T Ok<T>(nint p, JsonTypeInfo<T> type) => Ok(p).Deserialize(type)!;

    /// [Ok], with an [AiException] for what the tagging functions report (core/src/ai/error.rs).
    static JsonElement OkAi(nint p)
    {
        if (p == 0) throw new CoreException("core.noResult");
        try
        {
            var bytes = MemoryMarshal.CreateReadOnlySpanFromNullTerminated((byte*)p).ToArray();
            using var doc = JsonDocument.Parse(bytes);
            var root = doc.RootElement;
            if (root.TryGetProperty("ai", out var ai))
            {
                var kind = ai.TryGetProperty("kind", out var k) ? k.GetString() ?? "engine" : "engine";
                int? status = ai.TryGetProperty("status", out var st) && st.ValueKind == JsonValueKind.Number ? st.GetInt32() : null;
                var detail = ai.TryGetProperty("detail", out var d) ? d.GetString() ?? "" : "";
                throw new AiException(kind, status, detail);
            }
            if (root.TryGetProperty("error", out var e)) throw new CoreException(e.GetString() ?? "");
            if (!root.TryGetProperty("ok", out var ok)) throw new CoreException("core.emptyResult");
            return ok.Clone();
        }
        finally
        {
            Native.tl_string_free(p);
        }
    }
    static T? OkOrNull<T>(nint p, JsonTypeInfo<T> type) where T : class
    {
        var e = Ok(p);
        return e.ValueKind == JsonValueKind.Null ? null : e.Deserialize(type);
    }
    static long OkLong(nint p) => Ok(p).GetInt64();
    static string OkString(nint p) => Ok(p).GetString() ?? "";
    static string? OkStringOrNull(nint p)
    {
        var e = Ok(p);
        return e.ValueKind == JsonValueKind.Null ? null : e.GetString();
    }
    static bool OkBool(nint p) => Ok(p).GetBoolean();
    static void Done(nint p) => Ok(p);

    static string Json<T>(T value, JsonTypeInfo<T> type) => JsonSerializer.Serialize(value, type);
    static string Json(JsonNode node) => node.ToJsonString();
    static JsonArray Strings(IEnumerable<string> v) => new(v.Select(s => (JsonNode?)JsonValue.Create(s)).ToArray());

    public static Task<T> Run<T>(Func<T> work) => Task.Run(work);
    public static Task Run(Action work) => Task.Run(work);

    // ---- library ----------------------------------------------------------------------------

    public static void SetLanguage(string tag) => Native.tl_set_language(tag);
    public static void SetAppName(string name) => Native.tl_set_app_name(name);
    public static bool Open(string dir) => Native.tl_open(dir);

    /// The feed, read in the core's compact form (PackedFeed in core/src/library.rs).
    public static List<FeedItem> Feed(FeedRequest request) => UnpackFeed(Ok(Native.tl_feed_packed(Json(request, J.FeedRequest))));

    public static bool MediaSizesFilling() => Native.tl_media_sizes_filling();

    static List<FeedItem> UnpackFeed(JsonElement packed)
    {
        var root = packed.GetProperty("root").GetString() ?? "";
        var posts = packed.GetProperty("posts");
        var lists = new List<IReadOnlyList<TagView>>();
        foreach (var l in packed.GetProperty("tag_lists").EnumerateArray())
        {
            var tags = new List<TagView>(l.GetArrayLength());
            foreach (var t in l.EnumerateArray())
            {
                var models = new List<string>();
                foreach (var m in t[2].EnumerateArray()) models.Add(m.GetString() ?? "");
                tags.Add(new TagView { Label = t[0].GetString() ?? "", Origin = t[1].GetInt32(), Models = models });
            }
            lists.Add(tags);
        }
        var postList = posts.EnumerateArray().ToArray();
        var media = packed.GetProperty("media");
        var items = new List<FeedItem>(media.GetArrayLength());
        foreach (var f in media.EnumerateArray())
        {
            var p = postList[f[1].GetInt32()];
            var path = f[4].GetString() ?? "";
            var bad = f[6].GetString() ?? "";
            items.Add(new FeedItem
            {
                MediaId = f[0].GetString() ?? "",
                PostId = Str(p, "id") ?? "",
                Ordinal = f[2].GetInt32(),
                Kind = f[3].GetString() == "v" ? MediaKind.Video : MediaKind.Photo,
                Path = path.StartsWith('/') || path.Contains(':') ? path : root + path,
                Text = Str(p, "text"),
                AuthorName = Str(p, "author_name"),
                ScreenName = Str(p, "screen_name"),
                Url = Str(p, "url"),
                CreatedAt = Str(p, "created_at"),
                Tags = lists[f[5].GetInt32()],
                Bad = bad.Length == 0 ? null : bad,
                Recent = Bool(p, "recent"),
                Album = Bool(p, "album"),
                Width = f[7].GetInt32(),
                Height = f[8].GetInt32(),
            });
        }
        return items;

        static string? Str(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        static bool Bool(JsonElement o, string k) => o.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    }

    public static LibraryStats Stats() => Ok(Native.tl_stats(), J.LibraryStats);
    public static long Epoch() => OkLong(Native.tl_epoch());
    public static string? Setting(string key) => OkStringOrNull(Native.tl_setting(key));
    public static void SetSetting(string key, string? value) => Done(Native.tl_set_setting(key, value));
    public static void DbSnapshot(string outPath) => Done(Native.tl_db_snapshot(outPath));
    public static void Wipe(bool includeModels) => Done(Native.tl_wipe(includeModels));
    public static StorageUsage StorageUsage(Dictionary<string, List<string>> extra)
    {
        var places = new JsonArray();
        foreach (var (key, paths) in extra)
            foreach (var p in paths) places.Add((JsonNode)new JsonObject { ["key"] = key, ["path"] = p });
        return Ok(Native.tl_storage_usage(Json(places)), J.StorageUsage);
    }

    // ---- tags -------------------------------------------------------------------------------

    public static void AddTag(string label, string mediaId, bool ai = false) => Done(Native.tl_tag(mediaId, label, (byte)(ai ? 2 : 1)));
    public static void RemoveTag(string label, string mediaId) => Done(Native.tl_untag(mediaId, label));
    public static List<TagCount> AllTags() => Ok(Native.tl_all_tags(), J.ListTagCount);
    public static string RenameTag(string from, string to) => OkString(Native.tl_rename_tag(from, to));
    public static long DeleteTag(string label) => OkLong(Native.tl_delete_tag(label));
    public static long RemoveAiTags() => OkLong(Native.tl_remove_ai_tags());
    public static List<string> MediaTags(string mediaId) => [.. Ok(Native.tl_media_tags(mediaId)).EnumerateArray().Select(r => r[0].GetString() ?? "")];
    public static long TagToFolder(string label, string folder) => OkLong(Native.tl_tag_to_folder(Json(new JsonObject { ["label"] = label, ["folder"] = folder })));

    // ---- folders ----------------------------------------------------------------------------

    public static List<(string Name, long Count)> Folders() => [.. Ok(Native.tl_folders()).EnumerateArray().Select(r => (r[0].GetString() ?? "", r[1].GetInt64()))];
    public static FolderOverview FolderOverview() => Ok(Native.tl_folder_overview(), J.FolderOverview);
    public static List<string> MediaFolders(string mediaId) => Ok(Native.tl_media_folders(mediaId), J.ListString);
    public static string CreateFolder(string name) => OkString(Native.tl_create_folder(name));
    public static void DeleteFolder(string name) => Done(Native.tl_delete_folder(name));
    public static long RenameFolder(string old, string to) => OkLong(Native.tl_rename_folder(Json(new JsonObject { ["old"] = old, ["new"] = to })));
    public static long AddToFolder(string name, IEnumerable<string>? media = null, IEnumerable<string>? posts = null) =>
        OkLong(Native.tl_folder_add(Json(new JsonObject { ["name"] = name, ["media"] = Strings(media ?? []), ["posts"] = Strings(posts ?? []) })));
    public static long RemoveFromFolder(string name, IEnumerable<string>? media = null, IEnumerable<string>? posts = null) =>
        OkLong(Native.tl_folder_remove(Json(new JsonObject { ["name"] = name, ["media"] = Strings(media ?? []), ["posts"] = Strings(posts ?? []) })));
    public static List<string> MediaIds(string folder) => [.. Feed(new FeedRequest { Filter = new FeedFilter { Folder = folder } }).Select(i => i.MediaId)];

    // ---- actions, trash ------------------------------------------------------------------------

    public static ActionReceipt Action(ActionKind kind, IEnumerable<string>? media = null, IEnumerable<string>? posts = null, string? folder = null, string? label = null, BinSnapshot? snapshot = null)
    {
        var o = new JsonObject
        {
            ["kind"] = JsonNamingPolicy.SnakeCaseLower.ConvertName(kind.ToString()),
            ["media"] = Strings(media ?? []),
            ["posts"] = Strings(posts ?? []),
            ["folder"] = folder,
            ["label"] = label,
            ["expected"] = snapshot == null ? null : JsonNode.Parse(JsonSerializer.Serialize(snapshot, J.BinSnapshot))!["entries"]!.DeepClone(),
            ["epoch"] = snapshot?.Epoch,
        };
        return Ok(Native.tl_action(Json(o)), J.ActionReceipt);
    }
    public static long Undo(ActionReceipt receipt) => OkLong(Native.tl_action_undo(Json(receipt, J.ActionReceipt)));
    public static BinSnapshot BinSnapshot(IReadOnlyCollection<string>? media = null)
    {
        var s = Ok(Native.tl_bin_snapshot(), J.BinSnapshot);
        if (media == null) return s;
        var ids = media.ToHashSet();
        return new BinSnapshot { Entries = [.. s.Entries.Where(e => ids.Contains(e.Id))], PendingCount = 0, Epoch = s.Epoch };
    }
    public static MediaScope PostScope(string post) => Ok(Native.tl_post_scope(post), J.MediaScope);
    public static long Trash(IEnumerable<string>? media = null, string? post = null) => OkLong(Native.tl_trash(Json(new JsonObject { ["media"] = Strings(media ?? []), ["post"] = post })));
    public static long Restore(IEnumerable<string> media) => OkLong(Native.tl_trash_restore(Json(new JsonObject { ["media"] = Strings(media) })));
    public static long Purge(IEnumerable<string> media) => OkLong(Native.tl_trash_purge(Json(new JsonObject { ["media"] = Strings(media) })));
    public static long EmptyTrash() => OkLong(Native.tl_trash_empty());
    public static List<TrashItem> TrashList() => Ok(Native.tl_trash_list(), J.ListTrashItem);
    public static long TrashKeepDays() => OkLong(Native.tl_trash_keep_days());
    public static void SetTrashKeepDays(uint days) => Done(Native.tl_set_trash_keep_days(days));
    public static long ExpireTrash() => OkLong(Native.tl_trash_expire());

    // ---- downloads ----------------------------------------------------------------------------

    public static List<string> BookmarkUrls(string path) => Ok(Native.tl_parse_bookmarks(path), J.ListString);
    public static long StartDownload(DownloadRequest r) => OkLong(Native.tl_download_start(Json(r, J.DownloadRequest)));
    public static DownloadStatus? DownloadStatus() => OkOrNull(Native.tl_download_status(), J.DownloadStatus);
    public static void CancelDownload() => Native.tl_download_cancel();
    public static long StopDownload(bool pause) => OkLong(Native.tl_download_stop(pause));
    public static long ResumeDownload(DownloadRequest r) => OkLong(Native.tl_download_resume(Json(r, J.DownloadRequest)));
    public static void SetCookies(string authToken, string ct0) => Native.tl_set_cookies(authToken, ct0);
    public static CookieCheck CheckCookies(string authToken, string ct0) => Ok(Native.tl_check_cookies(authToken, ct0), J.CookieCheck);
    public static List<CookieAccount> CookiesList() => Ok(Native.tl_cookies_list(), J.ListCookieAccount);
    public static CookieAccount CookieSave(string? id, string label, string authToken, string ct0, string? screenName = null) =>
        Ok(Native.tl_cookie_save(Json(new JsonObject
        {
            ["id"] = id,
            ["label"] = label,
            ["auth_token"] = authToken,
            ["ct0"] = ct0,
            ["screen_name"] = screenName,
        })), J.CookieAccount);
    public static bool CookieDelete(string id) => OkBool(Native.tl_cookie_delete(id));

    public static ShareStaged ShareStage(string dir, IEnumerable<string> urls, string route = "auto")
    {
        var v = Ok(Native.tl_share_stage(dir, Json(Strings(urls)), route));
        var items = new List<FeedItem>();
        foreach (var i in v.GetProperty("items").EnumerateArray()) items.Add(FeedItemFromJson(i));
        var failed = v.GetProperty("failed").EnumerateArray().Select(f => (f[0].GetString() ?? "", f[1].GetString() ?? "")).ToList();
        return new ShareStaged { Items = items, Failed = failed };
    }
    public static void SharePack(string dir, string outPath) => Done(Native.tl_share_pack(dir, outPath));

    static FeedItem FeedItemFromJson(JsonElement j)
    {
        string? S(string k) => j.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var tags = new List<TagView>();
        if (j.TryGetProperty("tags", out var ts) && ts.ValueKind == JsonValueKind.Array)
            foreach (var t in ts.EnumerateArray())
                tags.Add(new TagView
                {
                    Label = t.GetProperty("label").GetString() ?? "",
                    Origin = t.GetProperty("origin").GetInt32(),
                    Models = t.TryGetProperty("models", out var m) && m.ValueKind == JsonValueKind.Array ? m.EnumerateArray().Select(x => x.GetString() ?? "").ToList() : new List<string>(),
                });
        int w = 0, h = 0;
        if (j.TryGetProperty("size", out var size) && size.ValueKind == JsonValueKind.Array && size.GetArrayLength() == 2) { w = size[0].GetInt32(); h = size[1].GetInt32(); }
        return new FeedItem
        {
            MediaId = S("media_id") ?? "",
            PostId = S("post_id") ?? "",
            Ordinal = j.TryGetProperty("ordinal", out var o) ? o.GetInt32() : 0,
            Kind = S("kind") == "video" ? MediaKind.Video : MediaKind.Photo,
            Path = S("path") ?? "",
            Text = S("text"),
            AuthorName = S("author_name"),
            ScreenName = S("screen_name"),
            Url = S("url"),
            CreatedAt = S("created_at"),
            Bad = S("bad"),
            Recent = j.TryGetProperty("recent", out var r) && r.ValueKind == JsonValueKind.True,
            Album = j.TryGetProperty("album", out var a) && a.ValueKind == JsonValueKind.True,
            Tags = tags,
            Width = w,
            Height = h,
        };
    }

    // ---- import, export ----------------------------------------------------------------------

    public static ImportReport ImportLegacyDirectory(string dir) => Ok(Native.tl_import_legacy_dir(dir), J.ImportReport);
    public static ImportReport ImportLegacyZip(string path, string folder = "") => Ok(Native.tl_import_legacy_zip(path, folder), J.ImportReport);
    public static ImportReport ImportPack(string path, string folder = "") => Ok(Native.tl_import_pack(path, folder), J.ImportReport);
    public static ImportReport ImportLooseZip(string path, string folder = "") => Ok(Native.tl_import_loose_zip(path, folder), J.ImportReport);
    public static ImportReport ImportLooseDir(string dir, string? folder, bool consume, string? keepTo = null, bool album = true) =>
        Ok(Native.tl_import_loose_dir(Json(new JsonObject { ["dir"] = dir, ["folder"] = folder, ["consume"] = consume, ["keep_to"] = keepTo, ["album"] = album })), J.ImportReport);
    public static ImportProgress? ImportStatus() => OkOrNull(Native.tl_import_status(), J.ImportProgress);
    public static void CancelImport() => Native.tl_import_cancel();
    public static List<(string File, DateTime Date, string Source, long Issues)> ImportReports() =>
        [.. Ok(Native.tl_import_reports()).EnumerateArray().Select(r => (r[0].GetString() ?? "", DateTimeOffset.FromUnixTimeMilliseconds(r[1].GetInt64()).LocalDateTime, r[2].GetString() ?? "", r[3].GetInt64()))];
    public static ImportReport ImportReport(string path) => Ok(Native.tl_import_report(path), J.ImportReport);
    public static long ExportImportIssues(string report, string outZip) => OkLong(Native.tl_import_export_issues(report, outZip));
    public static DeletedReports DeleteImportReports(IEnumerable<string> files, IEnumerable<string> owned) =>
        Ok(Native.tl_delete_import_reports(Json(new JsonObject { ["reports"] = Strings(files), ["owned"] = Strings(owned) })), J.DeletedReports);

    public static ExportReport ExportMedia(IEnumerable<string> ids, string outPath, ExportOptions? options = null) =>
        Ok(Native.tl_export_media(Json(new JsonObject
        {
            ["media_ids"] = Strings(ids),
            ["out"] = outPath,
            ["options"] = JsonNode.Parse(Json(options ?? new ExportOptions(), J.ExportOptions)),
        })), J.ExportReport);
    public static ExportReport ExportBackup(string outPath) => Ok(Native.tl_export_backup(outPath), J.ExportReport);
    public static long ExportDiagnostics(string outPath, JsonObject appInfo) => OkLong(Native.tl_export_diagnostics(outPath, Json(appInfo)));
    public static ExportProgress? ExportStatus() => OkOrNull(Native.tl_export_status(), J.ExportProgress);
    public static bool CancelExport() => OkBool(Native.tl_export_cancel());

    // ---- integrity ----------------------------------------------------------------------------

    public static long StartVerify() => OkLong(Native.tl_verify_start());
    public static void CancelVerify() => Native.tl_verify_cancel();
    public static VerifyStatus? VerifyStatus() => OkOrNull(Native.tl_verify_status(), J.VerifyStatus);
    public static IntegritySummary IntegritySummary() => Ok(Native.tl_integrity_summary(), J.IntegritySummary);
    public static string? ReportBad(string mediaId) => OkStringOrNull(Native.tl_report_bad(mediaId));
    public static RepairResult Repair(string mediaId) => OkString(Native.tl_repair(mediaId)) switch
    {
        "replaced_new" => RepairResult.ReplacedNew,
        "from_peers" => RepairResult.FromPeers,
        _ => RepairResult.Replaced,
    };
    public static void ReportThumbnailFailed(string mediaId) => Done(Native.tl_report_thumbnail_failed(mediaId));

    // ---- thumbnails, images ----------------------------------------------------------------------

    public static ThumbnailResult Thumbnail(string mediaId, uint side, string cacheDir)
    {
        try { return Ok(Native.tl_thumbnail(mediaId, side, cacheDir), J.ThumbnailResult); }
        catch (CoreException e) when (e.Message == "not_decodable") { throw new ThumbnailNotDecodableException(); }
    }
    /// Warms missing square thumbnails on disk in the core's background coordinator.
    public static void WarmThumbnails(IEnumerable<string> mediaIds, uint side, string cacheDir) =>
        Done(Native.tl_thumbnails_warm(Json(Strings(mediaIds)), side, cacheDir));
    public static void CancelThumbnailsWarm() => Native.tl_thumbnails_warm_cancel();
    /// A HEIC or AVIF file as a JPEG Windows can show, at most maxSide on its long edge.
    public static string DisplayImage(string path, uint maxSide, string cacheDir) => OkString(Native.tl_display_image(path, maxSide, cacheDir));

    // ---- sync, discovery ----------------------------------------------------------------------

    public static string SyncNewAccount() => OkString(Native.tl_sync_new_account());
    public static long SyncStart(string accountKeyHex, string deviceName) => OkLong(Native.tl_sync_start(accountKeyHex, deviceName));
    public static SyncStatus SyncStatus() => Ok(Native.tl_sync_status(), J.SyncStatus);
    public static long SyncRestartListener() => OkLong(Native.tl_sync_restart_listener());
    public static string SyncPairBegin() => OkString(Native.tl_sync_pair_begin());
    public static void SyncPairCancel() => Native.tl_sync_pair_cancel();
    public static void SyncJoin(string host, int port, string code) => Done(Native.tl_sync_join(host, (ushort)port, code));
    public static void SyncReset() => Native.tl_sync_reset();
    public static ulong ModelExportZip(string id, string outPath) => (ulong)OkLong(Native.tl_model_export_zip(id, outPath));
    public static ModelInfo ModelImport(string path) => Ok(Native.tl_model_import(path), J.ModelInfo);
    public static List<ModelInfo> SyncPeerModels(string host, int port) => Ok(Native.tl_sync_peer_models(host, (ushort)port), J.ListModelInfo);
    public static void SyncPullModel(string host, int port, string id, string label, ulong total) => Done(Native.tl_sync_pull_model(host, (ushort)port, id, label, total));
    public static void DiscoveryStart(string serviceType, string deviceName, string deviceKind = "") => Done(Native.tl_discovery_start(serviceType, deviceName, deviceKind));
    public static DiscoveryStatus DiscoveryStatus() => Ok(Native.tl_discovery_status(), J.DiscoveryStatus);
    public static void DiscoveryChanged() => Native.tl_discovery_changed();
    public static void DiscoverySyncNow() => Native.tl_discovery_sync_now();
    public static void DiscoveryRediscover() => Native.tl_discovery_rediscover();
    public static void DiscoveryStop() => Native.tl_discovery_stop();

    // ---- browser extension ------------------------------------------------------------------------

    /// The extension's receiver: this device's name, platform and download settings; with listen
    /// the listener starts (once). Its port, or null.
    public static int? ExtensionServe(JsonObject options)
    {
        var v = Ok(Native.tl_ext_serve(Json(options)));
        return v.ValueKind == JsonValueKind.Number ? v.GetInt32() : null;
    }
    public static ExtensionPairing ExtensionPairBegin(IEnumerable<string>? addresses = null) =>
        Ok(Native.tl_ext_pair_begin(addresses == null ? "null" : Json(Strings(addresses))), J.ExtensionPairing);
    public static void ExtensionPairCancel() => Native.tl_ext_pair_cancel();
    public static ExtensionClients ExtensionClients() => Ok(Native.tl_ext_clients(), J.ExtensionClients);
    public static bool ExtensionRemove(string id) => OkBool(Native.tl_ext_remove(id));
    public static ExtensionManagedStatus ExtensionManagedStatus() => Ok(Native.tl_ext_managed_status(), J.ExtensionManagedStatus);
    public static ExtensionUpdateCheck ExtensionManagedCheck(string repo) => Ok(Native.tl_ext_managed_check(repo), J.ExtensionUpdateCheck);
    public static ExtensionManagedStatus ExtensionManagedInstall(string repo) => Ok(Native.tl_ext_managed_install(repo), J.ExtensionManagedStatus);
    public static bool ExtensionTakeOpenSettings() => Native.tl_ext_take_open_settings();

    // ---- secrets (Windows: in the data folder, sealed by the core) -----------------------------------

    public static string SecretKey() => OkString(Native.tl_secret_key());
    public static string SecretSeal(string key, string text) => OkString(Native.tl_secret_seal(key, text));
    public static string SecretOpen(string key, string blob) => OkString(Native.tl_secret_open(key, blob));

    // ---- updates ----------------------------------------------------------------------------

    /// The newer release (GitHub builds), null when this build is current. Blocks on the network.
    public static UpdateInfo? CheckUpdate(string repo, string current, IEnumerable<string> suffixes, string? arch) =>
        OkOrNull(Native.tl_update_check(Json(new JsonObject
        {
            ["repo"] = repo, ["current"] = current, ["suffixes"] = Strings(suffixes), ["flutter"] = false, ["arch"] = arch,
        })), J.UpdateInfo);
    /// Downloads and checks the release's installer into dir; its path. Blocks.
    public static string DownloadUpdate(UpdateInfo info, string dir) => OkString(Native.tl_update_download(Json(info, J.UpdateInfo), dir));

    // ---- AI ----------------------------------------------------------------------------------

    public static void SetModelsDirectory(string dir) => Done(Native.tl_set_models_dir(dir));
    public static List<CatalogEntry> ModelCatalog(string format) => Ok(Native.tl_model_catalog(format), J.ListCatalogEntry);
    /// Where models come from: <c>huggingface</c> or <c>modelscope</c> (kept beside the models).
    public static string ModelSource() => OkString(Native.tl_model_source());
    public static void SetModelSource(string name) => Done(Native.tl_set_model_source(name));
    public static HubDevice? HubDevice() => OkOrNull(Native.tl_hub_device(), J.HubDevice);
    public static HubPage HubSearch(string format, string query, bool uncensored, string? next) =>
        Ok(Native.tl_hub_search(Json(new JsonObject { ["format"] = format, ["query"] = query, ["uncensored"] = uncensored, ["next"] = next })), J.HubPage);
    public static HubDetail HubRepo(string format, string repo) => Ok(Native.tl_hub_repo(format, repo), J.HubDetail);
    public static void HubInstall(string format, string repo, string? revision, string? weights, string? projector, long bytes, string folder) =>
        Done(Native.tl_hub_install(Json(new JsonObject
        {
            ["format"] = format, ["repo"] = repo, ["revision"] = revision, ["weights"] = weights, ["projector"] = projector, ["bytes"] = bytes, ["folder"] = folder,
        })));
    public static ModelDownloadStatus? ModelStatus() => OkOrNull(Native.tl_model_status(), J.ModelDownloadStatus);
    public static void CancelModelDownload() => Native.tl_model_cancel();
    public static List<ModelInfo> InstalledModels() => Ok(Native.tl_models_installed(), J.ListModelInfo);
    public static void DeleteModel(string id) => Done(Native.tl_model_delete(id));
    public static List<string> LabelsMissingVectors(string model) => Ok(Native.tl_labels_missing_vectors(model), J.ListString);
    public static List<MediaRef> AiPending(long limit) => Ok(Native.tl_ai_pending(limit), J.ListMediaRef);
    public static List<MediaRef> AiPendingFor(string model, long since, long limit) => Ok(Native.tl_ai_pending_for(model, since, limit), J.ListMediaRef);
    public static List<AiFailure> AiFailures() => Ok(Native.tl_ai_failures(), J.ListAiFailure);
    public static long AiFailuresClear() => OkLong(Native.tl_ai_failures_clear());
    public static List<MediaRef> MediaPage(string after, long limit) => Ok(Native.tl_media_page(after, limit), J.ListMediaRef);
    public static (long Done, long Total) AiCounts()
    {
        var c = Ok(Native.tl_ai_counts(), J.ListInt64);
        return (c[0], c[1]);
    }
    public static void AiApply(string mediaId, string model, IEnumerable<string> labels, bool replaceOld = false, long? atEpoch = null) =>
        Done(Native.tl_ai_apply(Json(new JsonObject
        {
            ["media_id"] = mediaId, ["model"] = model, ["labels"] = Strings(labels), ["replace_old"] = replaceOld, ["epoch"] = atEpoch ?? Epoch(),
        })));
    public static void AiAttempt(AiAttemptStep step, string mediaId, string model, string reason = "") =>
        Done(Native.tl_ai_attempt(Json(new JsonObject
        {
            ["step"] = JsonNamingPolicy.SnakeCaseLower.ConvertName(step.ToString()), ["media_id"] = mediaId, ["model"] = model, ["reason"] = reason,
            ["now"] = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
        })));
    // ---- tagging with a vision model (core/src/ai): the core prepares the picture, asks the model
    // (this device's GPU, or a service) and reads the tags out of its reply

    public static void AiSetEngineDirectory(string dir) => Native.tl_ai_set_engine_dir(dir);

    /// The tags for one picture (a TagRequest, core/src/ai/mod.rs). Blocks: never on the UI thread.
    public static List<string> AiTag(JsonObject request) =>
        [.. OkAi(Native.tl_ai_tag(Json(request))).GetProperty("tags").EnumerateArray().Select(t => t.GetString() ?? "")];

    public static void AiCancel(string job) => Native.tl_ai_cancel(job);

    public static List<string> AiServiceModels(JsonObject service) =>
        [.. OkAi(Native.tl_ai_service_models(Json(service))).EnumerateArray().Select(t => t.GetString() ?? "")];

    /// What this device has for on-device AI: {engine, gpus, memory, chosen}.
    public static JsonElement AiHardware() => Ok(Native.tl_ai_hardware());

    public static void AiUnload() => Native.tl_ai_unload();

    public static void SetVectors(string model, IEnumerable<(string Label, IReadOnlyList<double> Vector)> items, long? atEpoch = null)
    {
        var arr = new JsonArray();
        foreach (var (label, vector) in items) arr.Add((JsonNode)new JsonArray(JsonValue.Create(label), new JsonArray(vector.Select(d => (JsonNode?)JsonValue.Create(d)).ToArray())));
        Done(Native.tl_set_vectors(Json(new JsonObject { ["model"] = model, ["epoch"] = atEpoch ?? Epoch(), ["items"] = arr })));
    }
}
