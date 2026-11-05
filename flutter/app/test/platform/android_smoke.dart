// Widget-free synthetic Android acceptance target. Never opens the normal library.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as image;
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/platform/multicast.dart';
import 'package:twimshelf/platform/background_work.dart';
import 'package:twimshelf/services/downloads.dart';

Future<void> _open(String path) => Isolate.run(() {
  if (!Core.open(path)) throw StateError('a1.open');
});
Future<SyncStatus> _syncStatus() => Isolate.run(Core.syncStatus);
Future<DiscoveryStatus> _discovery() => Isolate.run(Core.discoveryStatus);
Future<Set<String>> _liveIds() =>
    Isolate.run(() => Core.feed(FeedRequest()).map((m) => m.post_id).toSet());
Future<LibraryStats> _stats() => Isolate.run(Core.stats);
Future<void> _start(String account, String name) => Isolate.run(() {
  Core.syncStart(account, name);
  Core.discoveryStart('_twlib-debug._tcp', name);
});
Future<void> _cookies() => Isolate.run(() => Core.setCookies('', ''));

class SyntheticNativeDownloads extends NativeDownloadCore {
  @override
  Future<void> applyCookies(DownloadRoute route) => _cookies();
}

class Lifecycle extends WidgetsBindingObserver {
  bool background = false;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    background =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
  }
}

