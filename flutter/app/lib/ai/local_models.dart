import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';

import '../l10n/l10n.dart';
import '../platform/os.dart';

/// A model the app offers to download (the core's catalog, the same list as the native apps').
extension CatalogNames on CatalogEntry {
  String get name => L(name_key); // i18n-exempt: catalog keys from tl-core catalog.rs
  String get note => L(note_key); // i18n-exempt: catalog keys from tl-core catalog.rs
}

/// On-device models, run by the core (core/src/ai): on Apple devices with MLX (the same engine and
/// the same models as the native apps, `TLLocalAI`, which `tl_native` hands to the core), on Android
/// with llama.cpp (`tl_llama`: OpenCL on Adreno, Vulkan elsewhere; never the processor) and GGUF
/// models. Models go between devices of the same kind (export, import, pull from another device).
class LocalModels extends ChangeNotifier {
  LocalModels._();
  static final instance = LocalModels._();
  /// For tests: no core behind it.
  @visibleForTesting
  LocalModels.forTest(List<CatalogEntry> entries) {
    catalog = entries;
  }

  static bool get apple => OS.isIOS;
  static const _native = MethodChannel('tl/native');

  String get format => apple ? 'mlx' : 'gguf';
  // no semantic search here: its embedding models are not offered
  late List<CatalogEntry> catalog = Core.modelCatalog(format).where((c) => !c.embedder).toList();

  bool supported = false;
  /// The GPU llama.cpp runs models on (e.g. "Vulkan0 (Mali-G720)"); null on Apple devices, and
  /// where there is none (on-device AI is then off).
  String? devices;
  List<ModelInfo> installed = const [];
  ModelDownloadStatus? download;
  Timer? _poll;
  Future<void>? _starting;

  /// Where models live: beside, not inside, the library (a reset or a test library never makes
  /// them download again), as the native apps keep them.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    final dir = OS.environment['TL_MODELS_DIR'] ?? '${(await getApplicationSupportDirectory()).path}${OS.pathSeparator}Models';
    await Directory(dir).create(recursive: true);
    Core.setModelsDirectory(dir);
    if (apple) {
      try {
        supported = await _native.invokeMethod<bool>('aiSupported') ?? false;
      } catch (_) {
        supported = false;
      }
    } else {
      try {
        if (OS.isAndroid) {
          final dir = await _androidLibDir();
          if (dir != null) Core.setAiEngineDirectory(dir);
        }
        final hw = await coreRunAsync(Core.aiHardware);
        final gpus = (hw['gpus'] as List? ?? const []).cast<Map<String, dynamic>>();
        final chosen = gpus.where((g) => g['name'] == hw['chosen']).firstOrNull ?? gpus.firstOrNull;
        devices = chosen == null ? null : '${chosen['name']} (${chosen['description']})';
        supported = hw['engine'] == true && gpus.isNotEmpty;
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
    final found = await coreRunAsync(() => Core.installedModels().where((m) => m.format == wanted).toList());
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
    await coreRunAsync(() => Core.deleteModel(id));
    await refresh();
  }

  Future<void> unload() async {
    if (apple) {
      try {
        await _native.invokeMethod<void>('aiUnload');
      } catch (_) {}
    } else if (supported) {
      await coreRunAsync(Core.aiUnload);
    }
  }

  // ---- models between devices of the same kind (MLX between Apple devices, GGUF between the others)

  Future<int> export(String id, String out) => Core.exportModelZipAsync(id, out);
  Future<void> import(String path) async {
    await Core.importModelAsync(path);
    refresh();
  }
}

class LocalModelError implements Exception {
  LocalModelError(this.message);
  final String message;
  @override
  String toString() => message;
}
