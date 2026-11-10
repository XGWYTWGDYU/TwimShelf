import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';
import 'package:twimshelf/l10n/l10n.dart';
import 'package:twimshelf/search/query.dart';
import 'package:twimshelf/search/marks.dart';
import 'package:twimshelf/search/history.dart';
import 'package:twimshelf/search/suggestions.dart';

Map<String, Object?> expected(
  List<String> terms, {
  bool tags = true,
  bool text = true,
  bool author = true,
  List<String> exclude = const [],
  List<int>? origins,
  String scope = 'both',
  Map<String, Object?> filter = const {},
}) => {
  'terms': terms,
  'scope': scope,
  'seed': null,
  'newest_first': false,
  'fuzzy': false,
  'term_vectors': <Object>[],
  'embed_model': null,
  'threshold': .55,
  'fields': {'tags': tags, 'text': text, 'author': author},
  'filter': {
    'author': null,
    'labels': <String>[],
    'review': 'any',
    'bad_only': false,
    'folder': null,
    'loose_only': false,
    'album_only': false,
    'recent_only': false,
    'kind': null,
    'exclude_terms': exclude,
    'origins': origins,
    'exclude_folders': <String>[],
    'exclude_recent': false,
    'exclude_loose': false,
    ...filter,
  },
  'whole_posts': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await L10n.load(locale: const Locale('zh', 'CN'));
  });
  final cases = <String, Map<String, Object?>>{
    '用户 al': expected(['al'], tags: false, text: false),
    '猫': expected(['猫']),
    'cat': expected(['cat']),
    '墙 -猫': expected(['墙'], exclude: ['猫']),
    '-al': expected([], exclude: ['al']),
    '墙 -用户': expected(['墙'], author: false),
    'al -用户': expected(['al'], author: false),
    '墙 -AI': expected(['墙'], origins: [1]),
    '标签 墙 -我的': expected(['墙'], text: false, author: false, origins: [2]),
    '贴文 猫': expected(['猫'], tags: false, author: false),
    '标签 猫': expected(['猫'], text: false, author: false),
    '我的 猫': expected(['猫'], text: false, author: false, scope: 'mine'),
    'AI 猫': expected(['猫'], text: false, author: false, scope: 'ai'),
    '猫 -贴文': expected(['猫'], text: false),
    '-共同': expected([], origins: [1, 2]),
    '-全部': expected([], exclude: ['全部']),
  };
  for (final entry in cases.entries) {
    test('Swift request: ${entry.key}', () {
      final query = TokenQuery.parse(entry.key);
      expect(query.request().toJson(), entry.value);
      expect(query.isContradictory, isFalse);
    });
  }
  test('contradictions must bypass the core exactly as native UI does', () {
    for (final input in [
      '视频 -视频',
      '照片 -照片',
      '最近 -最近',
      '外部导入 -外部导入',
      '文件夹 旅行 -文件夹 旅行',
      '猫 -标签 -贴文 -用户',
    ]) {
      expect(TokenQuery.parse(input).isContradictory, isTrue, reason: input);
    }
    expect(TokenQuery.parse('视频 照片 -视频').kind, MediaKind.photo);
    expect(TokenQuery.parse('AI -AI 猫').origins, isEmpty);
    expect(TokenQuery.parse('AI -AI 猫').isContradictory, isFalse);
    expect(
      TokenQuery.parse('-猫 -标签 -贴文 -用户').request().filter.exclude_terms,
      isEmpty,
    );
  });
  test('all minus characters and a lone minus', () {
    for (final minus in ['-', '－', '−', '–']) {
      expect(TokenQuery.parse('$minus猫 $minus用户').keys, ['-t:猫', '-f:author']);
      expect(TokenQuery.parse(minus).keys, ['t:$minus']);
    }
  });
  test(
    'split keeps unfinished word and folder capsules consume the next word',
    () {
      final split = TokenQuery.split('用户\u3000al');
      expect(split.keys, ['f:author']);
      expect(split.rest, 'al');
      expect(TokenQuery.parse('-文件夹 −旅行 文件夹 -literal').keys, [
        '-d:旅行',
        'd:-literal',
      ]);
      expect(TokenQuery.split('文件夹 ').keys, ['p:folder']);
      expect(TokenQuery.parse('CAT cat Cat').terms, ['cat']);
      expect(TokenQuery.parse('文件夹 一 文件夹 二').folder, '二');
    },
  );
  test('scope precedence and filter overlay preserve unrelated page chips', () {
    final query = TokenQuery.parse('我的 AI 共同 猫 -共同 -文件夹 旅行 -最近 -外部导入');
    expect(query.scope, SearchScope.common);
    expect(query.origins, isEmpty);
    final base = FeedFilter(
      author: 'alice',
      labels: ['mine'],
      bad_only: true,
      kind: MediaKind.video,
    );
    final filter = query.filter(over: base);
    expect(filter.author, 'alice');
    expect(filter.labels, ['mine']);
    expect(filter.bad_only, isTrue);
    expect(filter.kind, MediaKind.video);
    expect(filter.exclude_folders, ['旅行']);
    expect(filter.exclude_recent, isTrue);
    expect(filter.exclude_loose, isTrue);
    expect(base.exclude_folders, isEmpty);
  });
  test(
    'keywords recognize only the current language; stable keys translate',
    () async {
      expect(TokenQuery.parse('photo').terms, ['photo']);
      expect(TokenQuery.title('-f:author'), L('search.kw.author.word'));
      expect(TokenQuery.spoken('-t:猫'), L('search.token.excluded', ['猫']));
      await L10n.load(locale: const Locale('en'));
      expect(TokenQuery.parse('User AL').keys, ['f:author', 't:AL']);
      expect(TokenQuery.parse('用户').terms, ['用户']);
      expect(TokenQuery.parse('Photo').kind, MediaKind.photo);
    },
  );
  test(
    'marks select only searched fields (including native empty-field fallback)',
    () {
      final author = TokenQuery.parse('用户 al').marks;
      expect(author.author, ['al']);
      expect(author.text, isEmpty);
      expect(author.tags, isEmpty);
      final text = TokenQuery.parse('贴文 猫').marks;
      expect(text.text, ['猫']);
      expect(text.author, isEmpty);
      expect(text.tags, isEmpty);
      expect(TokenQuery.parse('猫 -用户').marks.author, isEmpty);
      expect(
        SearchMarks(
          terms: ['x'],
          fields: SearchFields(tags: false, text: false, author: false),
        ).tags,
        ['x'],
      );
    },
  );
  test('highlight UTF16 offsets, Unicode folding and overlapping unions', () {
    expect(highlightRanges(['ab', 'bc'], 'ABC'), [const HighlightRange(0, 3)]);
    expect(highlightRanges(['abc cafe'], 'ＡＢＣ café'), [
      const HighlightRange(0, 8),
    ]);
    expect(highlightRanges(['strasse'], 'Straße'), [
      const HighlightRange(0, 6),
    ]);
    expect(highlightRanges(['fi'], '① ² ﬁ'), [const HighlightRange(4, 5)]);
    expect(highlightRanges(['1'], '①'), [const HighlightRange(0, 1)]);
    expect(highlightRanges(['e'], '😀e\u0301'), [const HighlightRange(2, 4)]);
    expect(highlightRanges(['ガ'], 'ｶﾞ カ ガ'), [const HighlightRange(5, 6)]);
    expect(highlightRanges(['カ'], 'ガ'), isEmpty);
    expect(highlightRanges(['カ'], 'ｶﾞ'), [const HighlightRange(0, 1)]);
    expect(highlightRanges(['ana'], 'banana'), [const HighlightRange(1, 4)]);
  });
  test(
    'negative and pending-folder suggestions preserve native groups/order',
    () {
      final sections = suggestionSections('-', [], [], []);
      expect(sections.map((s) => s.titleKey), ['search.section.exclude']);
      expect(sections.single.rows.any((r) => r.key == '-s:both'), isFalse);
      final pending = suggestionSections(
        '旅',
        ['-p:folder'],
        [],
        [(name: '旅行', count: 3)],
      );
      expect(pending.single.titleKey, 'search.section.pickExcludedFolder');
      expect(pending.single.rows.single.key, '-d:旅行');
      expect(pending.single.rows.single.excluded, isTrue);
      final tags = [
        TagCount(label: '猫咪', count: 2, user: 2, ai: 0),
        TagCount(label: '小猫', count: 8, user: 0, ai: 8),
      ];
      final result = suggestionSections('-猫', [], tags, [
        (name: '猫相册', count: 4),
      ]);
      expect(result.map((s) => s.titleKey), [
        'search.section.content',
        'search.section.folders',
      ]);
      expect(result.first.rows.map((r) => r.key), ['-t:猫', '-t:小猫', '-t:猫咪']);
    },
  );
  test('recent suggestions exclude present terms and expose clear action', () {
    final sections = suggestionSections(
      '',
      ['t:cat'],
      [],
      [],
      history: ['cat', 'dog'],
    );
    expect(sections.map((s) => s.titleKey), [
      'search.section.conditions',
      'search.section.recent',
    ]);
    expect(sections.last.rows.first.key, 't:dog');
    expect(sections.last.rows.last.kind, SuggestionKind.clearHistory);
  });
  test(
    'history persists a 12-item MRU, trims, deduplicates and clears',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final history = SearchHistory(prefs);
      await Future.wait(List.generate(15, (i) => history.add(' item$i ')));
      expect(history.items.length, 12);
      expect(history.items.first, 'item14');
      await history.add('item9');
      await history.add('   ');
      expect(SearchHistory(prefs).items.first, 'item9');
      expect(history.items.where((s) => s == 'item9').length, 1);
      await history.clear();
      expect(history.items, isEmpty);
    },
  );
}
