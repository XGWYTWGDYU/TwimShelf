import 'package:flutter_test/flutter_test.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/screens/settings/tags_page.dart';

void main() {
  TagCount t(String label, int count, int user, int ai) => TagCount(label: label, count: count, user: user, ai: ai);
  final tags = [t('cat', 5, 1, 5), t('sea', 3, 3, 0), t('dog', 5, 4, 2), t('art', 1, 0, 1)];
  List<String> order(int o) => sortedTags(tags, o).map((x) => x.label).toList();

  test('the tag list orders as the native apps: media, mine, AI, name', () {
    expect(order(0), ['cat', 'dog', 'sea', 'art'], reason: 'ties by name');
    expect(order(1), ['dog', 'sea', 'cat', 'art']);
    expect(order(2), ['cat', 'dog', 'art', 'sea']);
    expect(order(3), ['art', 'cat', 'dog', 'sea']);
  });
}
