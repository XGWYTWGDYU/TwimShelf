import 'package:tl_core/tl_core.dart';

import '../platform/system_random.dart';

/// Random feed order drawn from the system's random number generator, as the native apps'
/// `FeedOrder`. Each media (or post) gets a random rank the first time it is seen and keeps it until
/// the next reshuffle, so the order stays put while you tag, delete or sync, and media that arrive
/// later land at random positions.
class FeedOrder {
  FeedOrder({int Function()? draw}) : _draw = draw ?? const SystemRandom().nextInt64;

  final int Function() _draw;
  final _rank = <String, int>{};

  void reshuffle() => _rank.clear();

  /// Posts in the order of [items] (which the core already put in order), each post's media in their
  /// order: the feed by when things were added.
  static List<List<FeedItem>> postsInPlace(List<FeedItem> items) {
    final byPost = <String, List<FeedItem>>{};
    for (final i in items) {
      byPost.putIfAbsent(i.post_id, () => []).add(i);
    }
    for (final media in byPost.values) {
      media.sort((a, b) => a.ordinal.compareTo(b.ordinal));
    }
    return byPost.values.toList();
  }

  /// Posts, each with exactly one random rank (its own draw, never "the best of its media": that
  /// favours posts with many media near the top), each post's media in their order. Nothing about
  /// the content (text, ids, hashes, dates) enters the order.
  List<List<FeedItem>> posts(List<FeedItem> items) {
    final byPost = postsInPlace(items);
    final keyed = [for (final post in byPost) (_rank.putIfAbsent('post:${post.first.post_id}', _draw), post)];
    keyed.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final k in keyed) k.$2];
  }

  List<FeedItem> apply(List<FeedItem> items) {
    final keyed = [for (final i in items) (_rank.putIfAbsent(i.media_id, _draw), i)];
    keyed.sort((a, b) => a.$1.compareTo(b.$1));
    return [for (final k in keyed) k.$2];
  }
}
