import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twimshelf/widgets/known_masonry.dart';

/// Heights of 2000 cards, all different.
double heightOf(int i) => 100.0 + (i * 37) % 160;

void main() {
  late Set<int> built;
  late ScrollController scroll;

  Widget grid({double Function(int)? real, double Function(int, double)? estimate, int count = 2000, Object? items}) => MaterialApp(
        home: CustomScrollView(controller: scroll, slivers: [
          SliverKnownMasonry(
            columns: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            items: items ?? const Object(),
            keyOf: (i) => i,
            estimate: estimate ?? (i, _) => heightOf(i),
            delegate: SliverChildBuilderDelegate(childCount: count, (context, i) {
              built.add(i);
              return SizedBox(key: ValueKey(i), height: (real ?? heightOf)(i));
            }),
          ),
        ]),
      );

  /// Where a masonry grid puts each card: the shortest column (the leftmost of equals).
  List<Offset> expected(double Function(int) h, int count, double width) {
    final bottoms = [0.0, 0.0];
    final stride = (width + 10) / 2;
    return [
      for (var i = 0; i < count; i++)
        () {
          final c = bottoms[1] < bottoms[0] ? 1 : 0;
          final at = Offset(c * stride, bottoms[c]);
          bottoms[c] += h(i) + 10;
          return at;
        }(),
    ];
  }

  setUp(() {
    built = {};
    scroll = ScrollController();
  });

  testWidgets('cards go to the shortest column, as a masonry grid places them', (t) async {
    await t.pumpWidget(grid());
    final want = expected(heightOf, 2000, 800);
    for (final i in [0, 1, 2, 3, 7]) {
      expect(t.getTopLeft(find.byKey(ValueKey(i))), want[i], reason: 'card $i');
    }
  });

  testWidgets('deep in the list only the cards near the screen are built', (t) async {
    await t.pumpWidget(grid());
    final want = expected(heightOf, 2000, 800);
    built.clear();
    scroll.jumpTo(want[1500].dy);
    await t.pump();
    expect(built.length, lessThan(30), reason: 'built: ${built.length}');
    expect(built.reduce((a, b) => a < b ? a : b), greaterThan(1400));
    expect(t.getTopLeft(find.byKey(const ValueKey(1500))).dy, 0);
  });

  testWidgets('scrolling builds only the cards coming into view, never again the ones shown', (t) async {
    await t.pumpWidget(grid(estimate: (i, _) => heightOf(i) - 37));
    final counts = <int, int>{};
    built = _Counting(counts);
    for (var f = 0; f < 300; f++) {
      scroll.jumpTo(scroll.offset + 40);
      await t.pump();
    }
    expect(counts.values.where((n) => n > 1), isEmpty, reason: 'built more than once: $counts');
  });

  testWidgets('a new list deep down builds only what shows, not every card above', (t) async {
    await t.pumpWidget(grid());
    scroll.jumpTo(100000);
    await t.pump();
    built.clear();
    await t.pumpWidget(grid(items: Object()));
    expect(built.length, lessThan(30), reason: 'built: ${built.length}');
  });

  testWidgets('real heights replace the estimates and the card at the top stays put', (t) async {
    // every estimate 40 too short
    await t.pumpWidget(grid(estimate: (i, _) => heightOf(i) - 40));
    final top = t.getTopLeft(find.byKey(const ValueKey(0))).dy;
    expect(t.getSize(find.byKey(const ValueKey(0))).height, heightOf(0));
    // jump far: the cards there are placed with estimates for those never laid out
    built.clear();
    scroll.jumpTo(50000);
    await t.pump();
    // a card in the middle of the screen
    final shown = (built.toList()..sort()).firstWhere((i) {
      final f = find.byKey(ValueKey(i));
      return f.evaluate().isNotEmpty && t.getTopLeft(f).dy > 150;
    });
    final before = t.getTopLeft(find.byKey(ValueKey(shown))).dy;
    // scroll up a little: cards above come in with their real heights, the shown one does not move with them
    scroll.jumpTo(scroll.offset - 300);
    await t.pump();
    expect(t.getTopLeft(find.byKey(ValueKey(shown))).dy, closeTo(before + 300, 0.5));
    expect(top, 0);
    // laid out once, the places are a masonry of the real heights
    scroll.jumpTo(0);
    await t.pump();
    final want = expected(heightOf, 2000, 800);
    for (final i in [0, 1, 2, 3]) {
      expect(t.getTopLeft(find.byKey(ValueKey(i))), want[i]);
    }
  });

  testWidgets('a card growing on screen moves the cards under it', (t) async {
    final grown = ValueNotifier(100.0);
    await t.pumpWidget(MaterialApp(
      home: CustomScrollView(controller: scroll, slivers: [
        SliverKnownMasonry(
          columns: 1,
          mainAxisSpacing: 0,
          crossAxisSpacing: 0,
          items: const Object(),
          keyOf: (i) => i,
          estimate: (i, _) => 100,
          delegate: SliverChildBuilderDelegate(childCount: 3, (context, i) => i == 0
              ? ValueListenableBuilder<double>(valueListenable: grown, builder: (_, h, _) => SizedBox(key: const ValueKey(0), height: h))
              : SizedBox(key: ValueKey(i), height: 100)),
        ),
      ]),
    ));
    expect(t.getTopLeft(find.byKey(const ValueKey(2))).dy, 200);
    grown.value = 180;
    await t.pump();
    expect(t.getTopLeft(find.byKey(const ValueKey(2))).dy, 280);
  });

  testWidgets('the end of the list is where the last card ends', (t) async {
    await t.pumpWidget(grid(count: 9));
    final want = expected(heightOf, 9, 800);
    var bottom = 0.0;
    for (var i = 0; i < 9; i++) {
      bottom = bottom > want[i].dy + heightOf(i) ? bottom : want[i].dy + heightOf(i);
    }
    expect(scroll.position.maxScrollExtent, (bottom - 600).clamp(0, double.infinity));
  });
}

/// Counts how often each card is built.
class _Counting extends SetBase<int> {
  _Counting(this.counts);
  final Map<int, int> counts;
  @override
  bool add(int value) {
    counts[value] = (counts[value] ?? 0) + 1;
    return true;
  }

  @override
  bool contains(Object? element) => counts.containsKey(element);
  @override
  Iterator<int> get iterator => counts.keys.iterator;
  @override
  int get length => counts.length;
  @override
  int? lookup(Object? element) => contains(element) ? element as int : null;
  @override
  bool remove(Object? value) => counts.remove(value) != null;
  @override
  Set<int> toSet() => counts.keys.toSet();
}
