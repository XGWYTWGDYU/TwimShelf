import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import 'query.dart';

enum SuggestionKind { keyword, term, tag, folder, history, clearHistory, empty }

enum SuggestionTint { accent, folder, secondary, exclude }

class SearchSuggestion {
  const SearchSuggestion({
    required this.id,
    required this.kind,
    required this.label,
    this.detail,
    this.key,
    this.symbol,
    this.tint = SuggestionTint.accent,
    this.destructive = false,
    this.folderName,
    this.excluded = false,
  });
  final String id, label;
  final SuggestionKind kind;
  final String? detail, key, symbol, folderName;
  final SuggestionTint tint;
  final bool destructive, excluded;
}

class SearchSuggestionSection {
  SearchSuggestionSection(this.titleKey, List<SearchSuggestion> rows)
    : rows = List.unmodifiable(rows);
  final String titleKey;
  String get title => L(titleKey);
  final List<SearchSuggestion> rows;
}

typedef SearchFolder = ({String name, int count});

List<SearchSuggestionSection> suggestionSections(
  String raw,
  List<String> keys,
  List<TagCount> tags,
  List<SearchFolder> folders, {
  List<String> history = const [],
}) {
  final typed = raw.trim();
  final present = keys.toSet();
  final terms = keys
      .where((s) => s.startsWith('t:'))
      .map((s) => s.substring(2).toLowerCase())
      .toSet();
  final lone = TokenQuery.minusSigns.contains(typed);
  final negative = lone || TokenQuery.negated(typed) != null;
  final q = (lone ? '' : TokenQuery.negated(typed) ?? typed).toLowerCase();
  List<TagCount> matchingTags(bool excluding) {
    final list = tags
        .where(
          (t) =>
              t.label.toLowerCase().contains(q) &&
              (excluding ? t.label != q : !terms.contains(t.label)),
        )
        .toList();
    list.sort((a, b) => b.count.compareTo(a.count));
    return list.take(excluding ? 6 : 8).toList();
  }

  SearchSuggestion folderRow(
    SearchFolder f, {
    required bool excluding,
    bool picking = false,
  }) => SearchSuggestion(
    id: '${excluding && !picking ? 'folder-minus-' : 'folder-'}${f.name}',
    kind: SuggestionKind.folder,
    label: f.name,
    detail: L(
      picking || excluding ? 'search.row.mediaCount' : 'search.row.onlyFolder',
      [f.count],
    ),
    symbol: excluding ? 'minus.circle' : 'folder',
    tint: excluding ? SuggestionTint.exclude : SuggestionTint.folder,
    key: '${excluding ? '-' : ''}${TokenQuery.folderKey(f.name)}',
    folderName: f.name,
    excluded: excluding,
  );
  if (keys.isNotEmpty &&
      [
        TokenQuery.pendingFolder,
        '-${TokenQuery.pendingFolder}',
      ].contains(keys.last)) {
    final excluding = keys.last != TokenQuery.pendingFolder;
    final shown = folders
        .where((f) => q.isEmpty || f.name.toLowerCase().contains(q))
        .toList();
    return [
      SearchSuggestionSection(
        excluding
            ? 'search.section.pickExcludedFolder'
            : 'search.section.pickFolder',
        shown.isEmpty
            ? [
                SearchSuggestion(
                  id: 'noFolder',
                  kind: SuggestionKind.empty,
                  label: L(
                    folders.isEmpty
                        ? 'search.noFolders'
                        : 'search.noMatchingFolders',
                  ),
                  symbol: 'folder',
                ),
              ]
            : shown
                  .map((f) => folderRow(f, excluding: excluding, picking: true))
                  .toList(),
      ),
    ];
  }
  final out = <SearchSuggestionSection>[];
  final keywords = SearchKeyword.values
      .where(
        (kw) =>
            (!negative || kw.excludable) &&
            !present.contains('${negative ? '-' : ''}${kw.key}') &&
            kw.matchesPrefix(q),
      )
      .toList();
  if (keywords.isNotEmpty) {
    out.add(
      SearchSuggestionSection(
        negative ? 'search.section.exclude' : 'search.section.conditions',
        keywords
            .map(
              (kw) => SearchSuggestion(
                id: 'kw-${negative ? 'minus-' : ''}${kw.id}',
                kind: SuggestionKind.keyword,
                label: negative ? '−${kw.word}' : kw.word,
                detail: negative ? kw.excludeHint : kw.hint,
                key: '${negative ? '-' : ''}${kw.key}',
                symbol: negative ? 'minus.circle' : kw.symbol,
                tint: negative ? SuggestionTint.exclude : SuggestionTint.accent,
                excluded: negative,
              ),
            )
            .toList(),
      ),
    );
  }
  if (negative) {
    if (q.isNotEmpty) {
      out.add(
        SearchSuggestionSection('search.section.content', [
          SearchSuggestion(
            id: 'term-minus',
            kind: SuggestionKind.term,
            label: L('search.row.exclude', [q]),
            symbol: 'minus.circle',
            tint: SuggestionTint.exclude,
            key: '-${TokenQuery.termKey(q)}',
            excluded: true,
          ),
          ...matchingTags(true).map(
            (t) => SearchSuggestion(
              id: 'tag-minus-${t.label}',
              kind: SuggestionKind.tag,
              label: L('search.row.excludeTag', [t.label]),
              detail: L('search.row.mediaCount', [t.count]),
              symbol: 'tag',
              tint: SuggestionTint.exclude,
              key: '-${TokenQuery.termKey(t.label.toLowerCase())}',
              excluded: true,
            ),
          ),
        ]),
      );
      final shown = folders
          .where(
            (f) =>
                f.name.toLowerCase().contains(q) &&
                !present.contains('-${TokenQuery.folderKey(f.name)}'),
          )
          .toList();
      if (shown.isNotEmpty) {
        out.add(
          SearchSuggestionSection(
            'search.section.folders',
            shown.map((f) => folderRow(f, excluding: true)).toList(),
          ),
        );
      }
    }
    return List.unmodifiable(out);
  }
  if (typed.isNotEmpty) {
    out.add(
      SearchSuggestionSection('search.section.content', [
        SearchSuggestion(
          id: 'term',
          kind: SuggestionKind.term,
          label: L('search.row.searchFor', [typed]),
          symbol: 'magnifyingglass',
          key: TokenQuery.termKey(q),
        ),
        ...matchingTags(false).map(
          (t) => SearchSuggestion(
            id: 'tag-${t.label}',
            kind: SuggestionKind.tag,
            label: t.label,
            detail: L('search.row.mediaCount', [t.count]),
            symbol: 'tag',
            key: TokenQuery.termKey(t.label.toLowerCase()),
          ),
        ),
      ]),
    );
    final shown = folders
        .where((f) => f.name.toLowerCase().contains(q))
        .toList();
    if (shown.isNotEmpty) {
      out.add(
        SearchSuggestionSection(
          'search.section.folders',
          shown.map((f) => folderRow(f, excluding: false)).toList(),
        ),
      );
    }
  } else {
    final recent = history.where((t) => !terms.contains(t)).take(6).toList();
    if (recent.isNotEmpty) {
      out.add(
        SearchSuggestionSection('search.section.recent', [
          ...recent.map(
            (t) => SearchSuggestion(
              id: 'recent-$t',
              kind: SuggestionKind.history,
              label: t,
              symbol: 'clock.arrow.circlepath',
              tint: SuggestionTint.secondary,
              key: TokenQuery.termKey(t),
            ),
          ),
          SearchSuggestion(
            id: 'clearHistory',
            kind: SuggestionKind.clearHistory,
            label: L('search.clearHistory'),
            destructive: true,
          ),
        ]),
      );
    }
  }
  return List.unmodifiable(out);
}
