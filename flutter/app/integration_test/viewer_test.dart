import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/app/prefs.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/screens/viewer_page.dart';

/// The viewer as the native one, on a synthetic library with the seed's video: photo, video,
/// photo — each function, and swiping back and forth between photos and the video.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late LibraryModel library;
  late List<FeedItem> items;

  Future<void> until(WidgetTester t, bool Function() ok, {int tries = 80}) async {
    for (var i = 0; i < tries && !ok(); i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 24; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  setUpAll(() async {
    await L10n.load();
    await Prefs.load();
    library = await LibraryModel.open();
    final all = await library.feed(FeedRequest());
    final video = all.firstWhere((i) => i.kind == MediaKind.video);
    final photos = all.where((i) => i.kind == MediaKind.photo).take(2).toList();
    items = [photos[0], video, photos[1]];
  });

  /// A swipe past the middle of the page (turns it whatever the speed, as a finger does).
  Future<void> swipe(WidgetTester t, int direction) async {
    final w = t.getSize(find.byKey(const ValueKey('viewerPages'))).width;
    await t.drag(find.byKey(const ValueKey('viewerPages')), Offset(-direction * w * 0.7, 0));
  }

  Future<void> open(WidgetTester t, int index) async {
    await t.pumpWidget(MaterialApp(home: Builder(
      builder: (c) => Scaffold(
        body: Center(
          child: FilledButton(
            key: const ValueKey('openViewer'),
            onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => ViewerPage(library: library, items: items, index: index))),
            child: const Text('open'),
          ),
        ),
      ),
    )));
    await t.tap(find.byKey(const ValueKey('openViewer')));
    await settle(t);
  }

  testWidgets('photo: counter, double-tap zoom, swipe to the video and back, many times', (t) async {
    Prefs.instance.playerGesturesOff = true; // sideways swipes turn the page on the video too
    await open(t, 0);
    expect(find.text('1 / 3'), findsOneWidget);
    // double tap zooms; while zoomed the page does not turn
    final c = t.getCenter(find.byKey(const ValueKey('viewerPages')));
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(c);
    await settle(t);
    await t.fling(find.byKey(const ValueKey('viewerPages')), const Offset(-500, 0), 1500);
    await settle(t);
    expect(find.text('1 / 3'), findsOneWidget, reason: 'zoomed: no page turn');
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(c);
    await settle(t);
    // back and forth: photo → video → photo → video → photo, five rounds
    for (var round = 0; round < 5; round++) {
      await swipe(t, 1);
      await settle(t);
      await until(t, () => find.byKey(const ValueKey('videoPlay')).evaluate().isNotEmpty);
      expect(find.byKey(const ValueKey('videoPlay')), findsOneWidget, reason: 'round $round: on the video');
      await swipe(t, 1);
      await settle(t);
      expect(find.text('3 / 3'), findsOneWidget, reason: 'round $round: last photo');
      await swipe(t, -1);
      await settle(t);
      await swipe(t, -1);
      await settle(t);
      expect(find.text('1 / 3'), findsOneWidget, reason: 'round $round: back on the first photo');
    }
    // the bar's close
    await t.tap(find.byKey(const ValueKey('viewerClose')));
    await settle(t);
    expect(find.byKey(const ValueKey('viewerPages')), findsNothing);
  });

  testWidgets('video: play/pause, lock, arrows when the drags are on, keys', (t) async {
    Prefs.instance.playerGesturesOff = false;
    await open(t, 1);
    await until(t, () => find.byTooltip(L('viewer.pause')).evaluate().isNotEmpty);
    expect(find.byTooltip(L('viewer.pause')), findsOneWidget, reason: 'plays when it is the page');
    // play / pause from the bar and from Space
    await t.tap(find.byKey(const ValueKey('videoPlay')));
    await until(t, () => find.byTooltip(L('viewer.play')).evaluate().isNotEmpty);
    expect(find.byTooltip(L('viewer.play')), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await until(t, () => find.byTooltip(L('viewer.pause')).evaluate().isNotEmpty);
    expect(find.byTooltip(L('viewer.pause')), findsOneWidget, reason: 'Space plays');
    // with the drags on, a sideways swipe stays on the video; the arrows turn the page
    await t.fling(find.byKey(const ValueKey('viewerPages')), const Offset(-500, 0), 1500);
    await settle(t);
    expect(find.byKey(const ValueKey('videoPlay')), findsWidgets, reason: 'still the video');
    // lock: the bar goes, only the lock stays; unlock brings it back
    await t.tap(find.byKey(const ValueKey('videoPlay')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('videoLock')));
    await settle(t);
    // locked: the bar takes no touches (it fades out), only the lock is there
    expect(find.byKey(const ValueKey('videoPlay')).hitTestable(), findsNothing);
    expect(find.byKey(const ValueKey('videoUnlock')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('videoUnlock')));
    await settle(t);
    expect(find.byKey(const ValueKey('videoPlay')), findsOneWidget);
    // the arrow to the next photo, and ← back to the video
    await t.tap(find.byKey(const ValueKey('videoNext')));
    await settle(t);
    expect(find.text('3 / 3'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await settle(t);
    await until(t, () => find.byKey(const ValueKey('videoPlay')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('videoPlay')), findsOneWidget);
    // the player's own close; and Esc closes too
    await t.tap(find.byKey(const ValueKey('videoClose')));
    await settle(t);
    expect(find.byKey(const ValueKey('viewerPages')), findsNothing);
    await open(t, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t);
    expect(find.byKey(const ValueKey('viewerPages')), findsNothing);
  });
}
