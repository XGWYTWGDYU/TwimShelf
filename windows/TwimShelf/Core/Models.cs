// The core's JSON shapes (core/src: serde, snake_case), as flutter/tl_core/lib/src/models.dart
// reads them. Property names map by the snake_case policy of CoreJson; defaults are the core's.
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TwimShelf.Core;

/// Enums as the core writes them: snake_case strings (folder_add, replaced_new).
public sealed class SnakeEnum<T>() : JsonStringEnumConverter<T>(JsonNamingPolicy.SnakeCaseLower) where T : struct, Enum;

[JsonConverter(typeof(SnakeEnum<SearchScope>))]
public enum SearchScope { Mine, Ai, Both, Common }

[JsonConverter(typeof(SnakeEnum<MediaKind>))]
public enum MediaKind { Photo, Video }

[JsonConverter(typeof(SnakeEnum<ReviewFilter>))]
public enum ReviewFilter { Any, Unreviewed, Reviewed }

[JsonConverter(typeof(SnakeEnum<DownloadRoute>))]
public enum DownloadRoute { Auto, Fx, Cookie }

[JsonConverter(typeof(SnakeEnum<ActionKind>))]
public enum ActionKind { Trash, Restore, Purge, FolderAdd, FolderRemove, Tag }

[JsonConverter(typeof(SnakeEnum<RepairResult>))]
public enum RepairResult { Replaced, ReplacedNew, FromPeers }

[JsonConverter(typeof(SnakeEnum<AiAttemptStep>))]
public enum AiAttemptStep { Begin, Failed, Undo }

/// A tag on a media: origin 1 is the person's, 2 an AI model's (models: which).
public sealed class TagView
{
    public string Label { get; init; } = "";
    public int Origin { get; init; }
    public IReadOnlyList<string> Models { get; init; } = [];
    public bool IsAi => Origin == 2;
}

/// One media of the feed, with its post's text and tags.
public sealed class FeedItem
{
    public required string MediaId { get; init; }
    public required string PostId { get; init; }
    public int Ordinal { get; init; }
    public MediaKind Kind { get; init; }
    public required string Path { get; init; }
    public string? Text { get; init; }
    public string? AuthorName { get; init; }
    public string? ScreenName { get; init; }
    public string? Url { get; init; }
    public IReadOnlyList<TagView> Tags { get; init; } = [];
    public string? CreatedAt { get; init; }
    public string? Bad { get; init; }
    public bool Recent { get; init; }
    public bool Album { get; init; }
    /// Size as displayed, 0 until read from the file.
    public int Width { get; init; }
    public int Height { get; init; }

    public bool IsVideo => Kind == MediaKind.Video;
    public bool CanRedownload => Url != null || PostId.All(char.IsAsciiDigit) && PostId.Length > 0;

    /// A card's media, width per unit of height (4:5 until its size is known), kept within reason.
    public double CardAspectRatio => Width > 0 && Height > 0 ? Math.Clamp((double)Width / Height, 1 / 1.8, 1 / 0.3) : 4.0 / 5;
}

public sealed class Folder
{
    public required string Name { get; init; }
    public long Count { get; init; }
    public long Videos { get; init; }
    public string? CoverId { get; init; }
    public string? CoverPath { get; init; }
    public bool CoverVideo { get; init; }
}

public sealed class FolderOverview
{
    public List<Folder> Folders { get; init; } = [];
    public long Photos { get; init; }
    public long Videos { get; init; }
}

public sealed class SearchFields
{
    public bool Tags { get; set; } = true;
    public bool Text { get; set; }
    public bool Author { get; set; }
}

public sealed class FeedFilter
{
    public string? Author { get; set; }
    public List<string> Labels { get; set; } = [];
    public ReviewFilter Review { get; set; } = ReviewFilter.Any;
    public bool BadOnly { get; set; }
    public string? Folder { get; set; }
    public bool LooseOnly { get; set; }
    public bool AlbumOnly { get; set; }
    public bool RecentOnly { get; set; }
    public MediaKind? Kind { get; set; }
    public List<string> ExcludeTerms { get; set; } = [];
    public List<int>? Origins { get; set; }
    public List<string> ExcludeFolders { get; set; } = [];
    public bool ExcludeRecent { get; set; }
    public bool ExcludeLoose { get; set; }
    /// Conditions without words ("共同", "用户"): something in one of these fields (a tag that
    /// counts, post text, an author). All off: nothing.
    public SearchFields? Require { get; set; }
}

