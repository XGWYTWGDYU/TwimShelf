import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/feed_order.dart';

FeedItem _item(String post, int ordinal) => FeedItem.fromJson({
      'media_id': '$post-$ordinal',
      'post_id': post,
      'ordinal': ordinal,
      'kind': 'photo',
      'path': '/synthetic/$post-$ordinal.jpg',
      'tags': const <Object>[],
    });

void main() {
  final items = [for (var p = 0; p < 200; p++) _item('p$p', 0)];

  test('the order stays through a reload and a deletion; a reshuffle changes it', () {
    final order = FeedOrder();
    final first = order.apply(items).map((i) => i.media_id).toList();
    expect(first, isNot(items.map((i) => i.media_id).toList()));
    expect(order.apply(items).map((i) => i.media_id).toList(), first);
    final without = items.where((i) => i.media_id != first[7]).toList();
    expect(order.apply(without).map((i) => i.media_id).toList(), [...first]..removeAt(7));
    order.reshuffle();
    expect(order.apply(items).map((i) => i.media_id).toList(), isNot(first));
  });

  test('a post has one rank, however many media it has; its media stay in their order', () {
    var next = 0;
    final draws = <int>[];
    final order = FeedOrder(draw: () {
      draws.add(next);
      return next++;
    });
    final posts = order.posts([_item('a', 2), _item('b', 0), _item('a', 0), _item('a', 1)]);
    expect(draws.length, 2);
    expect(posts.map((p) => p.first.post_id), ['a', 'b']);
    expect(posts.first.map((i) => i.ordinal), [0, 1, 2]);
  });

  test('by date: posts where the core put them', () {
    final posts = FeedOrder.postsInPlace([_item('new', 1), _item('old', 0), _item('new', 0)]);
    expect(posts.map((p) => p.first.post_id), ['new', 'old']);
    expect(posts.first.map((i) => i.ordinal), [0, 1]);
  });
}
