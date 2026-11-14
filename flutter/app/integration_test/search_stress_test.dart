import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:twimshelf/app/shell.dart';
import 'package:twimshelf/main.dart' as app;
import 'package:twimshelf/screens/browse_page.dart';
import 'package:twimshelf/screens/viewer_page.dart';
import 'package:twimshelf/widgets/capsule_search.dart';

/// A search, then a long while of browsing and working in its results: scrolling, turning the
/// pages of cards to the last and back, opening media and closing them.
/// Every frame's build and raster time and the process's memory are recorded.
///   TL_LIBRARY_DIR=<a library with posts> TL_SEARCH='贴文 的' flutter test integration_test/search_stress_test.dart -d macos
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('working in search results stays smooth', (tester) async {
    app.main();
    for (var i = 0; i < 600 && find.byType(Shell).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 100 && find.byType(PostCard).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PostCard), findsWidgets, reason: 'the library has posts');

    final frames = <double>[];
    final samples = <Map<String, Object>>[];
    var phase = 'start';
    void record(List<FrameTiming> t) {
      for (final f in t) {
        final total = f.totalSpan.inMicroseconds / 1000;
        frames.add(total);
        if (total > 250) {
          // ignore: avoid_print
          print('LONG-FRAME phase=$phase total=$total build=${f.buildDuration.inMicroseconds / 1000} raster=${f.rasterDuration.inMicroseconds / 1000} vsyncOverhead=${f.vsyncOverhead.inMicroseconds / 1000}');
        }
      }
    }

    Future<void> settle([int n = 20]) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    SchedulerBinding.instance.addTimingsCallback(record);
    // the search the app started with (TL_SEARCH: the home page reads it in debug and profile runs)
    final search = Platform.environment['TL_SEARCH'] ?? '';
    expect(search, isNotEmpty, reason: 'run with TL_SEARCH');
    await settle(30);
    for (var i = 0; i < 50 && find.byType(PostCard).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print('SEARCH-STATE query="$search" cards=${find.byType(PostCard).evaluate().length} end=${find.descendant(of: find.byKey(const ValueKey('feedEnd')), matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data).toList()} keys=${tester.widget<CapsuleSearch>(find.byType(CapsuleSearch).first).initialKeys}');
    var turned = 0, opened = 0;
    // the list that holds the cards (the page's other scrollables come first in the tree)
    Finder feedNow() => find.ancestor(of: find.byType(PostCard).first, matching: find.byType(Scrollable)).first;
    Future<void> closeViewer() async {
      while (find.byType(ViewerPage).evaluate().isNotEmpty) {
        tester.state<NavigatorState>(find.ancestor(of: find.byType(ViewerPage), matching: find.byType(Navigator)).first).pop();
        await settle(30);
      }
    }
    // scrolled through its position (a drag that starts on a card would open it instead)
    ScrollPosition? lastPosition;
    Future<void> scrollBy(double dy) async {
      if (find.byType(PostCard).evaluate().isEmpty) {
        final p = lastPosition;
        // ignore: avoid_print
        print('NO-CARDS pixels=${p?.pixels} max=${p?.maxScrollExtent} texts=${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).whereType<String>().toList()}');
        throw StateError('the cards are gone');
      }
      final p = lastPosition = tester.state<ScrollableState>(feedNow()).position;
      final to = (p.pixels + dy).clamp(p.minScrollExtent, p.maxScrollExtent);
      await p.animateTo(to, duration: const Duration(milliseconds: 450), curve: Curves.decelerate);
      await settle(8);
    }
    final rounds = int.tryParse(Platform.environment['TL_ROUNDS'] ?? '') ?? 10;
    for (var round = 0; round < rounds; round++) {
      await closeViewer();
      phase = 'scroll $round';
      for (var i = 0; i < 4; i++) {
        await scrollBy(2200);
      }
      await scrollBy(-1100);
      // TL_ONLY_SCROLL: scrolling alone (no page turns, nothing opened)
      if (Platform.environment['TL_ONLY_SCROLL'] != null) {
        samples.add({'round': round, 'rss_mb': ProcessInfo.currentRss / 1048576, 'images': 0, 'playing': 0, 'idle': 0});
        continue;
      }
      // a card with several pages: to its last page and back
      final pagers = find.descendant(of: find.byType(PostCard), matching: find.byType(PageView)).hitTestable();
      if (pagers.evaluate().isNotEmpty) {
        final pager = pagers.first;
        final count = tester.widget<PageView>(pager).childrenDelegate.estimatedChildCount ?? 1;
        if (count > 1) {
          phase = 'turn $round ($count pages)';
          // (a fling taken as a tap opens the media instead: then this card is done)
          for (var p = 1; p < 2 * count - 1 && pager.evaluate().isNotEmpty; p++) {
            await tester.fling(pager, Offset(p < count ? -300 : 300, 0), 1500);
            await settle(15);
          }
          await closeViewer();
          turned++;
        }
      }
      // open a media and close it
      // the media area of a card (its page view), never a tag chip or the "+" beside them
      final media = find.descendant(of: find.descendant(of: find.byType(PostCard), matching: find.byType(PageView)), matching: find.byType(GestureDetector)).hitTestable();
      if (media.evaluate().isNotEmpty) {
        phase = 'open $round';
        await tester.tap(media.first);
        await settle(40);
        if (find.byType(ViewerPage).evaluate().isNotEmpty) {
          opened++;
          await closeViewer();
        }
      }
      if (round >= 11 && round <= 13) {
        final ids = find.byType(PostCard).evaluate().map((e) => (e.widget as PostCard).media.map((m) => '${m.media_id.substring(0, 10)}:${m.kind.name}').join('+')).toList();
        // ignore: avoid_print
        print('ROUND-$round worst-so-far=${frames.isEmpty ? 0 : (List.of(frames)..sort()).last} cards=$ids');
      }
      final players = feedVideoPlayers();
      samples.add({'round': round, 'rss_mb': ProcessInfo.currentRss / 1048576, 'images': PaintingBinding.instance.imageCache.currentSize, 'playing': players.playing, 'idle': players.idle});
    }
    SchedulerBinding.instance.removeTimingsCallback(record);

    frames.sort();
    final result = {
      'frames': frames.length,
      'over_50ms': frames.where((f) => f > 50).length,
      'over_100ms': frames.where((f) => f > 100).length,
      'p99_ms': frames.isEmpty ? 0 : frames[(frames.length * .99).floor().clamp(0, frames.length - 1)],
      'worst_ms': frames.isEmpty ? 0 : frames.last,
      'turned': turned,
      'opened': opened,
      'samples': samples,
      'results': find.byType(PostCard).evaluate().length,
      'browse': find.byType(BrowsePage).evaluate().length,
    };
    // ignore: avoid_print
    print('SEARCH-STRESS ${jsonEncode(result)}');
    final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/perf')..createSync(recursive: true);
    File('${dir.path}/search_stress.json').writeAsStringSync(jsonEncode(result));
    if (Platform.environment['TL_ONLY_SCROLL'] == null) expect(turned + opened, greaterThan(0), reason: 'something to work with in the results');
  });
}
