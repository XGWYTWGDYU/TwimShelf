import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/screens/viewer_page.dart';

const _count = 60;

FeedItem _item(int i) => FeedItem.fromJson({
      'media_id': 'm$i',
      'post_id': 'p$i',
      'ordinal': 0,
      'kind': 'photo',
      'path': '/synthetic/m$i',
      'text': 'caption $i',
      'tags': const <Object>[],
    });

/// Scrolls back and forth through the viewer, as fast as a scroll can be told from the next, and
/// after every scroll checks the page: the counter and the caption of the item the list has there.
void main() {
  late WidgetTester t;
  late int at;
  late Duration clock;

  Future<void> open(WidgetTester tester, int index) async {
    t = tester;
    at = index;
    clock = const Duration(seconds: 10);
    await tester.pumpWidget(MaterialApp(
      home: ViewerPage(library: LibraryModel.forTest('/no/such/folder'), items: [for (var i = 0; i < _count; i++) _item(i)], index: index),
    ));
    await tester.pump();
  }

  Future<void> scroll(int by, Duration gap) async {
    clock += gap;
    await t.sendEventToBinding(PointerScrollEvent(position: const Offset(400, 300), scrollDelta: Offset(0, by * 120.0), timeStamp: clock));
    at = (at + by).clamp(0, _count - 1);
    await t.pump(gap);
  }

  Future<void> check(String what) async {
    await t.pump(const Duration(milliseconds: 400));
    expect(t.widget<Text>(find.byKey(const ValueKey('photoCounter'))).data, '${at + 1} / $_count', reason: what);
    expect(find.textContaining('caption $at'), findsWidgets, reason: what);
  }

  for (final ms in [400, 200, 130]) {
    testWidgets('every $ms ms: 30 forward and 30 back land on each picture in the list order', (tester) async {
      await open(tester, 0);
      final gap = Duration(milliseconds: ms);
      for (var round = 0; round < 3; round++) {
        for (final dir in [1, -1]) {
          for (var i = 0; i < 30; i++) {
            await scroll(dir, gap);
            if (ms >= 300) await check('round $round dir $dir step $i');
          }
          await check('round $round dir $dir, at the end');
        }
      }
      expect(at, 0);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets('random directions and speeds, and both ends of the list', (tester) async {
    await open(tester, 0);
    final random = Random(2026);
    for (var i = 0; i < 300; i++) {
      await scroll(random.nextBool() ? 1 : -1, Duration(milliseconds: 130 + random.nextInt(300)));
      if (i % 10 == 0) await check('random step $i');
    }
    await check('random, at the end');
    for (var i = 0; i < 70; i++) {
      await scroll(1, const Duration(milliseconds: 150));
    }
    await check('past the last');
    expect(at, _count - 1);
    for (var i = 0; i < 70; i++) {
      await scroll(-1, const Duration(milliseconds: 150));
    }
    await check('past the first');
    expect(at, 0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
