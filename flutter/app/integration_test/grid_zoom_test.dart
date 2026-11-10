import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/app/places.dart';
import 'package:twimshelf/grid/zoom_grid.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/grid_page.dart';
import 'package:twimshelf/screens/settings/storage_page.dart';

/// The photo grid zooms by pinching, on the real app with the native core: spreading two
/// fingers goes to fewer columns, pinching in to more, and each zoom comes to rest.
/// Run with TL_LIBRARY_DIR pointing at a synthetic (seeded) library.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LibraryModel library;
  setUpAll(() async {
    final destination = Platform.environment['TL_LIBRARY_DIR'];
    final source = Platform.environment['TL_IMPORT_DIR'];
    if (destination == null || source == null ||
        !File('$source/seed.json').existsSync()) {
      throw StateError('Use a fresh TL_LIBRARY_DIR and synthetic TL_IMPORT_DIR');
    }
    await L10n.load();
    await Prefs.load();
    library = await LibraryModel.open();
  });

  Future<void> pinch(WidgetTester tester, Offset c, double from, double to, {bool settle = true}) async {
    final a = await tester.startGesture(c - Offset(from, 0), pointer: 1);
    final b = await tester.startGesture(c + Offset(from, 0), pointer: 2);
    for (var i = 1; i <= 20; i++) {
      final d = from + (to - from) * i / 20;
      await a.moveTo(c - Offset(d, 0));
      await b.moveTo(c + Offset(d, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    if (!settle) return;
    // let the settle run to its end
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('pinching changes the column level and comes to rest', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ZoomGrid), findsOneWidget, reason: 'the seeded library has photos');
    final state = tester.state<ZoomGridState>(find.byType(ZoomGrid));
    final c = tester.getCenter(find.byType(ZoomGrid));
    expect(state.rest!.level, 1);

    await pinch(tester, c, 40, 160); // spread
    expect(state.rest!.level, 2, reason: 'fewer, bigger columns');

    await pinch(tester, c, 160, 30); // pinch in, through the middle level to the densest
    expect(state.rest!.level, lessThan(2));
  });

  testWidgets('the toolbar buttons zoom one level each, without springing back', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final state = tester.state<ZoomGridState>(find.byType(ZoomGrid));
    Future<void> tap(String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    bool enabled(String key) => tester.widget<IconButton>(find.byKey(ValueKey(key))).onPressed != null;
    expect(state.rest!.level, 1);
    await tap('gridZoomIn');
    expect(state.rest!.level, 2, reason: 'fewer columns');
    expect(enabled('gridZoomIn'), isFalse, reason: 'the biggest level');
    await tap('gridZoomOut');
    expect(state.rest!.level, 1);
    await tap('gridZoomOut');
    expect(state.rest!.level, 0);
    expect(enabled('gridZoomOut'), isFalse, reason: 'the densest level');
    await tap('gridZoomIn');
    expect(state.rest!.level, 1);
    expect(enabled('gridZoomOut'), isTrue);
  });

  testWidgets('the storage page measures', (tester) async {
    await tester.pumpWidget(MaterialApp(home: StoragePage(library: library)));
    for (var i = 0; i < 100 && find.textContaining('Isolate').evaluate().isEmpty && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('repeated pinches at the top leave no empty places and no offset disagreement', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final state = tester.state<ZoomGridState>(find.byType(ZoomGrid));
    final box = tester.getRect(find.byType(ZoomGrid));
    final scroll = tester.state<ScrollableState>(find.descendant(of: find.byType(ZoomGrid), matching: find.byType(Scrollable)).first);
    // off-centre, asymmetric pinches near the top: the kind that left a phase behind
    final points = [box.topLeft + const Offset(60, 120), box.topRight + const Offset(-80, 160), box.topCenter + const Offset(0, 90)];
    for (var round = 0; round < 6; round++) {
      final p = points[round % points.length];
      await pinch(tester, p, round.isEven ? 40 : 150, round.isEven ? 150 : 40);
      final r = state.rest!;
      // at rest near the top the first row is full
      if (r.offset < 200) expect(r.phase, 0, reason: 'round $round left phase ${r.phase} at offset ${r.offset}');
      // the engine and the scroll view agree on where the grid is
      expect((scroll.position.pixels - r.offset).abs(), lessThan(1.0), reason: 'round $round: scroll ${scroll.position.pixels} vs engine ${r.offset}');
    }
  });
  testWidgets('a drag immediately after pinch interrupts settling', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final grid = find.byType(ZoomGrid);
    final state = tester.state<ZoomGridState>(grid);
    await pinch(tester, tester.getCenter(grid), 40, 140, settle: false);
    // Just one display frame to deliver pointer-up's physics change; no settle wait.
    await tester.pump(const Duration(milliseconds: 16));
    final drag = await tester.startGesture(tester.getCenter(grid), pointer: 3);
    await tester.pump(const Duration(milliseconds: 16));
    final before = state.rest!.offset;
    for (var i = 0; i < 6; i++) {
      await drag.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.rest!.offset, greaterThan(before + 80));
    await drag.up();
    final scroll = tester.state<ScrollableState>(find.descendant(of: grid, matching: find.byType(Scrollable)).first);
    expect((scroll.position.pixels - state.rest!.offset).abs(), lessThan(1));
  });

  // The scroll view only gets the engine's offset a frame after a zoom ends, and not at all
  // while one settles: a pinch beginning then must not take the scroll view's old offset (that
  // threw the grid most of the way to the top after a zoom in).
  testWidgets('a pinch that goes on or starts again during the settle keeps its place', (tester) async {
    await tester.pumpWidget(MaterialApp(home: GridPage(key: UniqueKey(), library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final grid = find.byType(ZoomGrid);
    final state = tester.state<ZoomGridState>(grid);
    final c = tester.getCenter(grid);
    final local = tester.getRect(grid).size.center(Offset.zero);
    ScrollableState scrollable() => tester.state<ScrollableState>(find.descendant(of: grid, matching: find.byType(Scrollable)).first);
    Future<void> frames(int n) async {
      for (var i = 0; i < n; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    Future<void> move(TestGesture a, TestGesture b, double from, double to) async {
      for (var i = 1; i <= 20; i++) {
        final d = from + (to - from) * i / 20;
        await a.moveTo(c - Offset(d, 0));
        await b.moveTo(c + Offset(d, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
    }
    Future<int> startFarDown() async {
      await frames(120);
      final position = scrollable().position;
      position.jumpTo(position.maxScrollExtent * 0.7);
      await frames(3);
      final index = state.indexAt(local) ?? state.indexAt(local + const Offset(0, 12));
      expect(index, isNotNull);
      expect(index!, greaterThan(200), reason: 'the seeded library is long enough to tell');
      return index;
    }
    Future<void> expectStillThere(int before, String what) async {
      await frames(120);
      final after = state.indexAt(local) ?? state.indexAt(local + const Offset(0, 12));
      expect(after, isNotNull, reason: what);
      expect((after! - before).abs(), lessThan(before ~/ 4), reason: '$what: item $before was under the fingers, now $after');
      final r = state.rest!;
      expect((scrollable().position.pixels - r.offset).abs(), lessThan(1.0), reason: what);
    }

    // one finger lifts and comes back while the zoom in settles, then both pinch back
    var before = await startFarDown();
    var a = await tester.startGesture(c - const Offset(40, 0), pointer: 11);
    var b = await tester.startGesture(c + const Offset(40, 0), pointer: 12);
    await move(a, b, 40, 160);
    await b.up();
    await frames(2);
    b = await tester.startGesture(c + const Offset(160, 0), pointer: 13);
    await move(a, b, 160, 55);
    await a.up();
    await b.up();
    await expectStillThere(before, 'a finger back during the settle');

    // both lift after the zoom in and are back at once, before the settle has ended
    before = await startFarDown();
    a = await tester.startGesture(c - const Offset(40, 0), pointer: 14);
    b = await tester.startGesture(c + const Offset(40, 0), pointer: 15);
    await move(a, b, 40, 160);
    await a.up();
    await b.up();
    await frames(2);
    a = await tester.startGesture(c - const Offset(160, 0), pointer: 16);
    b = await tester.startGesture(c + const Offset(160, 0), pointer: 17);
    await move(a, b, 160, 55);
    await a.up();
    await b.up();
    await expectStillThere(before, 'a new pinch during the settle');

    // a button's step right after a touch ended a settle
    before = await startFarDown();
    a = await tester.startGesture(c - const Offset(40, 0), pointer: 18);
    b = await tester.startGesture(c + const Offset(40, 0), pointer: 19);
    await move(a, b, 40, 160);
    await a.up();
    await b.up();
    await frames(2);
    final level = state.rest!.level;
    a = await tester.startGesture(c, pointer: 20);
    state.step(1);
    await a.up();
    await frames(120);
    if (state.rest!.level == level) state.step(1);
    await expectStillThere(before, 'a step during the handover');
  });

  testWidgets('synthetic thumbnails retain scroll-back images and video posters', (tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(1179, 2556);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(home: GridPage(library: library, place: Place.photos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final grid = find.byType(ZoomGrid);
    final widget = tester.widget<ZoomGrid>(grid);
    expect(widget.items.length, greaterThanOrEqualTo(500));
    final store = widget.store;
    expect(store.smallSide, 448);
    expect(store.largeSide, 1536);
    final watch = Stopwatch()..start();
    final first = widget.items.take(20).where((i) => !i.path.endsWith('damaged.jpg')).toList();
    for (var i = 0; i < 200 && first.any((item) => !store.hasImage(item.media_id) && !store.isFailed(item.media_id)); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    debugPrint('G1 first sample: loaded=${first.where((i) => store.hasImage(i.media_id)).length}, failed=${first.where((i) => store.isFailed(i.media_id)).length}, requests=${store.loads}');
    expect(first.where((i) => store.isFailed(i.media_id)).length, lessThanOrEqualTo(1));
    first.removeWhere((i) => store.isFailed(i.media_id));
    expect(first.every((item) => store.hasImage(item.media_id)), isTrue);
    final firstMs = watch.elapsedMilliseconds;
    final scroll = tester.state<ScrollableState>(find.descendant(of: grid, matching: find.byType(Scrollable)).first);
    for (var i = 0; i < 40; i++) {
      scroll.position.jumpTo((scroll.position.pixels + 30).clamp(0, scroll.position.maxScrollExtent));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final retained = first.where((item) => store.hasImage(item.media_id)).length;
    expect(retained, first.length);
    final loads = store.loads;
    scroll.position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(first.every((item) => store.hasImage(item.media_id)), isTrue);
    debugPrint('G1 photos: first20=${firstMs}ms retained=$retained/${first.length} loads=$loads bytes=${store.decodedBytes}');
    // Under pressure, keep a drawn tile and a prefetched margin tile; evict cold ones.
    final budget = store.budget;
    store.budget = 1 << 20;
    for (var i = 0; i < 3; i++) {
      store.beginFrame();
      store.image(first[0].media_id, 390, item: first[0]);
      store.prefetch(first[1]);
      store.endFrame();
    }
    expect(store.hasImage(first[0].media_id), isTrue);
    expect(store.hasImage(first[1].media_id), isTrue);
    expect(store.hasImage(first[2].media_id), isFalse);
    store.budget = budget;
    await tester.pumpWidget(MaterialApp(home: GridPage(key: UniqueKey(), library: library, place: Place.videos)));
    for (var i = 0; i < 50 && find.byType(ZoomGrid).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final video = tester.widget<ZoomGrid>(grid).items.first;
    watch.reset();
    for (var i = 0; i < 300 && !store.hasImage(video.media_id); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(store.hasImage(video.media_id), isTrue);
    debugPrint('G1 video: poster=${watch.elapsedMilliseconds}ms');
    final cached = File('${Platform.environment['TL_LIBRARY_DIR']}/.thumbs/${store.smallSide}/${video.media_id}.jpg');
    final modified = await cached.lastModified();
    store.clear();
    store.beginFrame();
    store.prefetch(video);
    store.endFrame();
    watch.reset();
    for (var i = 0; i < 200 && !store.hasImage(video.media_id); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(store.hasImage(video.media_id), isTrue);
    expect(await cached.lastModified(), modified, reason: 'disk hit must reuse the poster');
    debugPrint('G1 video disk hit: ${watch.elapsedMilliseconds}ms');
  });

}
