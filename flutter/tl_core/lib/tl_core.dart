library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'src/bindings.dart';
import 'src/models.dart';
export 'src/models.dart';
export 'src/bindings.dart';
export 'src/grid.dart';
export 'src/pet.dart';

DynamicLibrary openCoreLibrary() {
  if (Platform.isAndroid || Platform.isLinux)
    return DynamicLibrary.open('libtl_core.so');
  if (Platform.isWindows) return DynamicLibrary.open('tl_core.dll');
  if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
  throw UnsupportedError('core.unsupportedPlatform');
}

class CoreError implements Exception {
  const CoreError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Decode failures can be handled without parsing a localized message.
class ThumbnailNotDecodable extends CoreError {
  const ThumbnailNotDecodable() : super('not_decodable');
}

/// The process-wide native library is shared by calls made from any Dart isolate.
class Core {
  Core._();
  static final CoreBindings _bindings = CoreBindings(openCoreLibrary());
  static T _call<T>(T Function(Arena) action) => using(action);
  static Pointer<Utf8> _string(String? value, Arena arena) =>
      value == null ? nullptr : value.toNativeUtf8(allocator: arena);
  static Object? _read(Pointer<Utf8> pointer) {
    if (pointer == nullptr) throw const CoreError('core.noResult');
    try {
      final envelope =
          jsonDecode(pointer.toDartString()) as Map<String, dynamic>;
      if (envelope.containsKey('error'))
        throw CoreError(envelope['error'] as String);
      if (!envelope.containsKey('ok'))
        throw const CoreError('core.emptyResult');
      return envelope['ok'];
    } finally {
      _bindings.tl_string_free(pointer);
    }
  }

  /// Decode a caller-owned envelope and transfer ownership to this helper.
  static T decodeOk<T>(Pointer<Utf8> pointer, T Function(Object?) decode) =>
      decode(_read(pointer));

  static String? _raw(Pointer<Utf8> pointer) {
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      _bindings.tl_string_free(pointer);
    }
  }

