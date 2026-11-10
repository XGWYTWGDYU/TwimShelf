import 'dart:convert';
import 'dart:io';

import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;

import 'shared_links.dart';
import 'system_random.dart';
import 'os.dart';

/// Desktop shells may pass several files after --import. Everything after --
/// is literal, allowing a filename beginning with a dash.
List<String> parseDesktopImportArguments(List<String> arguments) {
  final result = <String>[];
  var importing = false;
  var literal = false;
  for (final argument in arguments) {
    if (argument.contains('\u0000')) {
      throw const FormatException('shareInbox.arguments');
    }
    if (!literal && argument == '--import') {
      importing = true;
    } else if (!literal && argument.startsWith('--import=')) {
      importing = true;
      result.add(argument.substring(9));
    } else if (importing && !literal && argument == '--') {
      literal = true;
    } else if (importing) {
      if (!literal && argument.startsWith('--')) {
        throw const FormatException('shareInbox.arguments');
      }
      result.add(argument);
    }
  }
  if (importing && (result.isEmpty || result.any((s) => s.isEmpty))) {
    throw const FormatException('shareInbox.arguments');
  }
  return result;
}

String resolveDesktopPath(String value, String cwd, {bool? windows}) {
  final win = windows ?? OS.isWindows;
  final context = p.Context(style: win ? p.Style.windows : p.Style.posix);
  final uri = Uri.tryParse(value);
  if (uri != null && uri.hasScheme) {
    if (uri.scheme == 'file') return uri.toFilePath(windows: win);
    // A Windows drive letter is a path, not a URI scheme.
    if (!(win && RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value))) {
      throw const FormatException('shareInbox.scheme');
    }
  }
  if (!context.isAbsolute(cwd)) throw const FormatException('shareInbox.cwd');
  return context.normalize(
    context.isAbsolute(value) ? value : context.join(cwd, value),
  );
}

/// Ignore our own incomplete writes and consumption deletes. Only a completed
/// publication can wake a failed request for another attempt.
bool isDesktopPublication(FileSystemEvent event, {required bool request}) {
  if (event.type == FileSystemEvent.delete) return false;
  final destination = event is FileSystemMoveEvent ? event.destination : null;
  final filename = p.basename(destination ?? event.path);
  return request
      ? filename.endsWith('.json')
      : event.isDirectory && RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(filename);
}

/// Durable shell-to-app handoff. Original media is copied, never consumed.
/// Requests remain retryable on failure. A receipt prevents replay after the
/// normal inbox consumer has removed a successfully published batch.
class DesktopInbox {
  DesktopInbox(this.root, {this.quickDownload});
  final Directory root;
  /// A request from the icon's 下载帖子 (`--quick-download`).
  final void Function()? quickDownload;
  static const _random = SystemRandom();
  static String newId() =>
      '${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(0x100000000)}';
  static bool _safe(String id) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id);

  Future<void> enqueue(
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (parseDesktopImportArguments(arguments).isEmpty) return;
    final requests = await Directory('${root.path}/Requests')
        .create(recursive: true);
    final id = newId();
    await _atomic(
      File('${requests.path}/$id.json'),
      jsonEncode({
        'version': 1,
        'arguments': arguments,
        'workingDirectory': workingDirectory ?? Directory.current.path,
      }),
    );
  }

  static Future<void> _atomic(File destination, String contents) async {
    final temporary = File('${destination.path}.${newId()}.partial');
    try {
      await temporary.create(exclusive: true);
      await temporary.writeAsString(contents, flush: true);
      await temporary.rename(destination.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<int> publishRequests() async {
    final requests = Directory('${root.path}/Requests');
    if (!await requests.exists()) return 0;
    final files = await requests
        .list(followLinks: false)
        .where((e) => e is File && e.path.endsWith('.json'))
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    var failures = 0;
    for (final entity in files) {
      try {
        await _publish(entity as File);
      } catch (_) {
        failures++;
      }
    }
    return failures;
  }

  Future<void> _publish(File request) async {
    final id = p.basenameWithoutExtension(request.path);
    if (!_safe(id)) throw const FormatException('shareInbox.id');
    final done = File('${root.path}/RequestsDone/$id.done');
    final batch = Directory('${root.path}/Inbox/$id');
    if (!await done.exists() && !await batch.exists()) {
      if (await request.length() > 1024 * 1024) {
        throw const FormatException('shareInbox.size');
      }
      final data = jsonDecode(await request.readAsString()) as Map;
      if (data['version'] != 1) {
        throw const FormatException('shareInbox.version');
      }
      final args = (data['arguments'] as List).cast<String>();
      if (args.contains('--quick-download')) {
        quickDownload?.call();
        await request.delete();
        return;
      }
      final cwd = data['workingDirectory'] as String;
      final items = parseDesktopImportArguments(args);
      if (items.isEmpty) throw const FormatException('shareInbox.empty');
      final partial = Directory('${batch.path}.partial');
      await batch.parent.create(recursive: true);
      // Only this primary process drains requests. A partial from a previous
      // crash has never been visible to the consumer and can be reconstructed.
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create();
      try {
        final links = <String>{};
        var index = 0;
        for (final item in items) {
          final urls = parseSharedPostLinks(item);
          final uri = Uri.tryParse(item);
          if (urls.isNotEmpty && (uri?.scheme != 'file')) {
            links.addAll(urls);
            continue;
          }
          final source = resolveDesktopPath(item, cwd);
          if (await FileSystemEntity.type(source, followLinks: false) !=
              FileSystemEntityType.file) {
            throw const FileSystemException('shareInbox.regularFile');
          }
          final file = File(source);
          final handle = await file.open();
          late List<int> header;
          try {
            header = await handle.read(32);
          } finally {
            await handle.close();
          }
          final mime = lookupMimeType(source, headerBytes: header);
          if (mime == null ||
              !(mime.startsWith('image/') || mime.startsWith('video/'))) {
            throw const FormatException('shareInbox.media');
          }
          final rawName = p
              .basename(source)
              .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
          final name = rawName.length > 160
              ? rawName.substring(rawName.length - 160)
              : rawName;
          final namedMime = lookupMimeType(source);
          final extension = extensionFromMime(mime);
          final suffix = extension != null && namedMime != mime
              ? '.$extension'
              : '';
          final copy = await file.copy(
            '${partial.path}/${index++}_$name$suffix',
          );
          final output = await copy.open(mode: FileMode.append);
          try {
            await output.flush();
          } finally {
            await output.close();
          }
        }
        if (links.isNotEmpty) {
          await File('${partial.path}/_links.json')
              .writeAsString(jsonEncode(links.toList()), flush: true);
        }
        await partial.rename(batch.path);
      } catch (_) {
        if (await partial.exists()) await partial.delete(recursive: true);
        rethrow;
      }
    }
    await done.parent.create(recursive: true);
    if (!await done.exists()) await _atomic(done, '1');
    await request.delete();
  }
}