public sealed class FeedRequest
{
    public List<string> Terms { get; set; } = [];
    public SearchScope Scope { get; set; } = SearchScope.Both;
    public long? Seed { get; set; }
    public bool NewestFirst { get; set; }
    public bool Fuzzy { get; set; } = true;
    public List<List<double>?> TermVectors { get; set; } = [];
    public string? EmbedModel { get; set; }
    public double Threshold { get; set; } = 0.55;
    public SearchFields Fields { get; set; } = new();
    public FeedFilter Filter { get; set; } = new();
    /// Post cards: a post found through any of its media comes with all of them.
    public bool WholePosts { get; set; }
}

public sealed class ImportIssue
{
    public string Category { get; init; } = "";
    public string Path { get; init; } = "";
    public string Reason { get; init; } = "";
    public string? SameAs { get; init; }
}

public sealed class ImportReport
{
    public long Posts { get; init; }
    public long Media { get; init; }
    public List<string> Skipped { get; init; } = [];
    public long Deleted { get; init; }
    public long DuplicateMedia { get; init; }
    public long MergedPosts { get; init; }
    public long PostsWithoutMedia { get; init; }
    public long Entries { get; init; }
    public long SystemFiles { get; init; }
    public long Sidecars { get; init; }
    public long NewMedia { get; init; }
    public long Folders { get; init; }
    public List<ImportIssue> Issues { get; init; } = [];
    public string? ReportFile { get; init; }
    public string? Source { get; init; }
    public string? Folder { get; init; }
    public long FolderAdded { get; init; }
    public long ToBin { get; init; }
    public long RenamesRestored { get; init; }
    public long FoldersRestored { get; init; }
    public string? Incomplete { get; init; }
}

public sealed class ImportProgress
{
    public string Outcome { get; init; } = "";
    public bool Running { get; init; }
    public string Kind { get; init; } = "";
    public long FoldersDone { get; init; }
    public long FoldersTotal { get; init; }
    public long FilesDone { get; init; }
    public long Issues { get; init; }
    public string? Current { get; init; }
    public bool Waiting { get; init; }
}

public sealed class ExportOptions
{
    public bool Tags { get; set; } = true;
    public bool Folders { get; set; } = true;
    public bool MediaOnly { get; set; }
}

public sealed class ExportSkip
{
    public string MediaId { get; init; } = "";
    public string PostId { get; init; } = "";
    public string Reason { get; init; } = "";
}

public sealed class ExportReport
{
    public long Posts { get; init; }
    public long Media { get; init; }
    public long Bytes { get; init; }
    public long Trashed { get; init; }
    public List<ExportSkip> Skipped { get; init; } = [];
}

public sealed class ExportProgress
{
    public bool Running { get; init; }
    public long Done { get; init; }
    public long Total { get; init; }
    public long Bytes { get; init; }
}

public sealed class TagCount
{
    public string Label { get; init; } = "";
    public long Count { get; init; }
    public long User { get; init; }
    public long Ai { get; init; }
    /// What a list of tags reads out (screen readers name a row by its item).
    public override string ToString() => Label;
}

/// A model offered for download (core catalog.rs); names and notes are catalog keys.
public sealed class CatalogEntry
{
    public string Repo { get; init; } = "";
    public string Format { get; init; } = "";
    public string Role { get; init; } = "";
    public string NameKey { get; init; } = "";
    public string NoteKey { get; init; } = "";
    public string Folder { get; init; } = "";
    public string Tier { get; init; } = "unknown";
    public long Bytes { get; init; }
    public long RecommendGb { get; init; }
    public bool Uncensored { get; init; }
    public string? Weights { get; init; }
    public string? Projector { get; init; }
    public bool Embedder => Role == "embedder";
}

