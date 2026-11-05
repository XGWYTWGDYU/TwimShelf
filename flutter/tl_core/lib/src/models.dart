// Wire keys intentionally retain Rust serde snake_case names.
// ignore_for_file: non_constant_identifier_names
abstract interface class JsonModel {
  Map<String, dynamic> toJson();
}

enum SearchScope {
  mine('mine'),
  ai('ai'),
  both('both'),
  common('common');

  const SearchScope(this.wireValue);
  final String wireValue;
}

enum MediaKind {
  photo('photo'),
  video('video');

  const MediaKind(this.wireValue);
  final String wireValue;
}

enum ReviewFilter {
  any('any'),
  unreviewed('unreviewed'),
  reviewed('reviewed');

  const ReviewFilter(this.wireValue);
  final String wireValue;
}

enum DownloadRoute {
  auto('auto'),
  fx('fx'),
  cookie('cookie');

  const DownloadRoute(this.wireValue);
  final String wireValue;
}

enum ActionKind {
  trash('trash'),
  restore('restore'),
  purge('purge'),
  folderAdd('folder_add'),
  folderRemove('folder_remove'),
  tag('tag');

  const ActionKind(this.wireValue);
  final String wireValue;
}

enum RepairResult {
  replaced('replaced'),
  replacedNew('replaced_new'),
  fromPeers('from_peers');

  const RepairResult(this.wireValue);
  final String wireValue;
}

enum AiAttemptStep {
  begin('begin'),
  failed('failed'),
  undo('undo');

  const AiAttemptStep(this.wireValue);
  final String wireValue;
}

class TagView implements JsonModel {
  TagView(
      {required this.label,
      required this.origin,
      List<String> models = const []})
      : models = List<String>.unmodifiable(models.map((v) => v));
  final String label;
  final int origin;
  final List<String> models;
  factory TagView.fromJson(Map<String, dynamic> json) => TagView(
        label: json['label'] as String,
        origin: (json['origin'] as num).toInt(),
        models: json['models'] == null
            ? const []
            : (json['models'] as List).map((v) => v as String).toList(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'label': label,
        'origin': origin,
        'models': models.map((v) => v).toList(),
      };
}

class FeedItem implements JsonModel {
  FeedItem(
      {required this.media_id,
      required this.post_id,
      required this.ordinal,
      required this.kind,
      required this.path,
      this.text,
      this.author_name,
      this.screen_name,
      this.url,
      List<TagView> tags = const [],
      this.created_at,
      this.bad,
      this.recent = false,
      this.album = false,
      this.width = 0,
      this.height = 0})
      : tags = List<TagView>.unmodifiable(tags.map((v) => v));
  /// Size as displayed, 0 until read from the file.
  final int width;
  final int height;

  /// There is a post to download this media from again: its link, or an id that makes one.
  bool get canRedownload => url != null || RegExp(r'^[0-9]+$').hasMatch(post_id);

  /// A card's media, width per unit of height: the media's own shape, so no bands around it. A
  /// very long or very wide one stays within reason and is fitted; 4:5 until its size is known.
  double get cardAspectRatio => width > 0 && height > 0 ? (width / height).clamp(1 / 1.8, 1 / 0.3) : 4 / 5;

