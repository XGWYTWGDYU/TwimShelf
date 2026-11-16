import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'os.dart';

/// The data folder on Linux: everything the app keeps — the library, its models, settings,
/// secrets, logs, caches — lives in one folder the person chose, so it can be backed up, moved
/// or deleted as one thing. The program is in a folder of its own (the AppImage). Only a small
/// pointer to the data folder stays in the system's config folder. (The native Windows app,
/// windows/TwimShelf, keeps the same layout there.)
///
/// Every plugin that asks path_provider for a folder is pointed inside the data folder:
///   support → `<data>/App` (library, models, settings, secrets), cache → `<data>/Cache`.
/// Downloads and temporary files stay where the system keeps them.
///
/// Apple devices and Android keep their system's app containers; a debug run on a synthetic
/// library (TL_LIBRARY_DIR) never touches the pointer.
class DataHome {
  DataHome._();

  static bool get applies =>
      !kIsWeb && OS.isLinux && OS.environment['TL_LIBRARY_DIR'] == null;

  static String? _path;
  static String? get path => _path;

  static String get _sep => OS.pathSeparator;

  /// The pointer: `$XDG_CONFIG_HOME/twimshelf/location.json`.
  static File get _pointer {
    final config = OS.environment['XDG_CONFIG_HOME'] ?? '${OS.environment['HOME']}/.config';
    return File('$config/twimshelf/location.json');
  }

  /// A sensible first suggestion: a folder in Documents.
  static String get suggested {
    final home = OS.environment['HOME']!;
    final docs = Directory('$home${_sep}Documents');
    return '${docs.existsSync() ? docs.path : home}${_sep}TwimShelf Data';
  }

  /// Reads the pointer; true when the data folder is known (and now in use).
  static bool locate() {
    if (!applies) return true;
    try {
      final j = jsonDecode(_pointer.readAsStringSync()) as Map<String, dynamic>;
      final p = j['path'] as String;
      if (!Directory(p).existsSync()) return false;
      _use(p);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// A folder can hold the data: it is new, empty, or already a data folder.
  static String? problem(String folder) {
    final d = Directory(folder);
    if (!d.existsSync()) return null;
    if (isDataFolder(folder)) return null;
    return d.listSync().isEmpty ? null : 'notEmpty';
  }

  static bool isDataFolder(String folder) => File('$folder${_sep}twimshelf-data.json').existsSync();

  /// Uses [folder] from now on (made when missing, marked as a data folder).
  static Future<void> choose(String folder) async {
    await Directory('$folder${_sep}App').create(recursive: true);
    final mark = File('$folder${_sep}twimshelf-data.json');
    if (!mark.existsSync()) await mark.writeAsString(jsonEncode({'created': DateTime.now().toUtc().toIso8601String()}));
    await _writePointer(folder);
    _use(folder);
  }

  static Future<void> _writePointer(String folder) async {
    await _pointer.parent.create(recursive: true);
    final tmp = File('${_pointer.path}.partial');
    await tmp.writeAsString(jsonEncode({'path': folder}), flush: true);
    await tmp.rename(_pointer.path);
  }

  static void _use(String folder) {
    _path = folder;
    PathProviderPlatform.instance = _DataFolderPaths(folder, PathProviderPlatform.instance);
    // shared_preferences asks its own path_provider, not the shared instance
    final prefs = SharedPreferencesStorePlatform.instance;
    if (prefs is SharedPreferencesLinux) prefs.pathProvider = _LinuxPaths(folder);
  }

  /// A folder the data can move to: new or empty only, never another library (its files would be
  /// overwritten before its database refused the copy). Null when it can, else the datahome.* key.
  static String? moveProblem(String folder) {
    final d = Directory(folder);
    if (!d.existsSync()) return null;
    if (isDataFolder(folder)) return 'datahome.moveExisting';
    return d.listSync().isEmpty ? null : 'datahome.notEmpty';
  }

  /// Moves everything to [target] (new or empty): copied, checked file by file (sizes), then
  /// used from the next start. The old folder is left as it was; the caller offers to delete it
  /// once the app runs from the new place. The database is not copied as files (a running one is
  /// spread over several, and they change between copies): [snapshot] writes a consistent copy
  /// first, and then the files are listed and copied, so every media the copied database refers to
  /// is among them (a file is always written before the database refers to it). The caller stops
  /// what writes first.
  static Future<void> moveTo(String target, {required Future<void> Function(String out) snapshot, required String databaseFile, void Function(int done, int total)? progress}) async {
    final from = _path;
    if (from == null) throw StateError('dataHome.none');
    if (moveProblem(target) != null) throw FileSystemException(moveProblem(target)!);
    if (target == from || target.startsWith('$from$_sep')) throw const FileSystemException('dataHome.inside');
    final copy = File('$target$_sep${databaseFile.substring(from.length + 1)}');
    await copy.parent.create(recursive: true);
    await snapshot(copy.path);
    if (!await copy.exists() || await copy.length() == 0) throw FileSystemException('dataHome.copyFailed', copy.path);
    final files = Directory(from).listSync(recursive: true, followLinks: false).whereType<File>().toList();
    var done = 0;
    for (final f in files) {
      if (f.path == databaseFile || f.path == '$databaseFile-wal' || f.path == '$databaseFile-shm') {
        done++;
        continue;
      }
      final rel = f.path.substring(from.length + 1);
      final dst = File('$target$_sep$rel');
      await dst.parent.create(recursive: true);
      await f.copy(dst.path);
      if (await dst.length() != await f.length()) throw FileSystemException('dataHome.copyFailed', rel);
      progress?.call(++done, files.length);
    }
    await _writePointer(target);
  }

  /// The previous data folder, after a move (deleted only when the person agrees).
  static Future<void> deleteOld(String folder) async {
    if (!isDataFolder(folder) || folder == _path) return;
    await Directory(folder).delete(recursive: true);
  }

  /// What starts this program: inside an AppImage the executable is in a temporary mount that
  /// goes away when this process ends.
  @visibleForTesting
  static String restartTarget(Map<String, String> environment, String executable) => environment['APPIMAGE'] ?? executable;

  /// Starts this program again (after a move).
  static Future<Never> restart() async {
    await Process.start(restartTarget(OS.environment, OS.resolvedExecutable), const [], mode: ProcessStartMode.detached);
    exit(0);
  }
}

class _DataFolderPaths extends PathProviderPlatform {
  _DataFolderPaths(this.root, this.system);
  final String root;
  final PathProviderPlatform system;
  String get _s => OS.pathSeparator;

  @override
  Future<String?> getApplicationSupportPath() async => '$root${_s}App';
  @override
  Future<String?> getApplicationDocumentsPath() async => '$root${_s}App';
  @override
  Future<String?> getApplicationCachePath() async => '$root${_s}Cache';
  @override
  Future<String?> getLibraryPath() async => '$root${_s}App';
  @override
  Future<String?> getTemporaryPath() => system.getTemporaryPath();
  @override
  Future<String?> getDownloadsPath() => system.getDownloadsPath();
  @override
  Future<String?> getExternalStoragePath() => system.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() => system.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) => system.getExternalStoragePaths(type: type);
}

// ignore_for_file: invalid_use_of_visible_for_testing_member
class _LinuxPaths extends PathProviderLinux {
  _LinuxPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => '$root/App';
}
