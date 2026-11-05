import 'dart:isolate';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_llama/tl_llama.dart';
import 'package:tl_native/tl_native.dart';

import '../l10n/l10n.dart';
import 'external_models.dart';

/// A model the app offers to download (the core's catalog, the same list as the native apps').
extension CatalogNames on CatalogEntry {
  String get name => L(name_key); // i18n-exempt: catalog keys from tl-core catalog.rs
  String get note => L(note_key); // i18n-exempt: catalog keys from tl-core catalog.rs
}

/// On-device models. Apple devices run MLX (the same engine and the same models as the native
/// apps, `TLLocalAI` through `tl_native`); Android, Windows and Linux run llama.cpp (`tl_llama`,
/// CPU or Vulkan) with GGUF models. Only Apple devices export, import or pull models from other
/// devices: MLX models run on Apple silicon alone.
class LocalModels extends ChangeNotifier {
  LocalModels._();
  static final instance = LocalModels._();
  /// For tests: no core behind it.
  @visibleForTesting
  LocalModels.forTest(List<CatalogEntry> entries) {
    catalog = entries;
  }

  static bool get apple => !kIsWeb && (Platform.isIOS || Platform.isMacOS);
  static const _native = MethodChannel('tl/native');

  String get format => apple ? 'mlx' : 'gguf';
  // no semantic search here: its embedding models are not offered
  late List<CatalogEntry> catalog = Core.modelCatalog(format).where((c) => !c.embedder).toList();

  bool supported = false;
  /// llama.cpp's devices (e.g. "Vulkan0 (…), CPU"); null on Apple devices.
  String? devices;
  List<ModelInfo> installed = const [];
  ModelDownloadStatus? download;
  Timer? _poll;
  bool _started = false;

  /// Where models live: beside, not inside, the library (a reset or a test library never makes
  /// them download again), as the native apps keep them.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final dir = Platform.environment['TL_MODELS_DIR'] ?? '${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}Models';
    await Directory(dir).create(recursive: true);
    Core.setModelsDirectory(dir);
    if (apple) {
      try {
        supported = await _native.invokeMethod<bool>('aiSupported') ?? false;
      } catch (_) {
        supported = false;
      }
    } else if (LlamaEngine.isSupported) {
      try {
        devices = await LlamaEngine.instance.init(Platform.isAndroid ? await _androidLibDir() : null);
        supported = true;
      } catch (_) {
        supported = false;
      }
    }
    await refresh();
  }

  static Future<String?> _androidLibDir() async {
    final paths = await TlNative.appPaths();
    return paths.where((p) => !p.endsWith('.apk')).lastOrNull;
  }

  /// Reads the models folder (their files are looked at) off the drawing thread.
  Future<void> refresh() async {
    final wanted = format;
    final found = await Isolate.run(() => Core.installedModels().where((m) => m.format == wanted).toList());
    installed = found;
    download = Core.modelStatus();
    notifyListeners();
  }

  ModelInfo? find(String id) => installed.where((m) => m.id == id).firstOrNull;
  CatalogEntry? catalogFor(String id) => catalog.where((c) => c.folder == id).firstOrNull;
  String title(ModelInfo m) => catalogFor(m.id)?.name ?? m.repo ?? m.id;

  /// A model of the catalog, from the model store.
  void installCurated(CatalogEntry c) {
    Core.hubInstall(format: c.format, repo: c.repo, weights: c.weights, projector: c.projector, bytes: c.bytes, folder: c.folder);
    _watch();
  }

  /// A version of a repo found in the model store, pinned to the revision that was looked at.
  void installVariant(HubDetail d, HubVariant v) {
    Core.hubInstall(format: format, repo: d.repo.repo, revision: d.revision, weights: v.weights, projector: v.projector, bytes: v.bytes, folder: v.folder);
    _watch();
  }

  void cancelDownload() => Core.cancelModelDownload();

  /// Follows a model coming in from somewhere else (another device) too.
  void watch() => _watch();

  void _watch() {
    _poll?.cancel();
    // only the status while it runs: listing what is installed reads the disk on this (the UI)
    // thread, and that waits as long as the disk is busy with the download
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) {
      download = Core.modelStatus();
      if (download?.running == true) return notifyListeners();
      _poll?.cancel();
      refresh();
    });
    refresh();
  }

  Future<void> delete(String id) async {
    await unload();
    await Isolate.run(() => Core.deleteModel(id));
    await refresh();
  }

  Future<void> unload() async {
    if (apple) {
      try {
        await _native.invokeMethod<void>('aiUnload');
      } catch (_) {}
    } else if (supported) {
      await LlamaEngine.instance.unloadAll();
    }
  }

  // ---- Apple devices only: models between Apple devices (MLX runs on Apple silicon alone)

  Future<int> export(String id, String out) => Core.exportModelZipAsync(id, out);
  Future<void> import(String path) async {
    await Core.importModelAsync(path);
    refresh();
  }

  /// Tags for one picture (the JPEG the tagger prepared: the same input on every device).
  Future<List<String>> tags(String id, {required Uint8List jpeg, required String system, required String question}) async {
    final m = find(id);
    if (m == null) throw const ExternalFailure(ExternalFailureKind.noModel);
    final sep = Platform.pathSeparator;
    final tmp = File('${(await getTemporaryDirectory()).path}${sep}tl-tag-${DateTime.now().microsecondsSinceEpoch}.jpg');
    await tmp.writeAsBytes(jpeg, flush: true);
    try {
      if (apple) {
        // iOS ends an app over its memory limit without a warning that arrives in time
        final available = await _native.invokeMethod<int>('aiAvailableMemory');
        final need = m.bytes + m.bytes ~/ 4 + 500000000;
        if (available != null && available < need) throw LocalModelError(L('ai.err.memory', [_gb(need), _gb(available)]));
        final r = await _native.invokeListMethod<String>('aiTags', {'modelDir': m.path, 'path': tmp.path, 'kind': 'photo', 'system': system, 'question': question});
        return r ?? const [];
      }
      final raw = await LlamaEngine.instance.describe(weights: '${m.path}$sep${m.weights}', projector: '${m.path}$sep${m.projector}', image: tmp.path, system: system, question: question);
      return ExternalAI.parseTags(raw);
    } finally {
      unawaited(tmp.delete().then((_) {}, onError: (Object _) {}));
    }
  }

  static String _gb(int bytes) => '${(bytes / 1e9).toStringAsFixed(1)} GB';
}

class LocalModelError implements Exception {
  LocalModelError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// For tests and isolates: whether an id names a local model folder rather than an external one.
bool isLocalModelId(String id) => !ExternalModels.isExternal(id) && id.isNotEmpty;