  static String? fxAPIURL(String url) =>
      _call((arena) => _raw(_bindings.tl_fx_api_url(_string(url, arena))));
  static void setLanguage(String tag) => _call((arena) {
        _bindings.tl_set_language(_string(tag, arena));
      });
  static void setAppName(String name) => _call((arena) {
        _bindings.tl_set_app_name(_string(name, arena));
      });
  static bool open(String dir) =>
      _call((arena) => _bindings.tl_open(_string(dir, arena)));
  static List<ThumbnailItem> _rawThumbnailItems() => _call((arena) {
        final value = _read(_bindings.tl_thumbnail_items());
        return (value as List)
            .map((v) => ThumbnailItem.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  /// The feed, read in the core's compact form (`PackedFeed` in core/src/library.rs: each post
  /// and tag list once, paths relative to the library), a quarter of the data for a large
  /// library; every media of a post shares one copy of its text.
  static List<FeedItem> feed(FeedRequest requestJson) => _call((arena) {
        final value = _read(_bindings
            .tl_feed_packed(_string(jsonEncode(requestJson.toJson()), arena)));
        return unpackFeed(value as Map<String, dynamic>);
      });

  /// Items of a `PackedFeed`.
  /// Whether media sizes are still being read in the background.
  static bool mediaSizesFilling() => _bindings.tl_media_sizes_filling();

  static List<FeedItem> unpackFeed(Map<String, dynamic> packed) {
    final root = packed['root'] as String;
    final posts = packed['posts'] as List;
    final lists = (packed['tag_lists'] as List)
        .map((l) => (l as List).map((t) {
              final f = t as List;
              return TagView(label: f[0] as String, origin: (f[1] as num).toInt(),
                  models: (f[2] as List).cast<String>());
            }).toList(growable: false))
        .toList(growable: false);
    return (packed['media'] as List).map((m) {
      final f = m as List;
      final p = posts[(f[1] as num).toInt()] as Map<String, dynamic>;
      final path = f[4] as String;
      final bad = f[6] as String;
      return FeedItem(
        media_id: f[0] as String,
        post_id: p['id'] as String,
        ordinal: (f[2] as num).toInt(),
        kind: f[3] == 'v' ? MediaKind.video : MediaKind.photo,
        path: path.startsWith('/') || path.contains(':') ? path : root + path,
        text: p['text'] as String?,
        author_name: p['author_name'] as String?,
        screen_name: p['screen_name'] as String?,
        url: p['url'] as String?,
        created_at: p['created_at'] as String?,
        tags: lists[(f[5] as num).toInt()],
        bad: bad.isEmpty ? null : bad,
        recent: p['recent'] as bool? ?? false,
        album: p['album'] as bool? ?? false,
        width: (f[7] as num).toInt(),
        height: (f[8] as num).toInt(),
      );
    }).toList();
  }
  static ImportReport importLegacyDirectory(String dir) => _call((arena) {
        final value =
            _read(_bindings.tl_import_legacy_dir(_string(dir, arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportReport> importLegacyDirectoryAsync(String dir) =>
      Isolate.run(() => importLegacyDirectory(dir));
  static ImportReport importLegacyZip(String path, [String folder = '']) =>
      _call((arena) {
        final value = _read(_bindings.tl_import_legacy_zip(
            _string(path, arena), _string(folder, arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportReport> importLegacyZipAsync(
          String path, String folder) =>
      Isolate.run(() => importLegacyZip(path, folder));
  static ImportReport importPack(String path, [String folder = '']) =>
      _call((arena) {
        final value = _read(_bindings.tl_import_pack(
            _string(path, arena), _string(folder, arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportReport> importPackAsync(String path,
          [String folder = '']) =>
      Isolate.run(() => importPack(path, folder));
  static ExportReport _rawExportMedia(Map<String, dynamic> argsJson) =>
      _call((arena) {
        final value = _read(
            _bindings.tl_export_media(_string(jsonEncode(argsJson), arena)));
        return ExportReport.fromJson(value as Map<String, dynamic>);
      });

  static List<String> bookmarkURLs(String path) => _call((arena) {
        final value = _read(_bindings.tl_parse_bookmarks(_string(path, arena)));
        return (value as List).map((v) => v as String).toList();
      });
  static int startDownload(DownloadRequest requestJson) => _call((arena) {
        final value = _read(_bindings.tl_download_start(
            _string(jsonEncode(requestJson.toJson()), arena)));
        return (value as num).toInt();
      });
  static Future<int> startDownloadAsync(DownloadRequest requestJson) =>
      Isolate.run(() => startDownload(requestJson));
  static DownloadStatus? downloadStatus() => _call((arena) {
        final value = _read(_bindings.tl_download_status());
        return value == null
            ? null
            : DownloadStatus.fromJson(value as Map<String, dynamic>);
      });
  static Future<DownloadStatus?> downloadStatusAsync() =>
      Isolate.run(() => downloadStatus());
  static void cancelDownload() => _call((arena) {
        _bindings.tl_download_cancel();
      });
  static Future<void> cancelDownloadAsync() =>
      Isolate.run(() => cancelDownload());
  static void setCookies(String authToken, String ct0) => _call((arena) {
        _bindings.tl_set_cookies(
            _string(authToken, arena), _string(ct0, arena));
      });
  static void addTag(String label, String mediaId, {bool ai = false}) =>
      _call((arena) {
        _read(_bindings.tl_tag(
            _string(mediaId, arena), _string(label, arena), ai ? 2 : 1));
      });
  static void removeTag(String label, String mediaId) => _call((arena) {
        _read(
            _bindings.tl_untag(_string(mediaId, arena), _string(label, arena)));
      });
  static List<TagCount> allTags() => _call((arena) {
        final value = _read(_bindings.tl_all_tags());
        return (value as List)
            .map((v) => TagCount.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static LibraryStats stats() => _call((arena) {
        final value = _read(_bindings.tl_stats());
        return LibraryStats.fromJson(value as Map<String, dynamic>);
      });
  /// 检查更新 (GitHub builds): the newer release, null when this build is current. Blocks on
  /// the network: run it off the UI isolate.
  static UpdateInfo? checkUpdate({required String repo, required String current, List<String> suffixes = const [], String? arch}) => _call((arena) {
        final q = {'repo': repo, 'current': current, 'suffixes': suffixes, 'flutter': true, 'arch': arch};
        final value = _read(_bindings.tl_update_check(_string(jsonEncode(q), arena)));
        return value == null ? null : UpdateInfo.fromJson(value as Map<String, dynamic>);
      });
  /// Downloads and checks the release's installer into [dir]; its path. Blocks.
  static String downloadUpdate(UpdateInfo info, String dir) => _call((arena) {
        final value = _read(_bindings.tl_update_download(_string(jsonEncode(info.toJson()), arena), _string(dir, arena)));
        return value as String;
      });
  /// 存储空间 by group; [extra] are the app's own places (key → path). Walks folders: run it
  /// off the UI isolate.
  static StorageUsage storageUsage(Map<String, List<String>> extra) => _call((arena) {
        final places = [
          for (final e in extra.entries)
            for (final p in e.value) {'key': e.key, 'path': p}
        ];
        final value = _read(_bindings.tl_storage_usage(_string(jsonEncode(places), arena)));
        return StorageUsage.fromJson(value as Map<String, dynamic>);
      });
  /// A shared link: downloads into the staging folder [dir], not the library. Blocks: off the main
  /// isolate.
  static ShareStaged shareStage(String dir, List<String> urls, {String route = 'auto'}) => _call((arena) {
        final value = _read(_bindings.tl_share_stage(_string(dir, arena), _string(jsonEncode(urls), arena), _string(route, arena))) as Map<String, dynamic>;
        return ShareStaged(
          items: [for (final i in value['items'] as List) FeedItem.fromJson(i as Map<String, dynamic>)],
          failed: [for (final f in value['failed'] as List) (link: (f as List)[0] as String, reason: f[1] as String)],
        );
      });

  /// The staging folder [dir] as a `.tlpack` at [out], to import when the person says so.
  static void sharePack(String dir, String out) => _call((arena) {
        _read(_bindings.tl_share_pack(_string(dir, arena), _string(out, arena)));
      });

  static void reportThumbnailFailed(String mediaId) => _call((arena) {
        _read(_bindings.tl_report_thumbnail_failed(_string(mediaId, arena)));
      });
  /// A consistent copy of the database at [out] (off the main isolate).
  static void dbSnapshot(String out) => _call((arena) {
        _read(_bindings.tl_db_snapshot(_string(out, arena)));
      });

  /// Free bytes on the volume of [path]; null when the system does not say.
  static int? freeSpace(String path) => _call((arena) => (_read(_bindings.tl_free_space(_string(path, arena))) as num?)?.toInt());
  static void wipe({bool includeModels = false}) => _call((arena) {
        _read(_bindings.tl_wipe(includeModels));
      });
  static Future<void> wipeAsync({bool includeModels = false}) =>
      Isolate.run(() => wipe(includeModels: includeModels));
  static List<String> labelsMissingVectors(String model) => _call((arena) {
        final value =
            _read(_bindings.tl_labels_missing_vectors(_string(model, arena)));
        return (value as List).map((v) => v as String).toList();
      });
  static void _setVectors(Map<String, dynamic> json) => _call((arena) {
        _read(_bindings.tl_set_vectors(_string(jsonEncode(json), arena)));
      });
  static String syncNewAccount() => _call((arena) {
        final value = _read(_bindings.tl_sync_new_account());
        return value as String;
      });
  static Future<String> syncNewAccountAsync() =>
      Isolate.run(() => syncNewAccount());
  /// Starts finding the account's devices and syncing with them (after [syncStart]).
  static void discoveryStart(String serviceType, String deviceName, [String deviceKind = '']) => _call((arena) {
        _read(_bindings.tl_discovery_start(_string(serviceType, arena), _string(deviceName, arena), _string(deviceKind, arena)));
      });
  static DiscoveryStatus discoveryStatus() => _call((arena) =>
      DiscoveryStatus.fromJson(_read(_bindings.tl_discovery_status()) as Map<String, dynamic>));
  /// The library changed on this device: sync shortly.
  static void discoveryChanged() => _bindings.tl_discovery_changed();
  static void discoverySyncNow() => _bindings.tl_discovery_sync_now();
  static void discoveryRediscover() => _bindings.tl_discovery_rediscover();
  static void discoveryStop() => _bindings.tl_discovery_stop();
  static int syncStart(String accountKeyHex, String deviceName) =>
      _call((arena) {
        final value = _read(_bindings.tl_sync_start(
            _string(accountKeyHex, arena), _string(deviceName, arena)));
        return (value as num).toInt();
      });
  static Future<int> syncStartAsync(String accountKeyHex, String deviceName) =>
      Isolate.run(() => syncStart(accountKeyHex, deviceName));
  static SyncStatus syncStatus() => _call((arena) {
        final value = _read(_bindings.tl_sync_status());
        return SyncStatus.fromJson(value as Map<String, dynamic>);
      });
  static Future<SyncStatus> syncStatusAsync() =>
      Isolate.run(() => syncStatus());
  static int syncRestartListener() => _call((arena) {
        final value = _read(_bindings.tl_sync_restart_listener());
        return (value as num).toInt();
      });
  static Future<int> syncRestartListenerAsync() =>
      Isolate.run(() => syncRestartListener());
  static String syncPairBegin() => _call((arena) {
        final value = _read(_bindings.tl_sync_pair_begin());
        return value as String;
      });
  static Future<String> syncPairBeginAsync() =>
      Isolate.run(() => syncPairBegin());
  static void syncPairCancel() => _call((arena) {
        _bindings.tl_sync_pair_cancel();
      });
  static Future<void> syncPairCancelAsync() =>
      Isolate.run(() => syncPairCancel());
  static void syncJoin(String host, int port, String code) => _call((arena) {
        _read(_bindings.tl_sync_join(
            _string(host, arena), port, _string(code, arena)));
      });
  static Future<void> syncJoinAsync(String host, int port, String code) =>
      Isolate.run(() => syncJoin(host, port, code));
  static void syncWith(String host, int port) => _call((arena) {
        _read(_bindings.tl_sync_with(_string(host, arena), port));
      });
  static Future<void> syncWithAsync(String host, int port) =>
      Isolate.run(() => syncWith(host, port));
  static void syncReset() => _call((arena) {
        _bindings.tl_sync_reset();
      });
  static Future<void> syncResetAsync() => Isolate.run(() => syncReset());
  static void setModelsDirectory(String dir) => _call((arena) {
        _read(_bindings.tl_set_models_dir(_string(dir, arena)));
      });
  static void downloadModel(String repo) => _call((arena) {
        _read(_bindings.tl_model_download(_string(repo, arena)));
      });
  static Future<void> downloadModelAsync(String repo) =>
      Isolate.run(() => downloadModel(repo));
  /// Windows / Linux secrets: a new key, and values sealed / opened with it.
  static String secretKey() => _call((arena) => _read(_bindings.tl_secret_key()) as String);
  static String secretSeal(String key, String text) =>
      _call((arena) => _read(_bindings.tl_secret_seal(_string(key, arena), _string(text, arena))) as String);
  static String secretOpen(String key, String blob) =>
      _call((arena) => _read(_bindings.tl_secret_open(_string(key, arena), _string(blob, arena))) as String);
  /// The models offered for download in [format] (`mlx` or `gguf`).
  static List<CatalogEntry> modelCatalog(String format) => _call((arena) {
        final value = _read(_bindings.tl_model_catalog(_string(format, arena)));
        return (value as List).map((v) => CatalogEntry.fromJson(v as Map<String, dynamic>)).toList();
      });
  /// This device as the model store sees it.
  static HubDevice? hubDevice() => _call((arena) {
        final value = _read(_bindings.tl_hub_device());
        return value == null ? null : HubDevice.fromJson(value as Map<String, dynamic>);
      });
  /// The model store's results. Waits on the network: off the drawing thread.
  static HubPage hubSearch(String format, String query, bool uncensored, String? next) => _call((arena) {
        final request = jsonEncode({'format': format, 'query': query, 'uncensored': uncensored, 'next': next});
        return HubPage.fromJson(_read(_bindings.tl_hub_search(_string(request, arena))) as Map<String, dynamic>);
      });
  /// One repo's real files and sizes. Waits on the network: off the drawing thread.
  static HubDetail hubRepo(String format, String repo) => _call((arena) =>
      HubDetail.fromJson(_read(_bindings.tl_hub_repo(_string(format, arena), _string(repo, arena))) as Map<String, dynamic>));
  /// Starts a model's download from the store; progress through [modelStatus].
  static void hubInstall({required String format, required String repo, String? revision, String? weights, String? projector, required int bytes, required String folder}) => _call((arena) {
        final request = jsonEncode({'format': format, 'repo': repo, 'revision': revision, 'weights': weights, 'projector': projector, 'bytes': bytes, 'folder': folder});
        _read(_bindings.tl_hub_install(_string(request, arena)));
      });
  /// llama.cpp models: the [weights] file (and a vision model's [projector]) from [repo].
  static void downloadGgufModel(String repo, String weights, String? projector) => _call((arena) {
        _read(_bindings.tl_model_download_gguf(_string(jsonEncode({'repo': repo, 'weights': weights, 'projector': projector}), arena)));
      });
  static ModelDownloadStatus? modelStatus() => _call((arena) {
        final value = _read(_bindings.tl_model_status());
        return value == null
            ? null
            : ModelDownloadStatus.fromJson(value as Map<String, dynamic>);
      });
  static void cancelModelDownload() => _call((arena) {
        _bindings.tl_model_cancel();
      });
  static List<ModelInfo> installedModels() => _call((arena) {
        final value = _read(_bindings.tl_models_installed());
        return (value as List)
            .map((v) => ModelInfo.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static List<InterruptedModel> interruptedModels() => _call((arena) {
        final value = _read(_bindings.tl_models_interrupted());
        return (value as List)
            .map((v) => InterruptedModel.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static void deleteModel(String id) => _call((arena) {
        _read(_bindings.tl_model_delete(_string(id, arena)));
      });
  static int exportModelZip(String id, String outPath) => _call((arena) {
        final value = _read(_bindings.tl_model_export_zip(
            _string(id, arena), _string(outPath, arena)));
        return (value as num).toInt();
      });
  static Future<int> exportModelZipAsync(String id, String outPath) =>
      Isolate.run(() => exportModelZip(id, outPath));
  static ModelInfo importModel(String path) => _call((arena) {
        final value = _read(_bindings.tl_model_import(_string(path, arena)));
        return ModelInfo.fromJson(value as Map<String, dynamic>);
      });
  static Future<ModelInfo> importModelAsync(String path) =>
      Isolate.run(() => importModel(path));
  static List<MediaRef> aiPending(int limit) => _call((arena) {
        final value = _read(_bindings.tl_ai_pending(limit));
        return (value as List)
            .map((v) => MediaRef.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static List<MediaRef> aiPendingFor(String model, int since, int limit) =>
      _call((arena) {
        final value = _read(
            _bindings.tl_ai_pending_for(_string(model, arena), since, limit));
        return (value as List)
            .map((v) => MediaRef.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static void _aiAttempt(Map<String, dynamic> json) => _call((arena) {
        _read(_bindings.tl_ai_attempt(_string(jsonEncode(json), arena)));
      });
  static List<AiFailure> aiFailures() => _call((arena) {
        final value = _read(_bindings.tl_ai_failures());
        return (value as List)
            .map((v) => AiFailure.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static int aiFailuresClear() => _call((arena) {
        final value = _read(_bindings.tl_ai_failures_clear());
        return (value as num).toInt();
      });
  static List<MediaRef> mediaPage(String after, int limit) => _call((arena) {
        final value =
            _read(_bindings.tl_media_page(_string(after, arena), limit));
        return (value as List)
            .map((v) => MediaRef.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static String? setting(String key) => _call((arena) {
        final value = _read(_bindings.tl_setting(_string(key, arena)));
        return value == null ? null : value as String;
      });
  static void setSetting(String key, String? value) => _call((arena) {
        _read(_bindings.tl_set_setting(
            _string(key, arena), _string(value, arena)));
      });
  static List<int> _rawAiCounts() => _call((arena) {
        final value = _read(_bindings.tl_ai_counts());
        return (value as List).map((v) => (v as num).toInt()).toList();
      });
  static int epoch() => _call((arena) {
        final value = _read(_bindings.tl_epoch());
        return (value as num).toInt();
      });
  static void _aiApply(Map<String, dynamic> json) => _call((arena) {
        _read(_bindings.tl_ai_apply(_string(jsonEncode(json), arena)));
      });
  static List<ModelInfo> syncPeerModels(String host, int port) =>
      _call((arena) {
        final value =
            _read(_bindings.tl_sync_peer_models(_string(host, arena), port));
        return (value as List)
            .map((v) => ModelInfo.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static Future<List<ModelInfo>> syncPeerModelsAsync(String host, int port) =>
      Isolate.run(() => syncPeerModels(host, port));
  static void syncPullModel(
          String host, int port, String id, String label, int total) =>
      _call((arena) {
        _read(_bindings.tl_sync_pull_model(_string(host, arena), port,
            _string(id, arena), _string(label, arena), total));
      });
  static Future<void> syncPullModelAsync(
          String host, int port, String id, String label, int total) =>
      Isolate.run(() => syncPullModel(host, port, id, label, total));
  static int _rawTrash(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_trash(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static int _rawRestore(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_trash_restore(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static int _rawPurge(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_trash_purge(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static int emptyTrash() => _call((arena) {
        final value = _read(_bindings.tl_trash_empty());
        return (value as num).toInt();
      });
  static List<TrashItem> trashList() => _call((arena) {
        final value = _read(_bindings.tl_trash_list());
        return (value as List)
            .map((v) => TrashItem.fromJson(v as Map<String, dynamic>))
            .toList();
      });
  static int trashKeepDays() => _call((arena) {
        final value = _read(_bindings.tl_trash_keep_days());
        return (value as num).toInt();
      });
  static void setTrashKeepDays(int days) => _call((arena) {
        _read(_bindings.tl_set_trash_keep_days(days));
      });
  static int expireTrash() => _call((arena) {
        final value = _read(_bindings.tl_trash_expire());
        return (value as num).toInt();
      });
  static int startVerify() => _call((arena) {
        final value = _read(_bindings.tl_verify_start());
        return (value as num).toInt();
      });
  static VerifyStatus? verifyStatus() => _call((arena) {
        final value = _read(_bindings.tl_verify_status());
        return value == null
            ? null
            : VerifyStatus.fromJson(value as Map<String, dynamic>);
      });
  static void cancelVerify() => _call((arena) {
        _bindings.tl_verify_cancel();
      });
  static String? reportBad(String mediaId) => _call((arena) {
        final value = _read(_bindings.tl_report_bad(_string(mediaId, arena)));
        return value == null ? null : value as String;
      });
  static RepairResult repair(String mediaId) => _call((arena) {
        final value = _read(_bindings.tl_repair(_string(mediaId, arena)));
        return RepairResult.values.firstWhere((e) => e.wireValue == value);
      });
  static Future<RepairResult> repairAsync(String mediaId) =>
      Isolate.run(() => repair(mediaId));
  static ImportProgress? importStatus() => _call((arena) {
        final value = _read(_bindings.tl_import_status());
        return value == null
            ? null
            : ImportProgress.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportProgress?> importStatusAsync() =>
      Isolate.run(() => importStatus());
  static List<List<Object?>> _rawImportReports() => _call((arena) {
        final value = _read(_bindings.tl_import_reports());
        return (value as List)
            .map((v) => (v as List).toList())
            .toList();
      });

  static ImportReport importReport(String path) => _call((arena) {
        final value = _read(_bindings.tl_import_report(_string(path, arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportReport> importReportAsync(String path) =>
      Isolate.run(() => importReport(path));
  static int exportImportIssues(String report, String outZip) => _call((arena) {
        final value = _read(_bindings.tl_import_export_issues(
            _string(report, arena), _string(outZip, arena)));
        return (value as num).toInt();
      });
  static Future<int> exportImportIssuesAsync(String report, String outZip) =>
      Isolate.run(() => exportImportIssues(report, outZip));
  static String renameTag(String from, String to) => _call((arena) {
        final value = _read(
            _bindings.tl_rename_tag(_string(from, arena), _string(to, arena)));
        return value as String;
      });
  static List<List<Object?>> _rawMediaTags(String mediaId) => _call((arena) {
        final value = _read(_bindings.tl_media_tags(_string(mediaId, arena)));
        return (value as List)
            .map((v) => (v as List).toList())
            .toList();
      });
  static List<List<Object?>> _rawFolders() => _call((arena) {
        final value = _read(_bindings.tl_folders());
        return (value as List)
            .map((v) => (v as List).toList())
            .toList();
      });
  static int deleteTag(String label) => _call((arena) {
        final value = _read(_bindings.tl_delete_tag(_string(label, arena)));
        return (value as num).toInt();
      });
  static int removeAITags() => _call((arena) {
        final value = _read(_bindings.tl_remove_ai_tags());
        return (value as num).toInt();
      });
  static FolderOverview folderOverview() => _call((arena) {
        final value = _read(_bindings.tl_folder_overview());
        return FolderOverview.fromJson(value as Map<String, dynamic>);
      });
  static List<String> mediaFolders(String mediaId) => _call((arena) {
        final value =
            _read(_bindings.tl_media_folders(_string(mediaId, arena)));
        return (value as List).map((v) => v as String).toList();
      });
  static String createFolder(String name) => _call((arena) {
        final value = _read(_bindings.tl_create_folder(_string(name, arena)));
        return value as String;
      });
  static void deleteFolder(String name) => _call((arena) {
        _read(_bindings.tl_delete_folder(_string(name, arena)));
      });
  static int _rawRenameFolder(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_rename_folder(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static int _rawAddToFolder(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_folder_add(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static int _rawRemoveFromFolder(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_folder_remove(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static ImportReport importLooseZip(String path, [String folder = '']) =>
      _call((arena) {
        final value = _read(_bindings.tl_import_loose_zip(
            _string(path, arena), _string(folder, arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ImportReport> importLooseZipAsync(String path,
          [String folder = '']) =>
      Isolate.run(() => importLooseZip(path, folder));
  static ExportReport exportBackup(String outPath) => _call((arena) {
        final value =
            _read(_bindings.tl_export_backup(_string(outPath, arena)));
        return ExportReport.fromJson(value as Map<String, dynamic>);
      });
  static Future<ExportReport> exportBackupAsync(String outPath) =>
      Isolate.run(() => exportBackup(outPath));
  static int exportDiagnostics(
          String outPath, Map<String, dynamic> appInfoJson) =>
      _call((arena) {
        final value = _read(_bindings.tl_export_diagnostics(
            _string(outPath, arena), _string(jsonEncode(appInfoJson), arena)));
        return (value as num).toInt();
      });
  static Future<int> exportDiagnosticsAsync(
          String outPath, Map<String, dynamic> appInfoJson) =>
      Isolate.run(() => exportDiagnostics(outPath, appInfoJson));
  static int _rawTagToFolder(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_tag_to_folder(_string(jsonEncode(json), arena)));
        return (value as num).toInt();
      });
  static CookieCheck checkCookies(String authToken, String ct0) =>
      _call((arena) {
        final value = _read(_bindings.tl_check_cookies(
            _string(authToken, arena), _string(ct0, arena)));
        return CookieCheck.fromJson(value as Map<String, dynamic>);
      });
  static ExportProgress? exportStatus() => _call((arena) {
        final value = _read(_bindings.tl_export_status());
        return value == null
            ? null
            : ExportProgress.fromJson(value as Map<String, dynamic>);
      });
  static Future<ExportProgress?> exportStatusAsync() =>
      Isolate.run(() => exportStatus());
  static bool cancelExport() => _call((arena) {
        final value = _read(_bindings.tl_export_cancel());
        return value as bool;
      });
  static void cancelImport() => _call((arena) => _bindings.tl_import_cancel());
  static Future<void> cancelImportAsync() => Isolate.run(cancelImport);
  static Future<bool> cancelExportAsync() => Isolate.run(() => cancelExport());
  static ImportReport _rawImportLooseDir(Map<String, dynamic> json) =>
      _call((arena) {
        final value = _read(
            _bindings.tl_import_loose_dir(_string(jsonEncode(json), arena)));
        return ImportReport.fromJson(value as Map<String, dynamic>);
      });

  static DeletedReports _rawDeleteImportReports(Map<String, dynamic> json) =>
      _call((arena) {
        final value = _read(_bindings
            .tl_delete_import_reports(_string(jsonEncode(json), arena)));
        return DeletedReports.fromJson(value as Map<String, dynamic>);
      });

  static MediaScope postScope(String post) => _call((arena) {
        final value = _read(_bindings.tl_post_scope(_string(post, arena)));
        return MediaScope.fromJson(value as Map<String, dynamic>);
      });
  static BinSnapshot _rawBinSnapshot() => _call((arena) {
        final value = _read(_bindings.tl_bin_snapshot());
        return BinSnapshot.fromJson(value as Map<String, dynamic>);
      });
  static ActionReceipt _rawAction(Map<String, dynamic> json) => _call((arena) {
        final value =
            _read(_bindings.tl_action(_string(jsonEncode(json), arena)));
        return ActionReceipt.fromJson(value as Map<String, dynamic>);
      });
  static int undo(ActionReceipt json) => _call((arena) {
        final value = _read(_bindings
            .tl_action_undo(_string(jsonEncode(json.toJson()), arena)));
        return (value as num).toInt();
      });
  static int stopDownload(bool pause) => _call((arena) {
        final value = _read(_bindings.tl_download_stop(pause));
        return (value as num).toInt();
      });
  static Future<int> stopDownloadAsync(bool pause) =>
      Isolate.run(() => stopDownload(pause));
  static int resumeDownload(DownloadRequest json) => _call((arena) {
        final value = _read(_bindings
            .tl_download_resume(_string(jsonEncode(json.toJson()), arena)));
        return (value as num).toInt();
      });
  static Future<int> resumeDownloadAsync(DownloadRequest json) =>
      Isolate.run(() => resumeDownload(json));
  static IntegritySummary integritySummary() => _call((arena) {
        final value = _read(_bindings.tl_integrity_summary());
        return IntegritySummary.fromJson(value as Map<String, dynamic>);
      });

  static List<String> mediaIds(String folder) =>
      feed(FeedRequest(filter: FeedFilter(folder: folder)))
          .map((item) => item.media_id)
          .toList();
  static void aiApply(
          {required String mediaId,
          required String model,
          required List<String> labels,
          bool replaceOld = false,
          int? atEpoch}) =>
      _aiApply({
        'media_id': mediaId,
        'model': model,
        'labels': labels,
        'replace_old': replaceOld,
        'epoch': atEpoch ?? epoch()
      });
  static void aiAttempt(AiAttemptStep step,
          {required String mediaId,
          required String model,
          String reason = ''}) =>
      _aiAttempt({
        'step': step.wireValue,
        'media_id': mediaId,
        'model': model,
        'reason': reason,
        'now': DateTime.now().millisecondsSinceEpoch ~/ 1000
      });
  static void setVectors(String model, List<(String, List<double>)> items,
          {int? atEpoch}) =>
      _setVectors({
        'model': model,
        'epoch': atEpoch ?? epoch(),
        'items': items.map((item) => [item.$1, item.$2]).toList()
      });

  static List<FeedItem> thumbnailItems() => _rawThumbnailItems()
      .map((item) => FeedItem(
          media_id: item.media_id,
          post_id: '',
          ordinal: 0,
          kind: item.kind,
          path: item.path))
      .toList();
  static ExportReport exportMedia(List<String> ids, String outPath,
          {ExportOptions? options}) =>
      _rawExportMedia({
        'media_ids': ids,
        'out': outPath,
        'options': (options ?? ExportOptions()).toJson()
      });
  static Future<ExportReport> exportMediaAsync(List<String> ids, String outPath,
          {ExportOptions? options}) =>
      Isolate.run(() => exportMedia(ids, outPath, options: options));
  static List<String> mediaIdsInFolder(String folder) => mediaIds(folder);
  static int trash({List<String> media = const [], String? post}) =>
      _rawTrash({'media': media, 'post': post});
  static int restore(List<String> media) => _rawRestore({'media': media});
  static int purge(List<String> media) => _rawPurge({'media': media});
  static int renameFolder(String old, String to) =>
      _rawRenameFolder({'old': old, 'new': to});
  static int addToFolder(String name,
          {List<String> media = const [], List<String> posts = const []}) =>
      _rawAddToFolder({'name': name, 'media': media, 'posts': posts});
  static int removeFromFolder(String name,
          {List<String> media = const [], List<String> posts = const []}) =>
      _rawRemoveFromFolder({'name': name, 'media': media, 'posts': posts});
  static int tagToFolder(String label, String folder) =>
      _rawTagToFolder({'label': label, 'folder': folder});
  static ImportReport importLooseDir(String dir,
          {String? folder, required bool consume, String? keepTo, bool album = true}) =>
      _rawImportLooseDir({
        'dir': dir,
        'folder': folder,
        'consume': consume,
        'keep_to': keepTo,
        'album': album
      });
  static Future<ImportReport> importLooseDirAsync(String dir,
          {String? folder, required bool consume, String? keepTo, bool album = true}) =>
      Isolate.run(() => importLooseDir(dir,
          folder: folder, consume: consume, keepTo: keepTo, album: album));
  static DeletedReports deleteImportReports(List<String> files,
          {required List<String> owned}) =>
      _rawDeleteImportReports({'reports': files, 'owned': owned});
  static Future<DeletedReports> deleteImportReportsAsync(List<String> files,
          {required List<String> owned}) =>
      Isolate.run(() => deleteImportReports(files, owned: owned));
  static ActionReceipt action(ActionKind kind,
          {List<String> media = const [],
          List<String> posts = const [],
          String? folder,
          String? label,
          BinSnapshot? snapshot}) =>
      _rawAction({
        'kind': kind.wireValue,
        'media': media,
        'posts': posts,
        'folder': folder,
        'label': label,
        'expected': snapshot?.entries.map((e) => e.toJson()).toList(),
        'epoch': snapshot?.epoch
      });
  static BinSnapshot binSnapshot({List<String>? media}) {
    final snapshot = _rawBinSnapshot();
    if (media == null) return snapshot;
    final ids = media.toSet();
    return BinSnapshot(
        entries: snapshot.entries.where((e) => ids.contains(e.id)).toList(),
        pending_count: 0,
        epoch: snapshot.epoch);
  }

  static List<({String name, int count})> folders() => _rawFolders()
      .map((row) => (name: row[0] as String, count: (row[1] as num).toInt()))
      .toList();
  static List<String> mediaTags(String mediaId) =>
      _rawMediaTags(mediaId).map((row) => row[0] as String).toList();
  static ({int done, int total}) aiCounts() {
    final counts = _rawAiCounts();
    return (done: counts[0], total: counts[1]);
  }

  static List<({String file, DateTime date, String source, int issues})>
      importReports() => _rawImportReports()
          .map((row) => (
                file: row[0] as String,
                date: DateTime.fromMillisecondsSinceEpoch(
                    (row[1] as num).toInt()),
                source: row[2] as String,
                issues: (row[3] as num).toInt()
              ))
          .toList();
  static Future<List<({String file, DateTime date, String source, int issues})>>
      importReportsAsync() => Isolate.run(importReports);
  // Grid handles and caller-owned numeric buffers use their explicit C lifetime.
  // Call gridFree once for each successful gridNew, after all users have stopped.
  static Pointer<TlGrid> gridNew(
          double width,
          double height,
          double scale,
          double inset_top,
          double inset_bottom,
          int count,
          int level,
          int phase,
          double offset) =>
      _bindings.tl_grid_new(width, height, scale, inset_top, inset_bottom,
          count, level, phase, offset);
  static void gridFree(Pointer<TlGrid> g) => _bindings.tl_grid_free(g);
  static void gridConfigure(Pointer<TlGrid> g, double width, double height,
          double scale, double inset_top, double inset_bottom, int count) =>
      _bindings.tl_grid_configure(
          g, width, height, scale, inset_top, inset_bottom, count);
  static void gridRest(Pointer<TlGrid> g, Pointer<Double> out3) =>
      _bindings.tl_grid_rest(g, out3);
  static void gridSetOffset(Pointer<TlGrid> g, double offset) =>
      _bindings.tl_grid_set_offset(g, offset);
  static double gridMaxOffset(Pointer<TlGrid> g) =>
      _bindings.tl_grid_max_offset(g);
  static void gridBeginPinch(
          Pointer<TlGrid> g, double x, double y, double time) =>
      _bindings.tl_grid_begin_pinch(g, x, y, time);
  static void gridPinchChanged(
          Pointer<TlGrid> g, double scale, double x, double y) =>
      _bindings.tl_grid_pinch_changed(g, scale, x, y);
  static void gridRelease(Pointer<TlGrid> g, double velocity, double scale) =>
      _bindings.tl_grid_release(g, velocity, scale);
  static int gridTick(Pointer<TlGrid> g, double time) =>
      _bindings.tl_grid_tick(g, time);
  static bool gridFinishNow(Pointer<TlGrid> g) =>
      _bindings.tl_grid_finish_now(g);
  static void gridInfo(Pointer<TlGrid> g, Pointer<Double> out4) =>
      _bindings.tl_grid_info(g, out4);
  static int gridTiles(
          Pointer<TlGrid> g, Pointer<Double> buffer, int capacity) =>
      _bindings.tl_grid_tiles(g, buffer, capacity);
  static int gridIndexAt(Pointer<TlGrid> g, double x, double y) =>
      _bindings.tl_grid_index_at(g, x, y);
  static void gridFrame(Pointer<TlGrid> g, int index, Pointer<Double> out3) =>
      _bindings.tl_grid_frame(g, index, out3);
  static void gridSetHidden(Pointer<TlGrid> g, int index) =>
      _bindings.tl_grid_set_hidden(g, index);

  static ThumbnailResult thumbnail(String mediaId, int side, String cacheDir) =>
      _call((arena) {
        try {
          return ThumbnailResult.fromJson(_read(_bindings.tl_thumbnail(
                  _string(mediaId, arena), side, _string(cacheDir, arena)))
              as Map<String, dynamic>);
        } on CoreError catch (error) {
          if (error.message == 'not_decodable')
            throw const ThumbnailNotDecodable();
          rethrow;
        }
      });

  /// Decoding and disk IO run outside the UI isolate.
  static Future<ThumbnailResult> thumbnailAsync(
          String mediaId, int side, String cacheDir) =>
      Isolate.run(() => thumbnail(mediaId, side, cacheDir));

  /// A HEIC or AVIF file as a JPEG Flutter can show, at most [maxSide] on its long edge: the
  /// cached JPEG's path.
  static String displayImage(String path, int maxSide, String cacheDir) =>
      _call((arena) => _read(_bindings.tl_display_image(
          _string(path, arena), maxSide, _string(cacheDir, arena))) as String);

  static Future<String> displayImageAsync(
          String path, int maxSide, String cacheDir) =>
      Isolate.run(() => displayImage(path, maxSide, cacheDir));

  /// The native function starts a bounded background warmer and returns at once.
  static void thumbnailsWarm(List<String> ids, int side, String cacheDir) =>
      _call((arena) {
        _read(_bindings.tl_thumbnails_warm(
            _string(jsonEncode(ids), arena), side, _string(cacheDir, arena)));
      });
  static Future<void> thumbnailsWarmAsync(
          List<String> ids, int side, String cacheDir) =>
      Isolate.run(() => thumbnailsWarm(ids, side, cacheDir));
  static void thumbnailsWarmCancel() => _bindings.tl_thumbnails_warm_cancel();
}
