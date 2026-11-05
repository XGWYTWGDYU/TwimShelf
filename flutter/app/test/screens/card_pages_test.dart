import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/screens/browse_page.dart';

FeedItem _item(int w, int h) => FeedItem(media_id: '$w$h', post_id: 'p', ordinal: 0, kind: MediaKind.photo, path: '/x', width: w, height: h);

void main() {
  final media = [_item(800, 800), _item(1000, 500), _item(500, 900)];
  double heightAt(double page, double width) => width / cardAspectAt(media, page);

  test('a card is as tall as the page it shows, at any width', () {
    for (final width in [320.0, 1200.0]) {
      expect(heightAt(0, width), closeTo(width, .01));
      expect(heightAt(1, width), closeTo(width / 2, .01));
      expect(heightAt(2, width), closeTo(width * 1.8, .01));
    }
  });

  test('between two pages its height moves evenly', () {
    expect(heightAt(0.5, 400), closeTo((400 + 200) / 2, .01));
    expect(heightAt(1.25, 400), closeTo(200 + (720 - 200) / 4, .01));
    // a pull past the ends stays at the end's height
    expect(heightAt(-0.3, 400), closeTo(400, .01));
    expect(heightAt(2.4, 400), closeTo(720, .01));
  });

  testWidgets('in columns, the cards under it follow while it moves', (t) async {
    final page = ValueNotifier(0.0);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: SizedBox(width: 100, child: Column(mainAxisSize: MainAxisSize.min, children: [
      ValueListenableBuilder(valueListenable: page, builder: (_, p, _) => AspectRatio(key: const ValueKey('card'), aspectRatio: cardAspectAt(media, p))),
      const SizedBox(key: ValueKey('under'), height: 10),
    ]))))));
    final top = t.getTopLeft(find.byKey(const ValueKey('under'))).dy;
    page.value = 1;
    await t.pump();
    expect(t.getTopLeft(find.byKey(const ValueKey('under'))).dy, lessThan(top));
  });
}
