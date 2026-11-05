import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/app/feed_order.dart';
import 'package:twimshelf/screens/browse_page.dart';

FeedItem _item(String post, int ordinal, {String kind = 'photo'}) => FeedItem.fromJson({
      'media_id': '$post-$ordinal',
      'post_id': post,
      'ordinal': ordinal,
      'kind': kind,
      'path': '/synthetic/$post-$ordinal',
      'tags': const <Object>[],
    });

void main() {
  test('alpha, beta with two media each: from alpha\'s first the next is alpha\'s second, then beta\'s', () {
    final cards = [
      [_item('alpha', 0), _item('alpha', 1)],
      [_item('beta', 0, kind: 'video'), _item('beta', 1)],
    ];
    final (items, index) = viewerList(cards, cards[0][0]);
    expect(index, 0);
    expect(items.map((i) => i.media_id), ['alpha-0', 'alpha-1', 'beta-0', 'beta-1']);
    expect(viewerList(cards, cards[1][0]).$2, 2);
  });

  test('in a random order, however the order drew, the viewer follows the cards exactly', () {
    final media = [
      for (var p = 0; p < 40; p++)
        for (var m = 0; m < 1 + p % 4; m++) _item('p$p', m, kind: m % 3 == 1 ? 'video' : 'photo'),
    ];
    final cards = FeedOrder().posts(FeedOrder().apply(media));
    final (items, _) = viewerList(cards, media.first);
    // each post's media stay together and in their order
    var at = 0;
    for (final card in cards) {
      for (var i = 0; i < card.length; i++) {
        expect(items[at + i].post_id, card.first.post_id);
        expect(items[at + i].ordinal, i);
      }
      at += card.length;
    }
    expect(items.length, media.length);
    for (final m in media) {
      expect(items[viewerList(cards, m).$2].media_id, m.media_id);
    }
  });

  test('a media no longer on a card opens the list at its start rather than failing', () {
    expect(viewerList([[_item('a', 0)]], _item('gone', 0)).$2, 0);
  });
}