public sealed class HubDevice
{
    public long? MemoryBytes { get; init; }
    public long? FreeBytes { get; init; }
    public bool Mobile { get; init; }
    /// The GPU models run on; NoGpu: none, on-device models are off here.
    public string? Gpu { get; init; }
    public bool NoGpu { get; init; }
}

public sealed class HubRepo
{
    public string Repo { get; init; } = "";
    public string Format { get; init; } = "";
    public string Tier { get; init; } = "unknown";
    public string? Architecture { get; init; }
    public string? License { get; init; }
    public string? Sha { get; init; }
    public long? Params { get; init; }
    public long? EstimatedBytes { get; init; }
    public long Downloads { get; init; }
    public long Likes { get; init; }
    public bool ClaimsUncensored { get; init; }
}

public sealed class HubHidden
{
    public string Repo { get; init; } = "";
    public string Reason { get; init; } = "";
}

public sealed class HubPage
{
    public HubDevice Device { get; init; } = new();
    public List<HubRepo> Items { get; init; } = [];
    public List<HubHidden> Hidden { get; init; } = [];
    public string? Next { get; init; }
}

public sealed class HubVariant
{
    public string Label { get; init; } = "";
    public string Tier { get; init; } = "unknown";
    public string Folder { get; init; } = "";
    public string? Weights { get; init; }
    public string? Projector { get; init; }
    public long Bytes { get; init; }
    public bool Suggested { get; init; }
    public bool EnoughSpace { get; init; } = true;
}

public sealed class HubSkipped
{
    public string Name { get; init; } = "";
    public string Reason { get; init; } = "";
}

public sealed class HubDetail
{
    public HubRepo Repo { get; init; } = new();
    /// The repo's page on the site it comes from.
    public string PageUrl { get; init; } = "";
    public string Revision { get; init; } = "";
    public List<HubVariant> Variants { get; init; } = [];
    public List<HubSkipped> Skipped { get; init; } = [];
    public string? Problem { get; init; }
}

public sealed class UpdateInfo
{
    public string Version { get; init; } = "";
    public string PageUrl { get; init; } = "";
    public string Notes { get; init; } = "";
    public string? AssetName { get; init; }
    public string? AssetUrl { get; init; }
    public long AssetSize { get; init; }
    public string? AssetDigest { get; init; }
}

public sealed class StorageGroup
{
    public string Key { get; init; } = "";
    public long Bytes { get; init; }
    public long Files { get; init; }
}

public sealed class StorageUsage
{
    public List<StorageGroup> Groups { get; init; } = [];
    public long Total { get; init; }
}

public sealed class LibraryStats
{
    public long Posts { get; init; }
    public long Photos { get; init; }
    public long Videos { get; init; }
    public long Tags { get; init; }
    public long PendingJobs { get; init; }
    public long FailedJobs { get; init; }
    public long Trashed { get; init; }
    public long Bad { get; init; }
    public long NewerOps { get; init; }
}

public sealed class TrashItem
{
    public string MediaId { get; init; } = "";
    public string PostId { get; init; } = "";
    public int Ordinal { get; init; }
    public MediaKind Kind { get; init; }
    public string Path { get; init; } = "";
    public string? Text { get; init; }
    public string? AuthorName { get; init; }
    public string? ScreenName { get; init; }
    public string? Url { get; init; }
    public List<TagView> Tags { get; init; } = [];
    public long TrashedAtMs { get; init; }
}

public sealed class VerifyStatus
{
    public string Outcome { get; init; } = "";
    public long CompletedAt { get; init; }
    public bool Running { get; init; }
    public long Checked { get; init; }
    public long Total { get; init; }
    public long Bytes { get; init; }
    public long Bad { get; init; }
    public long Fixed { get; init; }
    public bool Finished { get; init; }
    public string? Current { get; init; }
}

public sealed class IntegritySummary
{
    public long Total { get; init; }
    public long Unchecked { get; init; }
    public long Bad { get; init; }
    public VerifyStatus? Last { get; init; }
}

public sealed class DownloadRequest
{
    public List<string> Urls { get; set; } = [];
    public int Concurrency { get; set; } = 3;
    public long IntervalMs { get; set; } = 500;
    public DownloadRoute Route { get; set; } = DownloadRoute.Auto;
    public bool Revive { get; set; }
    public string? Folder { get; set; }
    public bool MarkRecent { get; set; }
}

