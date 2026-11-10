import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/library.dart';
import 'package:twimshelf/actions/media_actions.dart';

class _Library extends Fake implements LibraryModel {}

void main() {
  testWidgets('media menu uses the nested navigator coordinates beside a sidebar', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final item = FeedItem(media_id: 'm', post_id: 'p', ordinal: 0,
        kind: MediaKind.photo, path: '/unused', width: 100, height: 100);
    await t.pumpWidget(MaterialApp(home: Row(children: [
      const SizedBox(width: 280),
      Expanded(child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
        builder: (context) => Scaffold(body: Align(alignment: Alignment.topLeft,
          child: GestureDetector(key: const Key('media'), behavior: HitTestBehavior.opaque, onLongPressStart: (d) {
            showMediaMenu(context, library: _Library(), item: item, position: d.globalPosition);
          }, child: const SizedBox(width: 160, height: 160)),
        )),
      ))),
    ])));
    await t.longPress(find.byKey(const Key('media')));
    await t.pumpAndSettle();
    final row = t.getRect(find.byKey(const ValueKey('menu-reveal')));
    final media = t.getRect(find.byKey(const Key('media')));
    expect((row.left - media.center.dx).abs(), lessThan(24));
    expect((row.top - media.center.dy).abs(), lessThan(24));
  });
}
