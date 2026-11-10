import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';

import '../app/jobs.dart';
import '../l10n/l10n.dart';
import 'desktop_inbox.dart';
import 'desktop_entry.dart';
import 'shared_links.dart';
import 'os.dart';
export 'shared_links.dart';

sealed class ShareInboxEvent {
  const ShareInboxEvent();
}

/// Durable until acknowledgeLinks is called after the UI/download queue accepts
/// these links. It is safe to receive this same id again after a restart.
final class ShareLinksReady extends ShareInboxEvent {
  ShareLinksReady(this.id, List<String> links)
    : links = List.unmodifiable(links);
  final String id;
  final List<String> links;
  /// The folder chosen on the share page for these links; null: the download page's.
  String? folder;
}

/// Shared here with no page of its own (Android, Linux), or dropped on a window: files copied and links noted, not
/// imported. The app shows the share page, which ends in `confirm` or `discard`.
final class ShareNeedsChoice extends ShareInboxEvent {
  const ShareNeedsChoice(this.id, this.directory, this.files, this.links);
  final String id;
  final String directory;
  final List<String> files;
  final List<String> links;
}

/// 下载帖子 from the program's icon on Windows and Linux.
final class ShareQuickDownload extends ShareInboxEvent {
  const ShareQuickDownload();
}

final class ShareFilesImported extends ShareInboxEvent {
  const ShareFilesImported(this.id, this.report);
  final String id;
  final ImportReport report;
}

final class ShareInboxFailure extends ShareInboxEvent {
  const ShareInboxFailure(this.pending);
  final int pending;
  String get messageKey => 'shareInbox.failed';
}

typedef ShareImporter = Future<ImportReport> Function(
  String directory,
  String keepTo, {
  String? folder,
  bool album,
});

/// Subscribe to events, then start AFTER Core.open. Keep one instance for the
/// application lifetime, and dispose it on shutdown. Imports are serialized;
/// failures remain pending for the next resume, never retried in a tight loop.
class ShareInbox with WidgetsBindingObserver {
  ShareInbox({this.root, ShareImporter? importer, this.asks = false})
    : _importer = importer ?? _import;
  /// A share without the person's choice in it waits for the share page. (Apple's share extensions
  /// are that page themselves; what they hand over has been confirmed.)
  final bool asks;
  final _asked = <String>{};
  /// Shares waiting for the page: one that came in before the page's listener was there is here.
  final pendingChoices = <ShareNeedsChoice>[];
  static const _channel = MethodChannel('org.twimshelf/share_inbox');
  final Directory? root;
  Directory? _root;
  final ShareImporter _importer;
  final _events = StreamController<ShareInboxEvent>.broadcast();
  Stream<ShareInboxEvent> get events => _events.stream;
  Future<void>? _running;
  bool _started = false;
  bool _disposed = false;
  bool _again = false;
  final List<StreamSubscription<FileSystemEvent>> _watchers = [];
  Timer? _debounce;