  final String media_id;
  final String post_id;
  final int ordinal;
  final MediaKind kind;
  final String path;
  final String? text;
  final String? author_name;
  final String? screen_name;
  final String? url;
  final List<TagView> tags;
  final String? created_at;
  final String? bad;
  final bool recent;
  final bool album;
  factory FeedItem.fromJson(Map<String, dynamic> json) => FeedItem(
        media_id: json['media_id'] as String,
        post_id: json['post_id'] as String,
        ordinal: (json['ordinal'] as num).toInt(),
        kind: MediaKind.values.firstWhere((v) => v.wireValue == json['kind']),
        path: json['path'] as String,
        text: json['text'] == null ? null : json['text'] as String,
        author_name:
            json['author_name'] == null ? null : json['author_name'] as String,
        screen_name:
            json['screen_name'] == null ? null : json['screen_name'] as String,
        url: json['url'] == null ? null : json['url'] as String,
        tags: json['tags'] == null
            ? const []
            : (json['tags'] as List)
                .map((v) => TagView.fromJson(v as Map<String, dynamic>))
                .toList(),
        created_at:
            json['created_at'] == null ? null : json['created_at'] as String,
        bad: json['bad'] == null ? null : json['bad'] as String,
        recent: json['recent'] == null ? false : json['recent'] as bool,
        album: json['album'] == null ? false : json['album'] as bool,
        width: (json['size'] as List?)?.first as int? ?? 0,
        height: (json['size'] as List?)?.last as int? ?? 0,
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'post_id': post_id,
        'ordinal': ordinal,
        'kind': kind.wireValue,
        'path': path,
        'text': text == null ? null : text!,
        'author_name': author_name == null ? null : author_name!,
        'screen_name': screen_name == null ? null : screen_name!,
        'url': url == null ? null : url!,
        'tags': tags.map((v) => v.toJson()).toList(),
        'created_at': created_at == null ? null : created_at!,
        'bad': bad == null ? null : bad!,
        'recent': recent,
        'album': album,
      };
}

class Folder implements JsonModel {
  Folder(
      {required this.name,
      required this.count,
      required this.videos,
      this.cover_id,
      this.cover_path,
      required this.cover_video});
  final String name;
  final int count;
  final int videos;
  final String? cover_id;
  final String? cover_path;
  final bool cover_video;
  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
        name: json['name'] as String,
        count: (json['count'] as num).toInt(),
        videos: (json['videos'] as num).toInt(),
        cover_id: json['cover_id'] == null ? null : json['cover_id'] as String,
        cover_path:
            json['cover_path'] == null ? null : json['cover_path'] as String,
        cover_video: json['cover_video'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'name': name,
        'count': count,
        'videos': videos,
        'cover_id': cover_id == null ? null : cover_id!,
        'cover_path': cover_path == null ? null : cover_path!,
        'cover_video': cover_video,
      };
}

class FolderOverview implements JsonModel {
  FolderOverview(
      {required List<Folder> folders,
      required this.photos,
      required this.videos})
      : folders = List<Folder>.unmodifiable(folders.map((v) => v));
  final List<Folder> folders;
  final int photos;
  final int videos;
  factory FolderOverview.fromJson(Map<String, dynamic> json) => FolderOverview(
        folders: (json['folders'] as List)
            .map((v) => Folder.fromJson(v as Map<String, dynamic>))
            .toList(),
        photos: (json['photos'] as num).toInt(),
        videos: (json['videos'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'folders': folders.map((v) => v.toJson()).toList(),
        'photos': photos,
        'videos': videos,
      };
}

class SearchFields implements JsonModel {
  SearchFields({this.tags = true, this.text = false, this.author = false});
  final bool tags;
  final bool text;
  final bool author;
  factory SearchFields.fromJson(Map<String, dynamic> json) => SearchFields(
        tags: json['tags'] == null ? true : json['tags'] as bool,
        text: json['text'] == null ? false : json['text'] as bool,
        author: json['author'] == null ? false : json['author'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'tags': tags,
        'text': text,
        'author': author,
      };
}

class FeedFilter implements JsonModel {
  FeedFilter(
      {this.author,
      List<String> labels = const [],
      this.review = ReviewFilter.any,
      this.bad_only = false,
      this.folder,
      this.loose_only = false,
      this.album_only = false,
      this.recent_only = false,
      this.kind,
      List<String> exclude_terms = const [],
      List<int>? origins,
      List<String> exclude_folders = const [],
      this.exclude_recent = false,
      this.exclude_loose = false})
      : labels = List<String>.unmodifiable(labels.map((v) => v)),
        exclude_terms = List<String>.unmodifiable(exclude_terms.map((v) => v)),
        origins = origins == null
            ? null
            : List<int>.unmodifiable(origins.map((v) => v)),
        exclude_folders =
            List<String>.unmodifiable(exclude_folders.map((v) => v));
  final String? author;
  final List<String> labels;
  final ReviewFilter review;
  final bool bad_only;
  final String? folder;
  final bool loose_only;
  final bool album_only;
  final bool recent_only;
  final MediaKind? kind;
  final List<String> exclude_terms;
  final List<int>? origins;
  final List<String> exclude_folders;
  final bool exclude_recent;
  final bool exclude_loose;
  factory FeedFilter.fromJson(Map<String, dynamic> json) => FeedFilter(
        author: json['author'] == null ? null : json['author'] as String,
        labels: json['labels'] == null
            ? const []
            : (json['labels'] as List).map((v) => v as String).toList(),
        review: json['review'] == null
            ? ReviewFilter.any
            : ReviewFilter.values
                .firstWhere((v) => v.wireValue == json['review']),
        bad_only: json['bad_only'] == null ? false : json['bad_only'] as bool,
        folder: json['folder'] == null ? null : json['folder'] as String,
        loose_only:
            json['loose_only'] == null ? false : json['loose_only'] as bool,
        album_only: json['album_only'] == null ? false : json['album_only'] as bool,
        recent_only:
            json['recent_only'] == null ? false : json['recent_only'] as bool,
        kind: json['kind'] == null
            ? null
            : MediaKind.values.firstWhere((v) => v.wireValue == json['kind']),
        exclude_terms: json['exclude_terms'] == null
            ? const []
            : (json['exclude_terms'] as List).map((v) => v as String).toList(),
        origins: json['origins'] == null
            ? null
            : (json['origins'] as List).map((v) => (v as num).toInt()).toList(),
        exclude_folders: json['exclude_folders'] == null
            ? const []
            : (json['exclude_folders'] as List)
                .map((v) => v as String)
                .toList(),
        exclude_recent: json['exclude_recent'] == null
            ? false
            : json['exclude_recent'] as bool,
        exclude_loose: json['exclude_loose'] == null
            ? false
            : json['exclude_loose'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'author': author == null ? null : author!,
        'labels': labels.map((v) => v).toList(),
        'review': review.wireValue,
        'bad_only': bad_only,
        'folder': folder == null ? null : folder!,
        'loose_only': loose_only,
        'album_only': album_only,
        'recent_only': recent_only,
        'kind': kind == null ? null : kind!.wireValue,
        'exclude_terms': exclude_terms.map((v) => v).toList(),
        'origins': origins == null ? null : origins!.map((v) => v).toList(),
        'exclude_folders': exclude_folders.map((v) => v).toList(),
        'exclude_recent': exclude_recent,
        'exclude_loose': exclude_loose,
      };
}

class FeedRequest implements JsonModel {
  FeedRequest(
      {List<String> terms = const [],
      this.scope = SearchScope.both,
      this.seed,
      this.newest_first = false,
      this.fuzzy = true,
      List<List<double>?> term_vectors = const [],
      this.embed_model,
      this.threshold = 0.55,
      SearchFields? fields,
      FeedFilter? filter})
      : terms = List<String>.unmodifiable(terms.map((v) => v)),
        term_vectors = List<List<double>?>.unmodifiable(term_vectors.map((v) =>
            v == null ? null : List<double>.unmodifiable(v.map((v) => v)))),
        fields = fields ?? SearchFields(),
        filter = filter ?? FeedFilter();
  final List<String> terms;
  final SearchScope scope;
  final int? seed;
  final bool newest_first;
  final bool fuzzy;
  final List<List<double>?> term_vectors;
  final String? embed_model;
  final double threshold;
  final SearchFields fields;
  final FeedFilter filter;
  factory FeedRequest.fromJson(Map<String, dynamic> json) => FeedRequest(
        terms: json['terms'] == null
            ? const []
            : (json['terms'] as List).map((v) => v as String).toList(),
        scope: json['scope'] == null
            ? SearchScope.both
            : SearchScope.values
                .firstWhere((v) => v.wireValue == json['scope']),
        seed: json['seed'] == null ? null : (json['seed'] as num).toInt(),
        newest_first: json['newest_first'] == null ? false : json['newest_first'] as bool,
        fuzzy: json['fuzzy'] == null ? true : json['fuzzy'] as bool,
        term_vectors: json['term_vectors'] == null
            ? const []
            : (json['term_vectors'] as List)
                .map((v) => v == null
                    ? null
                    : (v as List).map((v) => (v as num).toDouble()).toList())
                .toList(),
        embed_model:
            json['embed_model'] == null ? null : json['embed_model'] as String,
        threshold: json['threshold'] == null
            ? 0.55
            : (json['threshold'] as num).toDouble(),
        fields: json['fields'] == null
            ? SearchFields()
            : SearchFields.fromJson(json['fields'] as Map<String, dynamic>),
        filter: json['filter'] == null
            ? FeedFilter()
            : FeedFilter.fromJson(json['filter'] as Map<String, dynamic>),
      );
  @override
  Map<String, dynamic> toJson() => {
        'terms': terms.map((v) => v).toList(),
        'scope': scope.wireValue,
        'seed': seed == null ? null : seed!,
        'newest_first': newest_first,
        'fuzzy': fuzzy,
        'term_vectors': term_vectors
            .map((v) => v == null ? null : v.map((v) => v).toList())
            .toList(),
        'embed_model': embed_model == null ? null : embed_model!,
        'threshold': threshold,
        'fields': fields.toJson(),
        'filter': filter.toJson(),
      };
}

class ImportIssue implements JsonModel {
  ImportIssue(
      {required this.category,
      required this.path,
      required this.reason,
      this.same_as});
  final String category;
  final String path;
  final String reason;
  final String? same_as;
  factory ImportIssue.fromJson(Map<String, dynamic> json) => ImportIssue(
        category: json['category'] as String,
        path: json['path'] as String,
        reason: json['reason'] as String,
        same_as: json['same_as'] == null ? null : json['same_as'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'category': category,
        'path': path,
        'reason': reason,
        'same_as': same_as == null ? null : same_as!,
      };
}

class ImportReport implements JsonModel {
  ImportReport(
      {required this.posts,
      required this.media,
      List<String> skipped = const [],
      this.deleted = 0,
      this.duplicate_media = 0,
      this.merged_posts = 0,
      this.posts_without_media = 0,
      this.entries = 0,
      this.system_files = 0,
      this.sidecars = 0,
      this.new_media = 0,
      this.folders = 0,
      List<ImportIssue> issues = const [],
      this.report_file,
      this.source,
      this.folder,
      this.folder_added = 0,
      this.to_bin = 0,
      this.renames_restored = 0,
      this.folders_restored = 0,
      this.incomplete})
      : skipped = List<String>.unmodifiable(skipped.map((v) => v)),
        issues = List<ImportIssue>.unmodifiable(issues.map((v) => v));
  final int posts;
  final int media;
  final List<String> skipped;
  final int deleted;
  final int duplicate_media;
  final int merged_posts;
  final int posts_without_media;
  final int entries;
  final int system_files;
  final int sidecars;
  final int new_media;
  final int folders;
  final List<ImportIssue> issues;
  final String? report_file;
  final String? source;
  final String? folder;
  final int folder_added;
  final int to_bin;
  final int renames_restored;
  final int folders_restored;
  /// Why it stopped short with something it can still do later: keep the source, try again.
  final String? incomplete;
  factory ImportReport.fromJson(Map<String, dynamic> json) => ImportReport(
        posts: (json['posts'] as num).toInt(),
        media: (json['media'] as num).toInt(),
        skipped: json['skipped'] == null
            ? const []
            : (json['skipped'] as List).map((v) => v as String).toList(),
        deleted: json['deleted'] == null ? 0 : (json['deleted'] as num).toInt(),
        duplicate_media: json['duplicate_media'] == null
            ? 0
            : (json['duplicate_media'] as num).toInt(),
        merged_posts: json['merged_posts'] == null
            ? 0
            : (json['merged_posts'] as num).toInt(),
        posts_without_media: json['posts_without_media'] == null
            ? 0
            : (json['posts_without_media'] as num).toInt(),
        entries: json['entries'] == null ? 0 : (json['entries'] as num).toInt(),
        system_files: json['system_files'] == null
            ? 0
            : (json['system_files'] as num).toInt(),
        sidecars:
            json['sidecars'] == null ? 0 : (json['sidecars'] as num).toInt(),
        new_media:
            json['new_media'] == null ? 0 : (json['new_media'] as num).toInt(),
        folders: json['folders'] == null ? 0 : (json['folders'] as num).toInt(),
        issues: json['issues'] == null
            ? const []
            : (json['issues'] as List)
                .map((v) => ImportIssue.fromJson(v as Map<String, dynamic>))
                .toList(),
        report_file:
            json['report_file'] == null ? null : json['report_file'] as String,
        source: json['source'] == null ? null : json['source'] as String,
        folder: json['folder'] == null ? null : json['folder'] as String,
        folder_added: json['folder_added'] == null
            ? 0
            : (json['folder_added'] as num).toInt(),
        to_bin: json['to_bin'] == null ? 0 : (json['to_bin'] as num).toInt(),
        renames_restored: json['renames_restored'] == null
            ? 0
            : (json['renames_restored'] as num).toInt(),
        folders_restored: json['folders_restored'] == null
            ? 0
            : (json['folders_restored'] as num).toInt(),
        incomplete: json['incomplete'] as String?,
      );
  @override
  Map<String, dynamic> toJson() => {
        'posts': posts,
        'media': media,
        'skipped': skipped.map((v) => v).toList(),
        'deleted': deleted,
        'duplicate_media': duplicate_media,
        'merged_posts': merged_posts,
        'posts_without_media': posts_without_media,
        'entries': entries,
        'system_files': system_files,
        'sidecars': sidecars,
        'new_media': new_media,
        'folders': folders,
        'issues': issues.map((v) => v.toJson()).toList(),
        'report_file': report_file == null ? null : report_file!,
        'source': source == null ? null : source!,
        'folder': folder == null ? null : folder!,
        'folder_added': folder_added,
        'to_bin': to_bin,
        'renames_restored': renames_restored,
        'folders_restored': folders_restored,
        if (incomplete != null) 'incomplete': incomplete,
      };
}

class ImportProgress implements JsonModel {
  ImportProgress(
      {required this.outcome,
      required this.running,
      required this.kind,
      required this.folders_done,
      required this.folders_total,
      required this.files_done,
      required this.issues,
      this.current,
      this.waiting = false});
  final String outcome;
  final bool running;
  final String kind;
  final int folders_done;
  final int folders_total;
  final int files_done;
  final int issues;
  final String? current;
  final bool waiting;
  factory ImportProgress.fromJson(Map<String, dynamic> json) => ImportProgress(
        outcome: json['outcome'] as String,
        running: json['running'] as bool,
        kind: json['kind'] as String,
        folders_done: (json['folders_done'] as num).toInt(),
        folders_total: (json['folders_total'] as num).toInt(),
        files_done: (json['files_done'] as num).toInt(),
        issues: (json['issues'] as num).toInt(),
        current: json['current'] == null ? null : json['current'] as String,
        waiting: json['waiting'] == null ? false : json['waiting'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'outcome': outcome,
        'running': running,
        'kind': kind,
        'folders_done': folders_done,
        'folders_total': folders_total,
        'files_done': files_done,
        'issues': issues,
        'current': current == null ? null : current!,
        'waiting': waiting,
      };
}

class ExportOptions implements JsonModel {
  ExportOptions(
      {this.tags = true, this.folders = true, this.media_only = false});
  final bool tags;
  final bool folders;
  final bool media_only;
  factory ExportOptions.fromJson(Map<String, dynamic> json) => ExportOptions(
        tags: json['tags'] == null ? true : json['tags'] as bool,
        folders: json['folders'] == null ? true : json['folders'] as bool,
        media_only:
            json['media_only'] == null ? false : json['media_only'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'tags': tags,
        'folders': folders,
        'media_only': media_only,
      };
}

class ExportSkip implements JsonModel {
  ExportSkip(
      {required this.media_id, required this.post_id, required this.reason});
  final String media_id;
  final String post_id;
  final String reason;
  factory ExportSkip.fromJson(Map<String, dynamic> json) => ExportSkip(
        media_id: json['media_id'] as String,
        post_id: json['post_id'] as String,
        reason: json['reason'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'post_id': post_id,
        'reason': reason,
      };
}

class ExportReport implements JsonModel {
  ExportReport(
      {required this.posts,
      required this.media,
      required this.bytes,
      this.trashed = 0,
      List<ExportSkip> skipped = const []})
      : skipped = List<ExportSkip>.unmodifiable(skipped.map((v) => v));
  final int posts;
  final int media;
  final int bytes;
  final int trashed;
  final List<ExportSkip> skipped;
  factory ExportReport.fromJson(Map<String, dynamic> json) => ExportReport(
        posts: (json['posts'] as num).toInt(),
        media: (json['media'] as num).toInt(),
        bytes: (json['bytes'] as num).toInt(),
        trashed: json['trashed'] == null ? 0 : (json['trashed'] as num).toInt(),
        skipped: json['skipped'] == null
            ? const []
            : (json['skipped'] as List)
                .map((v) => ExportSkip.fromJson(v as Map<String, dynamic>))
                .toList(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'posts': posts,
        'media': media,
        'bytes': bytes,
        'trashed': trashed,
        'skipped': skipped.map((v) => v.toJson()).toList(),
      };
}

class ExportProgress implements JsonModel {
  ExportProgress(
      {required this.running,
      required this.done,
      required this.total,
      required this.bytes});
  final bool running;
  final int done;
  final int total;
  final int bytes;
  factory ExportProgress.fromJson(Map<String, dynamic> json) => ExportProgress(
        running: json['running'] as bool,
        done: (json['done'] as num).toInt(),
        total: (json['total'] as num).toInt(),
        bytes: (json['bytes'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'running': running,
        'done': done,
        'total': total,
        'bytes': bytes,
      };
}

class TagCount implements JsonModel {
  TagCount(
      {required this.label,
      required this.count,
      required this.user,
      required this.ai});
  final String label;
  final int count;
  final int user;
  final int ai;
  factory TagCount.fromJson(Map<String, dynamic> json) => TagCount(
        label: json['label'] as String,
        count: (json['count'] as num).toInt(),
        user: (json['user'] as num).toInt(),
        ai: (json['ai'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'label': label,
        'count': count,
        'user': user,
        'ai': ai,
      };
}

/// A model offered for download (`tl-core` catalog.rs): names and notes are catalog keys.
class CatalogEntry {
  const CatalogEntry({required this.repo, required this.format, required this.role, required this.name_key, required this.note_key,
      required this.bytes, required this.folder, this.uncensored = false, this.recommend_gb = 0, this.weights, this.projector, this.tier = 'unknown'});
  final String repo, format, role, name_key, note_key, folder;
  /// How it fits this device: `recommended`, `usable`, `tooLarge` or `unknown`.
  final String tier;
  final int bytes, recommend_gb;
  final bool uncensored;
  final String? weights, projector;
  bool get embedder => role == 'embedder';
  factory CatalogEntry.fromJson(Map<String, dynamic> j) => CatalogEntry(
        repo: j['repo'] as String,
        format: j['format'] as String,
        role: j['role'] as String,
        name_key: j['name_key'] as String,
        note_key: j['note_key'] as String,
        bytes: (j['bytes'] as num).toInt(),
        folder: j['folder'] as String,
        uncensored: j['uncensored'] as bool? ?? false,
        recommend_gb: (j['recommend_gb'] as num?)?.toInt() ?? 0,
        weights: j['weights'] as String?,
        projector: j['projector'] as String?,
        tier: j['tier'] as String? ?? 'unknown',
      );
}

/// This device as the model store sees it (core/src/hub.rs).
class HubDevice {
  const HubDevice({this.memory_bytes, this.free_bytes, this.mobile = false});
  final int? memory_bytes, free_bytes;
  final bool mobile;
  factory HubDevice.fromJson(Map<String, dynamic> j) => HubDevice(memory_bytes: (j['memory_bytes'] as num?)?.toInt(), free_bytes: (j['free_bytes'] as num?)?.toInt(), mobile: j['mobile'] as bool? ?? false);
}

class HubRepo {
  const HubRepo({required this.repo, required this.format, this.architecture, this.params, this.downloads = 0, this.likes = 0, this.license, this.sha, this.claims_uncensored = false, this.estimated_bytes, this.tier = 'unknown'});
  final String repo, format, tier;
  final String? architecture, license, sha;
  final int? params, estimated_bytes;
  final int downloads, likes;
  final bool claims_uncensored;
  factory HubRepo.fromJson(Map<String, dynamic> j) => HubRepo(
        repo: j['repo'] as String,
        format: j['format'] as String,
        architecture: j['architecture'] as String?,
        params: (j['params'] as num?)?.toInt(),
        downloads: (j['downloads'] as num?)?.toInt() ?? 0,
        likes: (j['likes'] as num?)?.toInt() ?? 0,
        license: j['license'] as String?,
        sha: j['sha'] as String?,
        claims_uncensored: j['claims_uncensored'] as bool? ?? false,
        estimated_bytes: (j['estimated_bytes'] as num?)?.toInt(),
        tier: j['tier'] as String? ?? 'unknown',
      );
}

/// A result the store does not offer, and why: nothing is left out silently.
class HubHidden {
  const HubHidden({required this.repo, required this.reason});
  final String repo, reason;
  factory HubHidden.fromJson(Map<String, dynamic> j) => HubHidden(repo: j['repo'] as String, reason: j['reason'] as String);
}

class HubPage {
  const HubPage({required this.device, this.items = const [], this.hidden = const [], this.next});
  final HubDevice device;
  final List<HubRepo> items;
  final List<HubHidden> hidden;
  final String? next;
  factory HubPage.fromJson(Map<String, dynamic> j) => HubPage(
        device: HubDevice.fromJson(j['device'] as Map<String, dynamic>),
        items: (j['items'] as List).map((v) => HubRepo.fromJson(v as Map<String, dynamic>)).toList(),
        hidden: (j['hidden'] as List).map((v) => HubHidden.fromJson(v as Map<String, dynamic>)).toList(),
        next: j['next'] as String?,
      );
}

class HubVariant {
  const HubVariant({required this.label, this.weights, this.projector, required this.bytes, this.tier = 'unknown', this.suggested = false, this.enough_space = true, required this.folder});
  final String label, tier, folder;
  final String? weights, projector;
  final int bytes;
  final bool suggested, enough_space;
  factory HubVariant.fromJson(Map<String, dynamic> j) => HubVariant(
        label: j['label'] as String,
        weights: j['weights'] as String?,
        projector: j['projector'] as String?,
        bytes: (j['bytes'] as num).toInt(),
        tier: j['tier'] as String? ?? 'unknown',
        suggested: j['suggested'] as bool? ?? false,
        enough_space: j['enough_space'] as bool? ?? true,
        folder: j['folder'] as String,
      );
}

class HubSkipped {
  const HubSkipped({required this.name, required this.reason});
  final String name, reason;
  factory HubSkipped.fromJson(Map<String, dynamic> j) => HubSkipped(name: j['name'] as String, reason: j['reason'] as String);
}

class HubDetail {
  const HubDetail({required this.repo, required this.revision, this.variants = const [], this.skipped = const [], this.problem});
  final HubRepo repo;
  final String revision;
  final List<HubVariant> variants;
  final List<HubSkipped> skipped;
  final String? problem;
  factory HubDetail.fromJson(Map<String, dynamic> j) => HubDetail(
        repo: HubRepo.fromJson(j['repo'] as Map<String, dynamic>),
        revision: j['revision'] as String,
        variants: (j['variants'] as List).map((v) => HubVariant.fromJson(v as Map<String, dynamic>)).toList(),
        skipped: (j['skipped'] as List).map((v) => HubSkipped.fromJson(v as Map<String, dynamic>)).toList(),
        problem: j['problem'] as String?,
      );
}

class UpdateInfo implements JsonModel {
  UpdateInfo({required this.version, required this.page_url, this.notes = '', this.asset_name, this.asset_url, this.asset_size = 0, this.asset_digest});
  final String version;
  final String page_url;
  final String notes;
  final String? asset_name;
  final String? asset_url;
  final int asset_size;
  final String? asset_digest;
  factory UpdateInfo.fromJson(Map<String, dynamic> json) => UpdateInfo(
        version: json['version'] as String,
        page_url: json['page_url'] as String,
        notes: json['notes'] as String? ?? '',
        asset_name: json['asset_name'] as String?,
        asset_url: json['asset_url'] as String?,
        asset_size: (json['asset_size'] as num?)?.toInt() ?? 0,
        asset_digest: json['asset_digest'] as String?,
      );
  @override
  Map<String, dynamic> toJson() => {
        'version': version,
        'page_url': page_url,
        'notes': notes,
        'asset_name': asset_name,
        'asset_url': asset_url,
        'asset_size': asset_size,
        'asset_digest': asset_digest,
      };
}

class StorageGroup implements JsonModel {
  StorageGroup({required this.key, required this.bytes, required this.files});
  /// `storage.group.<key>` names it, `storage.group.<key>.detail` says what it holds.
  final String key;
  final int bytes;
  final int files;
  factory StorageGroup.fromJson(Map<String, dynamic> json) => StorageGroup(
        key: json['key'] as String,
        bytes: (json['bytes'] as num).toInt(),
        files: (json['files'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {'key': key, 'bytes': bytes, 'files': files};
}

class StorageUsage implements JsonModel {
  StorageUsage({required this.groups, required this.total});
  final List<StorageGroup> groups;
  final int total;
  factory StorageUsage.fromJson(Map<String, dynamic> json) => StorageUsage(
        groups: (json['groups'] as List).map((v) => StorageGroup.fromJson(v as Map<String, dynamic>)).toList(),
        total: (json['total'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {'groups': groups.map((g) => g.toJson()).toList(), 'total': total};
}

class LibraryStats implements JsonModel {
  LibraryStats(
      {required this.posts,
      required this.photos,
      required this.videos,
      required this.tags,
      required this.pending_jobs,
      required this.failed_jobs,
      this.trashed = 0,
      this.bad = 0,
      this.newer_ops = 0});
  final int posts;
  final int photos;
  final int videos;
  final int tags;
  final int pending_jobs;
  final int failed_jobs;
  final int trashed;
  final int bad;
  final int newer_ops;
  factory LibraryStats.fromJson(Map<String, dynamic> json) => LibraryStats(
        posts: (json['posts'] as num).toInt(),
        photos: (json['photos'] as num).toInt(),
        videos: (json['videos'] as num).toInt(),
        tags: (json['tags'] as num).toInt(),
        pending_jobs: (json['pending_jobs'] as num).toInt(),
        failed_jobs: (json['failed_jobs'] as num).toInt(),
        trashed: json['trashed'] == null ? 0 : (json['trashed'] as num).toInt(),
        bad: json['bad'] == null ? 0 : (json['bad'] as num).toInt(),
        newer_ops:
            json['newer_ops'] == null ? 0 : (json['newer_ops'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'posts': posts,
        'photos': photos,
        'videos': videos,
        'tags': tags,
        'pending_jobs': pending_jobs,
        'failed_jobs': failed_jobs,
        'trashed': trashed,
        'bad': bad,
        'newer_ops': newer_ops,
      };
}

class TrashItem implements JsonModel {
  TrashItem(
      {required this.media_id,
      required this.post_id,
      required this.ordinal,
      required this.kind,
      required this.path,
      this.text,
      this.author_name,
      this.screen_name,
      this.url,
      List<TagView> tags = const [],
      required this.trashed_at_ms})
      : tags = List<TagView>.unmodifiable(tags.map((v) => v));
  final String media_id;
  final String post_id;
  final int ordinal;
  final MediaKind kind;
  final String path;
  final String? text;
  final String? author_name;
  final String? screen_name;
  final String? url;
  final List<TagView> tags;
  final int trashed_at_ms;
  factory TrashItem.fromJson(Map<String, dynamic> json) => TrashItem(
        media_id: json['media_id'] as String,
        post_id: json['post_id'] as String,
        ordinal: (json['ordinal'] as num).toInt(),
        kind: MediaKind.values.firstWhere((v) => v.wireValue == json['kind']),
        path: json['path'] as String,
        text: json['text'] == null ? null : json['text'] as String,
        author_name:
            json['author_name'] == null ? null : json['author_name'] as String,
        screen_name:
            json['screen_name'] == null ? null : json['screen_name'] as String,
        url: json['url'] == null ? null : json['url'] as String,
        tags: json['tags'] == null
            ? const []
            : (json['tags'] as List)
                .map((v) => TagView.fromJson(v as Map<String, dynamic>))
                .toList(),
        trashed_at_ms: (json['trashed_at_ms'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'post_id': post_id,
        'ordinal': ordinal,
        'kind': kind.wireValue,
        'path': path,
        'text': text == null ? null : text!,
        'author_name': author_name == null ? null : author_name!,
        'screen_name': screen_name == null ? null : screen_name!,
        'url': url == null ? null : url!,
        'tags': tags.map((v) => v.toJson()).toList(),
        'trashed_at_ms': trashed_at_ms,
      };
}

class VerifyStatus implements JsonModel {
  VerifyStatus(
      {required this.outcome,
      required this.completed_at,
      required this.running,
      required this.checked,
      required this.total,
      required this.bytes,
      required this.bad,
      required this.fixed,
      required this.finished,
      this.current});
  final String outcome;
  final int completed_at;
  final bool running;
  final int checked;
  final int total;
  final int bytes;
  final int bad;
  final int fixed;
  final bool finished;
  final String? current;
  factory VerifyStatus.fromJson(Map<String, dynamic> json) => VerifyStatus(
        outcome: json['outcome'] as String,
        completed_at: (json['completed_at'] as num).toInt(),
        running: json['running'] as bool,
        checked: (json['checked'] as num).toInt(),
        total: (json['total'] as num).toInt(),
        bytes: (json['bytes'] as num).toInt(),
        bad: (json['bad'] as num).toInt(),
        fixed: (json['fixed'] as num).toInt(),
        finished: json['finished'] as bool,
        current: json['current'] == null ? null : json['current'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'outcome': outcome,
        'completed_at': completed_at,
        'running': running,
        'checked': checked,
        'total': total,
        'bytes': bytes,
        'bad': bad,
        'fixed': fixed,
        'finished': finished,
        'current': current == null ? null : current!,
      };
}

class IntegritySummary implements JsonModel {
  IntegritySummary(
      {required this.total,
      required this.unchecked,
      required this.bad,
      this.last});
  final int total;
  final int unchecked;
  final int bad;
  final VerifyStatus? last;
  factory IntegritySummary.fromJson(Map<String, dynamic> json) =>
      IntegritySummary(
        total: (json['total'] as num).toInt(),
        unchecked: (json['unchecked'] as num).toInt(),
        bad: (json['bad'] as num).toInt(),
        last: json['last'] == null
            ? null
            : VerifyStatus.fromJson(json['last'] as Map<String, dynamic>),
      );
  @override
  Map<String, dynamic> toJson() => {
        'total': total,
        'unchecked': unchecked,
        'bad': bad,
        'last': last == null ? null : last!.toJson(),
      };
}

class DownloadRequest implements JsonModel {
  DownloadRequest(
      {required List<String> urls,
      this.concurrency = 3,
      this.interval_ms = 500,
      this.route = DownloadRoute.auto,
      this.revive = false,
      this.folder,
      this.mark_recent = false})
      : urls = List<String>.unmodifiable(urls.map((v) => v));
  final List<String> urls;
  final int concurrency;
  final int interval_ms;
  final DownloadRoute route;
  final bool revive;
  final String? folder;
  final bool mark_recent;
  factory DownloadRequest.fromJson(Map<String, dynamic> json) =>
      DownloadRequest(
        urls: (json['urls'] as List).map((v) => v as String).toList(),
        concurrency: json['concurrency'] == null
            ? 3
            : (json['concurrency'] as num).toInt(),
        interval_ms: json['interval_ms'] == null
            ? 500
            : (json['interval_ms'] as num).toInt(),
        route: json['route'] == null
            ? DownloadRoute.auto
            : DownloadRoute.values
                .firstWhere((v) => v.wireValue == json['route']),
        revive: json['revive'] == null ? false : json['revive'] as bool,
        folder: json['folder'] == null ? null : json['folder'] as String,
        mark_recent:
            json['mark_recent'] == null ? false : json['mark_recent'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'urls': urls.map((v) => v).toList(),
        'concurrency': concurrency,
        'interval_ms': interval_ms,
        'route': route.wireValue,
        'revive': revive,
        'folder': folder == null ? null : folder!,
        'mark_recent': mark_recent,
      };
}

class DownloadStatus implements JsonModel {
  DownloadStatus(
      {required this.outcome,
      required this.paused,
      required this.running,
      required this.total,
      required this.done,
      required this.skipped,
      required this.failed,
      required List<String> active,
      required List<List<String>> errors,
      required this.generation,
      required List<String> recent})
      : active = List<String>.unmodifiable(active.map((v) => v)),
        errors = List<List<String>>.unmodifiable(
            errors.map((v) => List<String>.unmodifiable(v.map((v) => v)))),
        recent = List<String>.unmodifiable(recent.map((v) => v));
  final String outcome;
  final int paused;
  final bool running;
  final int total;
  final int done;
  final int skipped;
  final int failed;
  final List<String> active;
  final List<List<String>> errors;
  final int generation;
  final List<String> recent;
  factory DownloadStatus.fromJson(Map<String, dynamic> json) => DownloadStatus(
        outcome: json['outcome'] as String,
        paused: (json['paused'] as num).toInt(),
        running: json['running'] as bool,
        total: (json['total'] as num).toInt(),
        done: (json['done'] as num).toInt(),
        skipped: (json['skipped'] as num).toInt(),
        failed: (json['failed'] as num).toInt(),
        active: (json['active'] as List).map((v) => v as String).toList(),
        errors: (json['errors'] as List)
            .map((v) => (v as List).map((v) => v as String).toList())
            .toList(),
        generation: (json['generation'] as num).toInt(),
        recent: (json['recent'] as List).map((v) => v as String).toList(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'outcome': outcome,
        'paused': paused,
        'running': running,
        'total': total,
        'done': done,
        'skipped': skipped,
        'failed': failed,
        'active': active.map((v) => v).toList(),
        'errors': errors.map((v) => v.map((v) => v).toList()).toList(),
        'generation': generation,
        'recent': recent.map((v) => v).toList(),
      };
}

class DeletedReports implements JsonModel {
  DeletedReports(
      {required this.reports, required this.sources, required this.bytes});
  final int reports;
  final int sources;
  final int bytes;
  factory DeletedReports.fromJson(Map<String, dynamic> json) => DeletedReports(
        reports: (json['reports'] as num).toInt(),
        sources: (json['sources'] as num).toInt(),
        bytes: (json['bytes'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'reports': reports,
        'sources': sources,
        'bytes': bytes,
      };
}

class ActionStamp implements JsonModel {
  ActionStamp(
      {required this.id,
      required this.hlc,
      required this.inc,
      required this.state});
  final String id;
  final int hlc;
  final int inc;
  final int state;
  factory ActionStamp.fromJson(Map<String, dynamic> json) => ActionStamp(
        id: json['id'] as String,
        hlc: (json['hlc'] as num).toInt(),
        inc: (json['inc'] as num).toInt(),
        state: (json['state'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'hlc': hlc,
        'inc': inc,
        'state': state,
      };
}

class ActionReceipt implements JsonModel {
  ActionReceipt(
      {required this.kind,
      this.folder,
      this.folder_hlc,
      required this.epoch,
      required List<ActionStamp> changes})
      : changes = List<ActionStamp>.unmodifiable(changes.map((v) => v));
  final ActionKind kind;
  final String? folder;
  final int? folder_hlc;
  final int epoch;
  final List<ActionStamp> changes;
  factory ActionReceipt.fromJson(Map<String, dynamic> json) => ActionReceipt(
        kind: ActionKind.values.firstWhere((v) => v.wireValue == json['kind']),
        folder: json['folder'] == null ? null : json['folder'] as String,
        folder_hlc: json['folder_hlc'] == null
            ? null
            : (json['folder_hlc'] as num).toInt(),
        epoch: (json['epoch'] as num).toInt(),
        changes: (json['changes'] as List)
            .map((v) => ActionStamp.fromJson(v as Map<String, dynamic>))
            .toList(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'kind': kind.wireValue,
        'folder': folder == null ? null : folder!,
        'folder_hlc': folder_hlc == null ? null : folder_hlc!,
        'epoch': epoch,
        'changes': changes.map((v) => v.toJson()).toList(),
      };
}

class BinSnapshot implements JsonModel {
  BinSnapshot(
      {required List<ActionStamp> entries,
      required this.pending_count,
      required this.epoch})
      : entries = List<ActionStamp>.unmodifiable(entries.map((v) => v));
  final List<ActionStamp> entries;
  final int pending_count;
  final int epoch;
  factory BinSnapshot.fromJson(Map<String, dynamic> json) => BinSnapshot(
        entries: (json['entries'] as List)
            .map((v) => ActionStamp.fromJson(v as Map<String, dynamic>))
            .toList(),
        pending_count: (json['pending_count'] as num).toInt(),
        epoch: (json['epoch'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'entries': entries.map((v) => v.toJson()).toList(),
        'pending_count': pending_count,
        'epoch': epoch,
      };
}

class MediaScope implements JsonModel {
  MediaScope(
      {required List<String> ids,
      required this.pending_count,
      required Map<String, List<String>> user_tags})
      : ids = List<String>.unmodifiable(ids.map((v) => v)),
        user_tags = Map<String, List<String>>.unmodifiable(user_tags.map(
            (k, v) => MapEntry(k, List<String>.unmodifiable(v.map((v) => v)))));
  final List<String> ids;
  final int pending_count;
  final Map<String, List<String>> user_tags;
  factory MediaScope.fromJson(Map<String, dynamic> json) => MediaScope(
        ids: (json['ids'] as List).map((v) => v as String).toList(),
        pending_count: (json['pending_count'] as num).toInt(),
        user_tags: (json['user_tags'] as Map<String, dynamic>).map((k, v) =>
            MapEntry(k, (v as List).map((v) => v as String).toList())),
      );
  @override
  Map<String, dynamic> toJson() => {
        'ids': ids.map((v) => v).toList(),
        'pending_count': pending_count,
        'user_tags':
            user_tags.map((k, v) => MapEntry(k, v.map((v) => v).toList())),
      };
}

class ModelInfo implements JsonModel {
  ModelInfo(
      {required this.id,
      this.repo,
      this.model_type,
      required this.vision,
      required this.bytes,
      required this.path,
      this.format = 'mlx',
      this.weights,
      this.projector});
  final String id;
  final String? repo;
  final String? model_type;
  final bool vision;
  final int bytes;
  final String path;
  /// `mlx` (Apple devices) or `gguf` (llama.cpp: Android, Windows, Linux).
  final String format;
  /// GGUF only: the weights' file and a vision model's projector, in [path].
  final String? weights;
  final String? projector;
  factory ModelInfo.fromJson(Map<String, dynamic> json) => ModelInfo(
        id: json['id'] as String,
        repo: json['repo'] == null ? null : json['repo'] as String,
        model_type:
            json['model_type'] == null ? null : json['model_type'] as String,
        vision: json['vision'] as bool,
        bytes: (json['bytes'] as num).toInt(),
        path: json['path'] as String,
        format: json['format'] as String? ?? 'mlx',
        weights: json['weights'] as String?,
        projector: json['projector'] as String?,
      );
  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'repo': repo == null ? null : repo!,
        'model_type': model_type == null ? null : model_type!,
        'vision': vision,
        'bytes': bytes,
        'path': path,
        'format': format,
        'weights': weights,
        'projector': projector,
      };
}

class ModelDownloadStatus implements JsonModel {
  ModelDownloadStatus(
      {required this.repo,
      required this.running,
      required this.total_bytes,
      required this.done_bytes,
      required this.file,
      this.error,
      required this.finished,
      this.verifying = false});
  final String repo;
  final bool running;
  final bool verifying;
  final int total_bytes;
  final int done_bytes;
  final String file;
  final String? error;
  final bool finished;
  factory ModelDownloadStatus.fromJson(Map<String, dynamic> json) =>
      ModelDownloadStatus(
        repo: json['repo'] as String,
        running: json['running'] as bool,
        verifying: json['verifying'] as bool? ?? false,
        total_bytes: (json['total_bytes'] as num).toInt(),
        done_bytes: (json['done_bytes'] as num).toInt(),
        file: json['file'] as String,
        error: json['error'] == null ? null : json['error'] as String,
        finished: json['finished'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'repo': repo,
        'running': running,
        'total_bytes': total_bytes,
        'done_bytes': done_bytes,
        'file': file,
        'error': error == null ? null : error!,
        'finished': finished,
      };
}

class MediaRef implements JsonModel {
  MediaRef(
      {required this.media_id,
      required this.path,
      required this.kind,
      this.text});
  final String media_id;
  final String path;
  final String kind;
  final String? text;
  factory MediaRef.fromJson(Map<String, dynamic> json) => MediaRef(
        media_id: json['media_id'] as String,
        path: json['path'] as String,
        kind: json['kind'] as String,
        text: json['text'] == null ? null : json['text'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'path': path,
        'kind': kind,
        'text': text == null ? null : text!,
      };
}

class InterruptedModel implements JsonModel {
  InterruptedModel({required this.repo, required this.bytes});
  final String repo;
  final int bytes;
  factory InterruptedModel.fromJson(Map<String, dynamic> json) =>
      InterruptedModel(
        repo: json['repo'] as String,
        bytes: (json['bytes'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'repo': repo,
        'bytes': bytes,
      };
}

class AiFailure implements JsonModel {
  AiFailure(
      {required this.media_id,
      required this.model,
      required this.attempts,
      required this.reason,
      required this.at});
  final String media_id;
  final String model;
  final int attempts;
  final String reason;
  final int at;
  factory AiFailure.fromJson(Map<String, dynamic> json) => AiFailure(
        media_id: json['media_id'] as String,
        model: json['model'] as String,
        attempts: (json['attempts'] as num).toInt(),
        reason: json['reason'] as String,
        at: (json['at'] as num).toInt(),
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'model': model,
        'attempts': attempts,
        'reason': reason,
        'at': at,
      };
}

class CookieCheck implements JsonModel {
  CookieCheck({this.screen_name, this.name, this.error});
  final String? screen_name;
  final String? name;
  final String? error;
  factory CookieCheck.fromJson(Map<String, dynamic> json) => CookieCheck(
        screen_name:
            json['screen_name'] == null ? null : json['screen_name'] as String,
        name: json['name'] == null ? null : json['name'] as String,
        error: json['error'] == null ? null : json['error'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'screen_name': screen_name == null ? null : screen_name!,
        'name': name == null ? null : name!,
        'error': error == null ? null : error!,
      };
}

class PeerInfo implements JsonModel {
  PeerInfo(
      {required this.device,
      required this.name,
      required this.last_sync,
      this.last_error,
      required this.addr,
      this.clock_skew_ms,
      required this.clock_warning});
  final String device;
  final String name;
  final int last_sync;
  final String? last_error;
  final String addr;
  final int? clock_skew_ms;
  final bool clock_warning;
  factory PeerInfo.fromJson(Map<String, dynamic> json) => PeerInfo(
        device: json['device'] as String,
        name: json['name'] as String,
        last_sync: (json['last_sync'] as num).toInt(),
        last_error:
            json['last_error'] == null ? null : json['last_error'] as String,
        addr: json['addr'] as String,
        clock_skew_ms: json['clock_skew_ms'] == null
            ? null
            : (json['clock_skew_ms'] as num).toInt(),
        clock_warning: json['clock_warning'] as bool,
      );
  @override
  Map<String, dynamic> toJson() => {
        'device': device,
        'name': name,
        'last_sync': last_sync,
        'last_error': last_error == null ? null : last_error!,
        'addr': addr,
        'clock_skew_ms': clock_skew_ms == null ? null : clock_skew_ms!,
        'clock_warning': clock_warning,
      };
}

class JoinState implements JsonModel {
  JoinState({required this.running, this.account_key, this.error});
  final bool running;
  final String? account_key;
  final String? error;
  factory JoinState.fromJson(Map<String, dynamic> json) => JoinState(
        running: json['running'] as bool,
        account_key:
            json['account_key'] == null ? null : json['account_key'] as String,
        error: json['error'] == null ? null : json['error'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'running': running,
        'account_key': account_key == null ? null : account_key!,
        'error': error == null ? null : error!,
      };
}

class Transfer implements JsonModel {
  Transfer(
      {required this.received,
      required this.total,
      required this.total_bytes,
      required this.bytes,
      required this.current_size,
      required this.current_done,
      this.last_path});
  final int received;
  final int total;
  final int total_bytes;
  final int bytes;
  final int current_size;
  final int current_done;
  final String? last_path;
  factory Transfer.fromJson(Map<String, dynamic> json) => Transfer(
        received: (json['received'] as num).toInt(),
        total: (json['total'] as num).toInt(),
        total_bytes: (json['total_bytes'] as num).toInt(),
        bytes: (json['bytes'] as num).toInt(),
        current_size: (json['current_size'] as num).toInt(),
        current_done: (json['current_done'] as num).toInt(),
        last_path:
            json['last_path'] == null ? null : json['last_path'] as String,
      );
  @override
  Map<String, dynamic> toJson() => {
        'received': received,
        'total': total,
        'total_bytes': total_bytes,
        'bytes': bytes,
        'current_size': current_size,
        'current_done': current_done,
        'last_path': last_path == null ? null : last_path!,
      };
}

class SyncStatus implements JsonModel {
  SyncStatus(
      {this.account_id,
      required this.device_id,
      required this.device_name,
      this.port,
      this.pairing_code,
      this.pairing_seconds_left,
      required List<PeerInfo> peers,
      required this.syncing,
      required this.changes,
      required this.join,
      this.receiving,
      required Map<String, String> failed})
      : peers = List<PeerInfo>.unmodifiable(peers.map((v) => v)),
        failed = Map<String, String>.unmodifiable(
            failed.map((k, v) => MapEntry(k, v)));
  final String? account_id;
  final String device_id;
  final String device_name;
  final int? port;
  final String? pairing_code;
  final int? pairing_seconds_left;
  final List<PeerInfo> peers;
  final int syncing;
  final int changes;
  final JoinState join;
  final Transfer? receiving;
  final Map<String, String> failed;
  factory SyncStatus.fromJson(Map<String, dynamic> json) => SyncStatus(
        account_id:
            json['account_id'] == null ? null : json['account_id'] as String,
        device_id: json['device_id'] as String,
        device_name: json['device_name'] as String,
        port: json['port'] == null ? null : (json['port'] as num).toInt(),
        pairing_code: json['pairing_code'] == null
            ? null
            : json['pairing_code'] as String,
        pairing_seconds_left: json['pairing_seconds_left'] == null
            ? null
            : (json['pairing_seconds_left'] as num).toInt(),
        peers: (json['peers'] as List)
            .map((v) => PeerInfo.fromJson(v as Map<String, dynamic>))
            .toList(),
        syncing: (json['syncing'] as num).toInt(),
        changes: (json['changes'] as num).toInt(),
        join: JoinState.fromJson(json['join'] as Map<String, dynamic>),
        receiving: json['receiving'] == null
            ? null
            : Transfer.fromJson(json['receiving'] as Map<String, dynamic>),
        failed: (json['failed'] as Map<String, dynamic>)
            .map((k, v) => MapEntry(k, v as String)),
      );
  @override
  Map<String, dynamic> toJson() => {
        'account_id': account_id == null ? null : account_id!,
        'device_id': device_id,
        'device_name': device_name,
        'port': port == null ? null : port!,
        'pairing_code': pairing_code == null ? null : pairing_code!,
        'pairing_seconds_left':
            pairing_seconds_left == null ? null : pairing_seconds_left!,
        'peers': peers.map((v) => v.toJson()).toList(),
        'syncing': syncing,
        'changes': changes,
        'join': join.toJson(),
        'receiving': receiving == null ? null : receiving!.toJson(),
        'failed': failed.map((k, v) => MapEntry(k, v)),
      };
}

class ThumbnailItem implements JsonModel {
  ThumbnailItem(
      {required this.media_id, required this.path, required this.kind});
  final String media_id;
  final String path;
  final MediaKind kind;
  factory ThumbnailItem.fromJson(Map<String, dynamic> json) => ThumbnailItem(
        media_id: json['media_id'] as String,
        path: json['path'] as String,
        kind: MediaKind.values.firstWhere((v) => v.wireValue == json['kind']),
      );
  @override
  Map<String, dynamic> toJson() => {
        'media_id': media_id,
        'path': path,
        'kind': kind.wireValue,
      };
}

/// A video needs a front-end poster; an image has an atomic cached JPEG path.
sealed class ThumbnailResult implements JsonModel {
  const ThumbnailResult();
  factory ThumbnailResult.fromJson(Map<String, dynamic> json) {
    if (json['video'] == true) return const ThumbnailVideo();
    final path = json['path'];
    if (path is String && path.isNotEmpty) return ThumbnailImage(path);
    throw const FormatException('invalid_thumbnail_result');
  }
}

final class ThumbnailImage extends ThumbnailResult {
  const ThumbnailImage(this.path);
  final String path;
  @override
  Map<String, dynamic> toJson() => {'path': path};
}

final class ThumbnailVideo extends ThumbnailResult {
  const ThumbnailVideo();
  @override
  Map<String, dynamic> toJson() => {'video': true};
}

/// A device found on the local network (`discovery::Peer`).
class DiscoveredPeer {
  const DiscoveredPeer({required this.device, required this.name, this.account, this.kind, this.host, this.port});
  final String device;
  final String name;
  final String? account;
  /// mac, iphone, ipad, android-phone, android-tablet, windows, linux (null: not said).
  final String? kind;
  final String? host;
  final int? port;
  bool get reachable => host != null && port != null;
  factory DiscoveredPeer.fromJson(Map<String, dynamic> j) => DiscoveredPeer(
        device: j['device'] as String,
        name: j['name'] as String,
        account: j['account'] as String?,
        kind: j['kind'] as String?,
        host: j['host'] as String?,
        port: (j['port'] as num?)?.toInt(),
      );
}

/// Discovery's state (`discovery::DiscoveryStatus`).
class DiscoveryStatus {
  const DiscoveryStatus({required this.running, required this.peers, this.error, this.network_ok = false});
  final bool network_ok;
  final bool running;
  final List<DiscoveredPeer> peers;
  final String? error;
  factory DiscoveryStatus.fromJson(Map<String, dynamic> j) => DiscoveryStatus(
        running: j['running'] as bool,
        network_ok: j['network_ok'] as bool? ?? false,
        peers: (j['peers'] as List).map((p) => DiscoveredPeer.fromJson(p as Map<String, dynamic>)).toList(growable: false),
        error: j['error'] as String?,
      );
}

/// What a share page downloaded into its staging folder: the post's media, and the links that did
/// not come down with why.
class ShareStaged {
  const ShareStaged({required this.items, required this.failed});
  final List<FeedItem> items;
  final List<({String link, String reason})> failed;
}