public sealed class DownloadStatus
{
    public string Outcome { get; init; } = "";
    public long Paused { get; init; }
    public bool Running { get; init; }
    public long Total { get; init; }
    public long Done { get; init; }
    public long Skipped { get; init; }
    public long Failed { get; init; }
    public List<string> Active { get; init; } = [];
    public List<List<string>> Errors { get; init; } = [];
    public long Generation { get; init; }
    public List<string> Recent { get; init; } = [];
}

public sealed class DeletedReports
{
    public long Reports { get; init; }
    public long Sources { get; init; }
    public long Bytes { get; init; }
}

public sealed class ActionStamp
{
    public string Id { get; set; } = "";
    public long Hlc { get; set; }
    public long Inc { get; set; }
    public int State { get; set; }
}

public sealed class ActionReceipt
{
    public ActionKind Kind { get; set; }
    public string? Label { get; set; }
    public string? Folder { get; set; }
    public long? FolderHlc { get; set; }
    public long Epoch { get; set; }
    public List<ActionStamp> Changes { get; set; } = [];
}

public sealed class BinSnapshot
{
    public List<ActionStamp> Entries { get; set; } = [];
    public long PendingCount { get; set; }
    public long Epoch { get; set; }
}

public sealed class MediaScope
{
    public List<string> Ids { get; init; } = [];
    public long PendingCount { get; init; }
    public Dictionary<string, List<string>> UserTags { get; init; } = [];
}

public sealed class ModelInfo
{
    public string Id { get; init; } = "";
    public string? Repo { get; init; }
    public string? ModelType { get; init; }
    public bool Vision { get; init; }
    public long Bytes { get; init; }
    public string Path { get; init; } = "";
    public string Format { get; init; } = "";
    public string? Weights { get; init; }
    public string? Projector { get; init; }
}

public sealed class ModelDownloadStatus
{
    public string Repo { get; init; } = "";
    public bool Running { get; init; }
    public bool Verifying { get; init; }
    public long TotalBytes { get; init; }
    public long DoneBytes { get; init; }
    public string File { get; init; } = "";
    public string? Error { get; init; }
    public bool Finished { get; init; }
}

public sealed class MediaRef
{
    public string MediaId { get; init; } = "";
    public string Path { get; init; } = "";
    public string Kind { get; init; } = "";
    public string? Text { get; init; }
}

public sealed class AiFailure
{
    public string MediaId { get; init; } = "";
    public string Model { get; init; } = "";
    public long Attempts { get; init; }
    public string Reason { get; init; } = "";
    public long At { get; init; }
}

public sealed class CookieCheck
{
    public string? ScreenName { get; init; }
    public string? Name { get; init; }
    public string? Error { get; init; }
}

public sealed class PeerInfo
{
    public string Device { get; init; } = "";
    public string Name { get; init; } = "";
    public long LastSync { get; init; }
    public string? LastError { get; init; }
    public string Addr { get; init; } = "";
    public long? ClockSkewMs { get; init; }
    public bool ClockWarning { get; init; }
}

public sealed class JoinState
{
    public bool Running { get; init; }
    public string? AccountKey { get; init; }
    public string? Error { get; init; }
}

public sealed class Transfer
{
    public long Received { get; init; }
    public long Total { get; init; }
    public long TotalBytes { get; init; }
    public long Bytes { get; init; }
    public long CurrentSize { get; init; }
    public long CurrentDone { get; init; }
    public string? LastPath { get; init; }
}

public sealed class SyncStatus
{
    public string? AccountId { get; init; }
    public string DeviceId { get; init; } = "";
    public string DeviceName { get; init; } = "";
    public int? Port { get; init; }
    public string? PairingCode { get; init; }
    public long? PairingSecondsLeft { get; init; }
    public List<PeerInfo> Peers { get; init; } = [];
    public long Syncing { get; init; }
    public long Changes { get; init; }
    public JoinState Join { get; init; } = new();
    public Transfer? Receiving { get; init; }
    public Dictionary<string, string> Failed { get; init; } = [];
    public List<string> InSession { get; init; } = [];
}

