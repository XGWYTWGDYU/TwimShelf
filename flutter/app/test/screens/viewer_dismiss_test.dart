import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/viewer_page.dart';

FeedItem _photo(String id) => FeedItem(
      media_id: id,
      post_id: 'post-$id',
      ordinal: 0,
      kind: MediaKind.photo,
      path: '/synthetic/$id.jpg',
      width: 1000,
      height: 1500,
    );

FeedItem _video(String id) => FeedItem(
      media_id: id,
      post_id: 'post-$id',
      ordinal: 0,
      kind: MediaKind.video,
      path: '/synthetic/$id.mp4',
      width: 1080,
      height: 1920,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await L10n.load();
    SharedPreferences.setMockInitialValues({});
    await Prefs.load();
  });

  Future<void> openViewer(WidgetTester t, List<FeedItem> items, {int index = 0}) async {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);

    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () {
              ViewerPage.push(
                context,
                library: LibraryModel.forTest('/synthetic/unused'),
                items: items,
                index: index,
                sourceRect: (_) => const Rect.fromLTWH(20, 100, 180, 270),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsOneWidget);
  }

  testWidgets('middle horizontal swipe turns pages instead of closing', (t) async {
    final items = [_photo('p0'), _photo('p1'), _photo('p2')];
    await openViewer(t, items, index: 0);
    expect(find.text('1 / 3'), findsOneWidget);

    await t.dragFrom(const Offset(200, 400), const Offset(-260, 0));
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);

    await t.dragFrom(const Offset(200, 400), const Offset(260, 0));
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
  });

  testWidgets('left edge inward swipe closes viewer even when on middle page', (t) async {
    final items = [_photo('p0'), _photo('p1'), _photo('p2')];
    await openViewer(t, items, index: 1);
    expect(find.text('2 / 3'), findsOneWidget);

    // Quick swipe starting near the left edge moving right (inward) must dismiss, not page back.
    await t.flingFrom(const Offset(12, 400), const Offset(120, 0), 900);
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsNothing);
  });

  testWidgets('right edge inward swipe closes viewer instead of advancing page', (t) async {
    final items = [_photo('p0'), _photo('p1'), _photo('p2')];
    await openViewer(t, items, index: 1);
    expect(find.text('2 / 3'), findsOneWidget);

    await t.flingFrom(const Offset(388, 400), const Offset(-120, 0), 900);
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsNothing);
  });

  testWidgets('small edge drag below threshold springs back without closing', (t) async {
    final items = [_photo('p0'), _photo('p1')];
    await openViewer(t, items, index: 0);

    await t.dragFrom(const Offset(12, 400), const Offset(28, 0));
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsOneWidget);
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('downward drag interactively moves media and sensitive flick dismisses', (t) async {
    final items = [_photo('p0')];
    await openViewer(t, items, index: 0);

    final g = await t.startGesture(const Offset(200, 300));
    await g.moveBy(const Offset(0, 60));
    await t.pump();
    final pageRect = t.getRect(find.byKey(const ValueKey('viewerPages')));
    expect(pageRect.top, greaterThan(40));
    await g.moveBy(const Offset(0, 50));
    await g.up();
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsNothing);
  });

  testWidgets('fast short downward flick closes viewer sensitively', (t) async {
    final items = [_photo('p0')];
    await openViewer(t, items, index: 0);

    await t.flingFrom(const Offset(200, 350), const Offset(0, 32), 700);
    await t.pumpAndSettle();
    expect(find.byType(ViewerPage), findsNothing);
  });

  group('video viewer with gestures disabled (playerGesturesOff)', () {
    setUp(() => Prefs.instance.playerGesturesOff = true);
    tearDown(() => Prefs.instance.playerGesturesOff = false);

    testWidgets('middle horizontal swipe turns page from video to next item', (t) async {
      final items = [_video('v0'), _photo('p1')];
      await openViewer(t, items, index: 0);

      await t.dragFrom(const Offset(200, 400), const Offset(-260, 0));
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('left edge and right edge inward swipes close video viewer', (t) async {
      await openViewer(t, [_video('v1'), _photo('p1')], index: 0);
      await t.flingFrom(const Offset(12, 400), const Offset(120, 0), 900);
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsNothing);

      await openViewer(t, [_photo('p0'), _video('v2')], index: 1);
      await t.flingFrom(const Offset(388, 400), const Offset(-120, 0), 900);
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsNothing);
    });

    testWidgets('downward swipe closes video viewer when gestures are off', (t) async {
      await openViewer(t, [_video('v3')], index: 0);
      await t.flingFrom(const Offset(200, 350), const Offset(0, 40), 700);
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsNothing);
    });
  });

  group('video viewer with gestures enabled', () {
    setUp(() => Prefs.instance.playerGesturesOff = false);

    testWidgets('edge swipe inward still closes video viewer while downward middle drag stays for volume/brightness', (t) async {
      await openViewer(t, [_video('v4')], index: 0);
      await t.dragFrom(const Offset(200, 350), const Offset(0, 120));
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsOneWidget);

      await t.flingFrom(const Offset(12, 400), const Offset(120, 0), 900);
      await t.pumpAndSettle();
      expect(find.byType(ViewerPage), findsNothing);
    });
  });
}