Future<void> main() async {
  if (!kDebugMode || !Platform.isAndroid) return;
  WidgetsFlutterBinding.ensureInitialized();
  final lifecycle = Lifecycle();
  WidgetsBinding.instance.addObserver(lifecycle);
  await L10n.load(locale: const Locale('en'));
  final support = await getApplicationSupportDirectory();
  final output = File('${support.path}/a1-result.json');
  final record = <String, Object?>{'phase': 'starting', 'ok': false};
  Future<void> save() => output.writeAsString(jsonEncode(record), flush: true);
  DownloadService? downloads;
  HttpServer? server;
  HttpClient? client;
  try {
    const account = String.fromEnvironment('A1_ACCOUNT');
    if (account.length != 64) throw StateError('a1.syntheticAccountRequired');
    final foreground = AndroidBackgroundWork();
    for (var i = 0; i < 2; i++) {
      await foreground.start();
      await foreground.stop();
      final state = await const MethodChannel(
        'org.twimshelf/android_platform',
      ).invokeMapMethod<String, dynamic>('platformStatus');
      if (state?['foreground'] != false) {
        throw StateError('a1.foregroundStopAck');
      }
    }
    foreground.dispose();
    record['rapid_cycle'] = true;
    final root = await Directory(
      '${support.path}/a1-synthetic-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    record['library'] = root.path;
    record['stage'] = 'open';
    await save();
    await _open(root.path);
    final local = await _syncStatus();
    final suffix = local.device_id.substring(0, 6);
    final name = 'A1-$suffix';
    final base = 9000000000000000000 + int.parse(suffix, radix: 16) * 100;
    record['stage'] = 'seed';
    await save();
    final input = await Directory('${root.path}/input').create();
    for (var i = 0; i < 60; i++) {
      final post = await Directory('${input.path}/${base + i}').create();
      final picture = image.Image(width: 16, height: 16, numChannels: 3);
      image.fill(
        picture,
        color: image.ColorRgb8(
          i + 1,
          int.parse(suffix.substring(0, 2), radix: 16),
          20,
        ),
      );
      for (var j = 0; j < local.device_id.length; j++) {
        picture.setPixelRgb(
          j % 16,
          j ~/ 16,
          local.device_id.codeUnitAt(j),
          i + 1,
          20,
        );
      }
      await File('${post.path}/1.png').writeAsBytes(image.encodePng(picture));
      await File('${post.path}/\u63A8\u6587\u5185\u5BB9.txt').writeAsString(
        '\u63A8\u6587 ID: ${base + i}\n\u3010\u63A8\u6587\u5B8C\u6574\u6B63\u6587\u3011\nsynthetic $i',
      );
    }
    await Core.importLegacyDirectoryAsync(input.path);
    final before = await _stats();
    if (before.posts != 60) throw StateError('a1.seed');
    await Multicast.acquire();
    await _start(account, name);
    record.addAll({'phase': 'lan', 'name': name, 'posts_before': before.posts});
    await save();
    final lan = Stopwatch()..start();
    var found = false, synced = false;
    while (lan.elapsed < const Duration(seconds: 90)) {
      final discovery = await _discovery();
      final peers = discovery.peers
          .where((p) => p.name.startsWith('A1-') && p.name != name)
          .toList();
      found = found || peers.isNotEmpty;
      final stats = await _stats();
      final syncStatus = await _syncStatus();
      record['sync_failures'] = syncStatus.failed;
      synced = stats.posts > before.posts;
      record.addAll({
        'phase': 'lan',
        'found': found,
        'synced': synced,
        'posts': stats.posts,
        'network_ok': discovery.network_ok,
        'peers': peers
            .map((p) => {'name': p.name, 'host': p.host, 'port': p.port})
            .toList(),
      });
      await save();
      if (found) Core.discoverySyncNow();
      if (found && synced) break;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final service = DownloadService(
      core: SyntheticNativeDownloads(),
      store: FileDownloadQueueStore(File('${root.path}/downloads.queue.json')),
    );
    downloads = service;
    await service.initialize();
    service.intervalMs = 1000;
    service.concurrency = 1;
    final urls = List.generate(60, (i) => 'https://x.com/i/status/${base + i}');
    // These posts are all live in this synthetic library. Rust processes its
    // real durable queue without contacting a public post/media API.
    final liveIds = await _liveIds();
    if (!List.generate(60, (i) => '${base + i}').every(liveIds.contains)) {
      throw StateError('a1.onlyKnownSyntheticUrls');
    }
    await service.enqueueLinks(urls);
    await service.start();
    final httpBytes = Uint8List(65536)..fillRange(0, 65536, 37);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.forEach((request) async {
      request.response.contentLength = 30 * httpBytes.length;
      try {
        for (var i = 0; i < 30; i++) {
          request.response.add(httpBytes);
          await request.response.flush();
          await Future<void>.delayed(const Duration(seconds: 1));
        }
        await request.response.close();
      } catch (_) {}
    });
    client = HttpClient();
    var received = 0;
    final transfer = (() async {
      final request = await client!.getUrl(
        Uri.parse('http://127.0.0.1:${server!.port}/synthetic'),
      );
      final response = await request.close();
      await for (final bytes in response) {
        if (bytes.any((b) => b != 37)) throw StateError('a1.syntheticBytes');
        received += bytes.length;
      }
    })().catchError((Object _) {});
    var backgroundTicks = 0, maxBackgroundSkipped = 0;
    record['phase'] = 'background';
    await save();
    final work = Stopwatch()..start();
    while (service.status?.running == true &&
        work.elapsed < const Duration(seconds: 100)) {
      await service.poll();
      final status = service.status!;
      if (lifecycle.background) {
        backgroundTicks++;
        if (status.skipped > maxBackgroundSkipped) {
          maxBackgroundSkipped = status.skipped;
        }
      }
      final platform = await const MethodChannel(
        'org.twimshelf/android_platform',
      ).invokeMapMethod<String, dynamic>('platformStatus');
      record.addAll({
        'phase': 'background',
        'skipped': status.skipped,
        'paused': status.paused,
        'running': status.running,
        'outcome': status.outcome,
        'background_ticks': backgroundTicks,
        'background_skipped': maxBackgroundSkipped,
        'http_bytes': received,
        'foreground': platform?['foreground'],
        'multicast': platform?['multicast'],
      });
      await save();
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final status = service.status!;
    record.addAll({
      'skipped': status.skipped,
      'paused': status.paused,
      'running': status.running,
      'outcome': status.outcome,
    });
    if (status.outcome == 'paused') {
      record.addAll({
        'phase': 'complete',
        'quota_paused': true,
        'ok': found && synced && status.paused > 0,
      });
    } else {
      await transfer.timeout(const Duration(seconds: 45));
      record.addAll({
        'phase': 'complete',
        'http_bytes': received,
        'ok':
            found &&
            synced &&
            status.skipped == 60 &&
            status.failed == 0 &&
            received == 30 * 65536 &&
            backgroundTicks > 0 &&
            maxBackgroundSkipped > 0,
      });
    }
    await server.close(force: true);
    await serving;
    await service.close();
    record['foreground_after'] = (await const MethodChannel(
      'org.twimshelf/android_platform',
    ).invokeMapMethod<String, dynamic>('platformStatus'))?['foreground'];
    await save();
  } catch (error) {
    record.addAll({
      'phase': 'error',
      'error': error is StateError
          ? error.message
          : error.runtimeType.toString(),
    });
    await save();
  } finally {
    client?.close(force: true);
    await server?.close(force: true);
    if (downloads != null) {
      try {
        await downloads.close();
      } catch (_) {}
    }
    Core.discoveryStop();
    await Multicast.release();
    WidgetsBinding.instance.removeObserver(lifecycle);
  }
}