/// A device found on the local network (discovery::Peer).
public sealed class DiscoveredPeer
{
    public string Device { get; init; } = "";
    public string Name { get; init; } = "";
    public string? Account { get; init; }
    /// mac, iphone, ipad, android-phone, android-tablet, windows, linux (null: not said).
    public string? Kind { get; init; }
    public string? Host { get; init; }
    public int? Port { get; init; }
    public bool Reachable => Host != null && Port != null;
}

public sealed class DiscoveryStatus
{
    public bool NetworkOk { get; init; }
    public bool Running { get; init; }
    public List<DiscoveredPeer> Peers { get; init; } = [];
    public string? Error { get; init; }
}

/// A thumbnail: an image's cached JPEG, or a video (the app makes the poster).
public sealed class ThumbnailResult
{
    public string? Path { get; init; }
    public bool Video { get; init; }
}

public sealed class ShareStaged
{
    public required List<FeedItem> Items { get; init; }
    public required List<(string Link, string Reason)> Failed { get; init; }
}

public sealed class ExtensionClient
{
    public string Id { get; init; } = "";
    public string Name { get; init; } = "";
    public long Added { get; init; }
    public long Seen { get; init; }
}

public sealed class ExtensionPairing
{
    public string Code { get; init; } = "";
    public string Link { get; init; } = "";
    public List<string> Addresses { get; init; } = [];
    public long ExpiresIn { get; init; }
}

public sealed class ExtensionClients
{
    public List<ExtensionClient> Clients { get; init; } = [];
    public ExtensionPairing? Pairing { get; init; }
    public int? Port { get; init; }
}

/// The source-generated serializers (Native AOT: no reflection).
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower,
    DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    NumberHandling = JsonNumberHandling.AllowReadingFromString)]
[JsonSerializable(typeof(FeedRequest))]
[JsonSerializable(typeof(FolderOverview))]
[JsonSerializable(typeof(ImportReport))]
[JsonSerializable(typeof(ImportProgress))]
[JsonSerializable(typeof(ExportOptions))]
[JsonSerializable(typeof(ExportReport))]
[JsonSerializable(typeof(ExportProgress))]
[JsonSerializable(typeof(List<TagCount>))]
[JsonSerializable(typeof(List<CatalogEntry>))]
[JsonSerializable(typeof(HubDevice))]
[JsonSerializable(typeof(HubPage))]
[JsonSerializable(typeof(HubDetail))]
[JsonSerializable(typeof(UpdateInfo))]
[JsonSerializable(typeof(StorageUsage))]
[JsonSerializable(typeof(LibraryStats))]
[JsonSerializable(typeof(List<TrashItem>))]
[JsonSerializable(typeof(VerifyStatus))]
[JsonSerializable(typeof(IntegritySummary))]
[JsonSerializable(typeof(DownloadRequest))]
[JsonSerializable(typeof(DownloadStatus))]
[JsonSerializable(typeof(DeletedReports))]
[JsonSerializable(typeof(ActionReceipt))]
[JsonSerializable(typeof(BinSnapshot))]
[JsonSerializable(typeof(MediaScope))]
[JsonSerializable(typeof(List<ModelInfo>))]
[JsonSerializable(typeof(ModelInfo))]
[JsonSerializable(typeof(ModelDownloadStatus))]
[JsonSerializable(typeof(List<MediaRef>))]
[JsonSerializable(typeof(List<AiFailure>))]
[JsonSerializable(typeof(CookieCheck))]
[JsonSerializable(typeof(SyncStatus))]
[JsonSerializable(typeof(DiscoveryStatus))]
[JsonSerializable(typeof(ThumbnailResult))]
[JsonSerializable(typeof(ExtensionClients))]
[JsonSerializable(typeof(ExtensionPairing))]
[JsonSerializable(typeof(List<string>))]
[JsonSerializable(typeof(List<long>))]
[JsonSerializable(typeof(Dictionary<string, JsonElement>))]
[JsonSerializable(typeof(JsonElement))]
public partial class CoreJson : JsonSerializerContext;
