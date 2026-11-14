import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/shell.dart';
import 'package:twimshelf/main.dart' as app;

/// 浏览 scrolled hard on a real device for a long while, in landscape and then turned upright,
/// with every frame's build and raster time, the process's memory and the image cache recorded:
/// where a scroll stutters, whether memory keeps growing, and what turning the device costs.
///
/// It reads the library the app opens. An empty library (a bundle id of its own) is filled with
/// synthetic posts whose photos are the size of real ones; a library with posts is only scrolled.
///   flutter drive --profile -d DEVICE --driver test_driver/perf_driver.dart --target integration_test/browse_scroll_perf_test.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('browse scrolls without long frames', (tester) async {
    final started = DateTime.now();
    app.main();
    for (var i = 0; i < 600 && find.byType(Shell).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final shellAt = DateTime.now().difference(started).inMilliseconds;
    final library = tester.widget<Shell>(find.byType(Shell)).library;
    if ((library.stats?.posts ?? 0) < 100) {
      final dir = await tester.runAsync(() async {
        final d = Directory('${(await getTemporaryDirectory()).path}/perf-seed');
        if (await d.exists()) await d.delete(recursive: true);
        await compute(_seed, d.path);
        return d.path;
      });
      await tester.runAsync(() => Core.importLegacyDirectoryAsync(dir!));
      await tester.runAsync(() => library.refresh());
    }
    // the feed in (its first cards built) and its first pictures decoded
    var feedAt = -1;
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (feedAt < 0 && find.byType(Image).evaluate().isNotEmpty) feedAt = DateTime.now().difference(started).inMilliseconds;
    }

    final frames = <Map<String, Object>>[];
    final samples = <Map<String, Object>>[];
    var phase = 'landscape';
    void record(List<FrameTiming> t) {
      for (final f in t) {
        frames.add({
          'phase': phase,
          'build': f.buildDuration.inMicroseconds / 1000,
          'raster': f.rasterDuration.inMicroseconds / 1000,
          'total': f.totalSpan.inMicroseconds / 1000,
          'start': f.timestampInMicroseconds(FramePhase.buildStart),
        });
      }
    }

    // the cards' list (on a wide screen the sidebar is a scrollable too, and comes first)
    final feed = find.descendant(of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first;
    double offset() => tester.state<ScrollableState>(feed).position.pixels;
    void sample(String label) {
      final cache = PaintingBinding.instance.imageCache;
      samples.add({
        'label': label,
        'phase': phase,
        'ms': DateTime.now().difference(started).inMilliseconds,
        'rss_mb': ProcessInfo.currentRss / 1048576,
        'cache_mb': cache.currentSizeBytes / 1048576,
        'cache_images': cache.currentSize,
        'live_images': cache.liveImageCount,
        'pending_images': cache.pendingImageCount,
        'offset': offset(),
      });
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    await binding.traceAction(() async {
      // a long stretch in landscape: hard flicks down (and now and then back up), as a hand does
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      sample('landscape start');
      for (var round = 0; round < 60; round++) {
        await tester.fling(feed, Offset(0, round % 10 == 9 ? 900 : -900), 2600);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        if (round % 5 == 4) sample('landscape $round');
      }
      // then turned upright
      phase = 'portrait';
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        sample('portrait +${(i + 1) * 250}ms');
      }
      for (var round = 0; round < 10; round++) {
        await tester.fling(feed, const Offset(0, -900), 2600);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
      }
      sample('portrait end');
    }, reportKey: 'timeline');
    SchedulerBinding.instance.removeTimingsCallback(record);
    await SystemChrome.setPreferredOrientations([]);

    final budget = 1000 / (PlatformDispatcher.instance.displays.firstOrNull?.refreshRate ?? 60);
    final result = {
      'shell_ms': shellAt,
      'first_image_ms': feedAt,
      'posts': library.stats?.posts ?? 0,
      'frames': frames,
      'samples': samples,
      'budget_ms': budget,
    };
    binding.reportData = {...?binding.reportData, ...result};
    // also in the app's documents (perf/browse_scroll.json), for a run with no driver attached:
    // `xcrun devicectl device copy from --domain-type appDataContainer` fetches it
    await tester.runAsync(() async {
      final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/perf')..createSync(recursive: true);
      File('${dir.path}/browse_scroll.json').writeAsStringSync(jsonEncode(result));
    });
  });
}

/// 300 posts of the legacy layout (a folder each, 推文内容.txt and one to three photos): photos of
/// 1200 to 1800 pixels with noise in them, so decoding costs what a real photo costs.
void _seed(String root) {
  final rng = Random(7);
  const bodies = ['合成测试：海边与蓝天。', 'Synthetic seaside, blue sky.', '合成測試：海邊與藍天。', '合成テスト：海と青空。'];
  const sizes = [(1200, 1600), (1600, 1200), (1200, 1200), (1080, 1920), (1800, 1200)];
  for (var i = 0; i < 300; i++) {
    final folder = Directory('$root/post-$i')..createSync(recursive: true);
    final id = 1900000000000000000 + i;
    File('${folder.path}/推文内容.txt').writeAsStringSync( // i18n-exempt: the legacy file format
        '作者: Seed ${i % 6} (@seed${i % 6})\n推文 ID: $id\n发布时间: Mon Jan 01 00:00:00 +0000 2024\n' // i18n-exempt: the legacy file format
        '原帖链接: https://x.com/seed${i % 6}/status/$id\n【推文完整正文】\n${bodies[i % bodies.length]} #$i\n'); // i18n-exempt: the legacy file format
    for (var k = 0; k < 1 + i % 3; k++) {
      final (w, h) = sizes[(i + k) % sizes.length];
      final picture = img.Image(width: w, height: h);
      final base = [rng.nextInt(200), rng.nextInt(200), rng.nextInt(200)];
      for (final p in picture) {
        final n = rng.nextInt(56);
        p
          ..r = base[0] + (p.x * 55 ~/ w) + n ~/ 2
          ..g = base[1] + (p.y * 55 ~/ h) + n ~/ 2
          ..b = base[2] + n;
      }
      File('${folder.path}/photo$k.jpg').writeAsBytesSync(img.encodeJpg(picture, quality: 85));
    }
  }
}