  static Future<ImportReport> _import(String source, String kept, {String? folder, bool album = true}) =>
      Core.importLooseDirAsync(source, folder: folder, consume: true, keepTo: kept, album: album);

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    final shares = await _shares();
    if (shares != null && (OS.isWindows || OS.isLinux)) {
      for (final name in ['Requests', 'Inbox']) {
        final directory = await Directory('${shares.path}/$name')
            .create(recursive: true);
        _watchers.add(
          directory.watch().listen((event) {
            if (!isDesktopPublication(event, request: name == 'Requests')) {
              return;
            }
            _debounce?.cancel();
            _debounce = Timer(
              const Duration(milliseconds: 100),
              () => unawaited(drain()),
            );
          }),
        );
      }
      try {
        // Registration labels come from the same initialized catalog as the UI.
        // what an earlier version left in Explorer's Send to
        if (root == null && OS.isWindows) {
          await _channel.invokeMethod<void>('removeSendTo', L('share.title'));
        } else if (root == null && OS.isLinux) {
          await installDesktopEntry();
        }
        if (root == null && OS.isWindows) await _channel.invokeMethod<void>('installJumpList', L('shortcut.downloadPosts'));
      } catch (_) {
        // Registration is recoverable and must not prevent a pending import.
        _emit(const ShareInboxFailure(0));
      }
    }
    await drain();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(drain());
  }

  Future<void> drain() {
    if (_disposed) return Future.value();
    if (_running != null) {
      _again = true;
      return _running!;
    }
    return _running =
        (() async {
          do {
            _again = false;
            await _drain();
          } while (_again && !_disposed);
        })().whenComplete(() {
          _running = null;
        });
  }

  Future<Directory?> _shares() async {
    if (root != null) return root;
    if (_root != null) return _root;
    final path = OS.isIOS || OS.isMacOS
        ? await TlNative.sharesRoot()
        : await _channel.invokeMethod<String>('getSharesRoot');
    if (path != null) _root = Directory(path);
    return _root;
  }

  void _emit(ShareInboxEvent event) {
    if (!_disposed) _events.add(event);
  }

  Future<List<Directory>> _pending(Directory inbox) async {
    if (!await inbox.exists()) return [];
    final ready = <Directory>[];
    await for (final entity in inbox.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (name.endsWith('.partial')) {
        if (DateTime.now().difference((await entity.stat()).modified) >
            const Duration(days: 1)) {
          await entity.delete(recursive: true);
        }
      } else if (_safeId(name)) {
        ready.add(entity);
      }
    }
    ready.sort((a, b) => a.path.compareTo(b.path));
    return ready;
  }

  static bool _safeId(String id) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

  Future<void> _drain() async {
    var pending = 0;
    try {
      final root = await _shares();
      if (root == null) return;
      final desktop = DesktopInbox(root, quickDownload: () => _emit(const ShareQuickDownload()));
      final failures = await desktop.publishRequests();
      if (failures > 0) _emit(ShareInboxFailure(failures));
      final inbox = Directory('${root.path}/Inbox');
      final links = Directory('${root.path}/Links');
      final announced = <String>{};
      // Windows finishes deleting a folder a moment later: one just imported may still be listed
      final imported = <String>{};
      while (!_disposed) {
        final ready = <Directory>[];
        for (final b in await _pending(inbox)) {
          final bid = b.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (imported.contains(bid)) continue;
          if ((!asks && !_alwaysAsk.contains(bid)) || await File('${b.path}/_share.json').exists()) {
            ready.add(b);
          } else if (_asked.add(bid)) {
            await _announce(bid, b);
          }
        }
        pending = ready.length;
        if (ready.isEmpty) break;
        final batch = ready.first;
        final id = batch.uri.pathSegments.where((s) => s.isNotEmpty).last;
        imported.add(id);
        // Native collector publishes only regular files. Never follow injected
        // symlinks, even inside otherwise private test/inbox directories.
        await for (final entity in batch.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is Link) {
            throw const FileSystemException('shareInbox.symlink');
          }
        }
        // what the person chose on the share page
        String? folder;
        // dropped on a window: only loose, not 从相册导入
        var album = true;
        final choice = File('${batch.path}/_share.json');
        if (await choice.exists()) {
          final chosen = jsonDecode(await choice.readAsString()) as Map;
          final name = chosen['folder'] as String? ?? '';
          folder = name.isEmpty ? null : name;
          album = chosen['dropped'] != true;
          final left = (chosen['links'] as List? ?? const []).cast<String>();
          if (left.isNotEmpty) {
            await links.create(recursive: true);
            await File('${links.path}/$id.json').writeAsString(jsonEncode(left));
            if (folder != null) await File('${links.path}/$id.folder').writeAsString(folder);
          }
          await choice.delete();
        }
        final pack = File('${batch.path}/post.tlpack');
        if (await pack.exists()) {
          if (folder != null) await _ensureFolder(folder);
          final report = await Core.importPackAsync(pack.path, folder ?? '');
          // what did not come in yet stays possible: the share stays in the inbox and is tried again
          if (report.incomplete != null) throw CoreError(report.incomplete!);
          await pack.delete();
          _emit(ShareFilesImported(id, report));
        }
        final metadata = File('${batch.path}/_links.json');
        if (await metadata.exists()) {
          await links.create(recursive: true);
          await metadata.rename('${links.path}/$id.json');
        }
        if (await batch.list(followLinks: false).isEmpty) {
          await batch.delete();
        } else {
          if (folder != null) await _ensureFolder(folder);
          final report = await _importer(batch.path, '${root.path}/Kept/$id', folder: folder, album: album);
          _emit(ShareFilesImported(id, report));
          // A custom importer must obey the same consume/keep contract.
          if (await batch.exists()) {
            throw const FileSystemException('shareInbox.notConsumed');
          }
        }
      }
      if (await links.exists()) {
        final files = await links
            .list(followLinks: false)
            .where((f) => f is File && f.path.endsWith('.json'))
            .toList();
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final entity in files) {
          final file = entity as File;
          final name = file.uri.pathSegments.last;
          final id = name.substring(0, name.length - 5);
          if (!_safeId(id) || !announced.add(id)) continue;
          if (await file.length() > 1024 * 1024) {
            throw const FormatException('shareInbox.linksTooLarge');
          }
          final values = jsonDecode(await file.readAsString()) as List;
          final urls = <String>{};
          for (final value in values) {
            if (value is! String) {
              throw const FormatException('shareInbox.invalidLinks');
            }
            urls.addAll(parseSharedPostLinks(value));
          }
          if (urls.isEmpty) {
            throw const FormatException('shareInbox.invalidLinks');
          }
          final named = File('${links.path}/$id.folder');
          _emit(ShareLinksReady(id, urls.toList())..folder = await named.exists() ? await named.readAsString() : null);
        }
      }
    } catch (_) {
      _emit(ShareInboxFailure(pending));
    }
  }

  /// Alternate embedders can forward startup arguments here. Standard desktop
  /// runners already persist them before starting Flutter; do not forward twice.
  Future<void> importArguments(
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    final shares = await _shares();
    if (shares == null) return;
    await DesktopInbox(shares)
        .enqueue(arguments, workingDirectory: workingDirectory);
    await drain();
  }

  /// Media dragged onto the window: copied into the inbox and offered on the share page, as what
  /// is shared here. Nothing reaches the library before 导入, and the originals stay where they are.
  Future<void> importDropped(List<String> paths) async {
    final root = await _shares();
    if (root == null || paths.isEmpty) return;
    final id = 'drop-${DateTime.now().microsecondsSinceEpoch}';
    final inbox = await Directory('${root.path}/Inbox').create(recursive: true);
    final partial = await Directory('${inbox.path}/$id.partial').create();
    var n = 0;
    Future<void> place(String path) async {
      final name = path.split(OS.pathSeparator).last;
      if (await FileSystemEntity.isDirectory(path)) {
        await for (final e in Directory(path).list(recursive: true, followLinks: false)) {
          if (e is File) await e.copy('${partial.path}/${n++}_${e.uri.pathSegments.last}');
        }
      } else {
        await File(path).copy('${partial.path}/${n++}_$name');
      }
    }

    try {
      for (final p in paths) {
        await place(p);
      }
    } catch (_) {
      await partial.delete(recursive: true);
      rethrow;
    }
    await partial.rename('${inbox.path}/$id');
    _alwaysAsk.add(id);
    await drain();
  }

  /// Dropped on a window: the page is shown here on every platform, even where shares have
  /// their own page (iOS, the Mac).
  final _alwaysAsk = <String>{};

  /// Acknowledge only after the download flow has durably queued the event.
  Future<void> acknowledgeLinks(String id) async {
    if (!_safeId(id)) throw ArgumentError.value(id, 'id');
    final root = await _shares();
    if (root == null) return;
    for (final file in [File('${root.path}/Links/$id.json'), File('${root.path}/Links/$id.folder')]) {
      if (await file.exists()) await file.delete();
    }
  }

  static Future<void> _ensureFolder(String name) async {
    try {
      await createFolder(name);
    } on CoreError {
      // it is there already; a real problem shows when the import uses it
    }
  }

  static Future<ShareNeedsChoice> _read(String id, Directory batch) async {
    final files = <String>[];
    final links = <String>[];
    await for (final e in batch.list(followLinks: false)) {
      if (e is! File) continue;
      if (e.path.endsWith('_links.json')) {
        for (final v in jsonDecode(await e.readAsString()) as List) {
          links.addAll(parseSharedPostLinks(v as String));
        }
      } else {
        files.add(e.path);
      }
    }
    files.sort();
    return ShareNeedsChoice(id, batch.path, files, links);
  }

  /// A batch still `.partial`, for the page over the app that shared (Android).
  Future<ShareNeedsChoice?> partialBatch(String id) async {
    final root = await _shares();
    if (root == null || !_safeId(id)) return null;
    final dir = Directory('${root.path}/Inbox/$id.partial');
    return await dir.exists() ? _read(id, dir) : null;
  }

  /// That page's answer: the batch joins the inbox with the choice, for the app to import the next
  /// time it comes forward. Nothing here touches the library.
  Future<void> publishChosen(ShareNeedsChoice batch, {String? folder, bool staged = false}) async {
    await _writeChoice(batch, folder: folder, staged: staged);
    final root = await _shares();
    await Directory(batch.directory).rename('${root!.path}/Inbox/${batch.id}');
  }

  Future<void> _announce(String id, Directory batch) async {
    final choice = await _read(id, batch);
    pendingChoices.add(choice);
    _emit(choice);
  }

  Future<String> _stagingOf(String id) async {
    final root = await _shares();
    return '${root!.path}/Staging/$id';
  }

  /// The share page downloads the links of share [id] into a staging folder, not the library.
  Future<ShareStaged> stage(String id, List<String> links) async {
    final dir = await Directory(await _stagingOf(id)).create(recursive: true);
    final path = dir.path;
    return coreRunAsync(() => Core.shareStage(path, links));
  }

  /// The person chose: what was shared goes into the library, in [folder] (or none). Links that
  /// did not come down are named in the report the page showed, and dropped.
  Future<void> confirm(ShareNeedsChoice batch, {String? folder, bool staged = false}) async {
    pendingChoices.remove(batch);
    await _writeChoice(batch, folder: folder, staged: staged);
    await drain();
  }

  Future<void> _writeChoice(ShareNeedsChoice batch, {String? folder, bool staged = false}) async {
    final staging = await _stagingOf(batch.id);
    final out = '${batch.directory}/post.tlpack';
    if (staged) await coreRunAsync(() => Core.sharePack(staging, out));
    final links = File('${batch.directory}/_links.json');
    if (await links.exists()) await links.delete();
    await File('${batch.directory}/_share.json').writeAsString(jsonEncode({'version': 1, 'folder': folder ?? '', 'dropped': _alwaysAsk.remove(batch.id), 'links': const <String>[]}));
    final stage = Directory(staging);
    if (await stage.exists()) await stage.delete(recursive: true);
  }

  /// 清除所有数据: what is waiting here and what was kept from earlier shares.
  Future<void> wipe() async {
    final root = await _shares();
    if (root == null) return;
    for (final name in ['Inbox', 'Kept', 'Links', 'Staging', 'Requests', 'RequestsDone']) {
      final d = Directory('${root.path}/$name');
      if (await d.exists()) await d.delete(recursive: true);
    }
    pendingChoices.clear();
    _asked.clear();
  }

  /// Where this app keeps copies of what it imported: an import record may delete those with it,
  /// never an original outside the app.
  Future<List<String>> ownedRoots() async {
    final root = await _shares();
    return root == null ? const [] : [root.path];
  }

  /// Closed without choosing: nothing was added anywhere.
  Future<void> discard(ShareNeedsChoice batch) async {
    pendingChoices.remove(batch);
    for (final d in [Directory(batch.directory), Directory(await _stagingOf(batch.id))]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
    _asked.remove(batch.id);
  }

  /// The library's folders for the share pages that do not open the library.
  Future<void> publishFolders(List<String> names) async {
    if (!OS.isIOS && !OS.isMacOS && !OS.isAndroid) return;
    final root = await _shares();
    if (root == null) return;
    await root.create(recursive: true);
    await File('${root.path}/folders.json').writeAsString(jsonEncode(names));
  }

  Future<void> dispose() async {
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    for (final watcher in _watchers) {
      await watcher.cancel();
    }
    await _running;
    await _events.close();
  }
}
