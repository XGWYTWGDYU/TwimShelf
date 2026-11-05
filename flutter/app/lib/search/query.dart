import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import 'marks.dart';

enum SearchField { tags, text, author }

enum SearchKeyword {
  tags('tags', 'f:tags', 'tag'),
  text('text', 'f:text', 'text.quote'),
  author('author', 'f:author', 'person'),
  mine('mine', 's:mine', 'person.crop.circle'),
  ai('ai', 's:ai', 'sparkles'),
  common('common', 's:common', 'checkmark.seal'),
  all('all', 's:both', 'circle.grid.2x2'),
  video('video', 'k:video', 'video'),
  photo('photo', 'k:photo', 'photo'),
  folder('folder', 'p:folder', 'folder'),
  recent('recent', 'r:recent', 'clock.badge.checkmark'),
  external('external', 'x:external', 'square.and.arrow.down');

  const SearchKeyword(this.id, this.key, this.symbol);
  final String id, key, symbol;
  // i18n-keys: search.kw.*
  String _localized(String suffix) {
    final key = 'search.kw.$id.$suffix';
    return L(key);
  }

  String get word => _localized('word');
  List<String> get aliases =>
      _localized('aliases')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
  String get hint => _localized('hint');
  String get excludeHint => _localized('exclude');
  bool get excludable => this != all;
  bool matchesPrefix(String q) =>
      [word, ...aliases].any((s) => s.toLowerCase().startsWith(q));
  static SearchKeyword? from(String value) {
    final q = value.trim().toLowerCase();
    if (q.isEmpty) return null;
    for (final keyword in values) {
      if ([keyword.word, ...keyword.aliases].any((s) => s.toLowerCase() == q)) {
        return keyword;
      }
    }
    return null;
  }
}

/// Encoded capsules are stable across locale changes. Recognition of newly typed
/// condition words uses only the CURRENT catalog, as in SearchQuery.swift.
class TokenQuery {
  TokenQuery({List<String> keys = const []}) : keys = List.unmodifiable(keys) {
    for (var key in keys) {
      final excluded = isExcluded(key);
      if (excluded) key = key.substring(1);
      if (key.startsWith('f:')) {
        for (final f in SearchField.values) {
          if (key == 'f:${f.name}') {
            (excluded ? _excludedFields : _fields).add(f);
          }
        }
      } else if (key.startsWith('s:')) {
        for (final s in SearchScope.values) {
          if (key == 's:${s.wireValue}' &&
              (!excluded || s != SearchScope.both)) {
            (excluded ? _excludedScopes : _scopes).add(s);
          }
        }
      } else if (key.startsWith('t:')) {
        final term = key.substring(2).toLowerCase();
        final target = excluded ? _excludedTerms : _terms;
        if ((!excluded || term.isNotEmpty) && !target.contains(term)) {
          target.add(term);
        }
      } else if (key.startsWith('d:')) {
        final name = key.substring(2);
        if (excluded) {
          if (!_excludedFolders.contains(name)) _excludedFolders.add(name);
        } else {
          _folder = name;
        }
      } else if (key == 'r:recent') {
        if (excluded) {
          _excludeRecent = true;
        } else {
          _recent = true;
        }
      } else if (key == 'x:external') {
        if (excluded) {
          _excludeExternal = true;
        } else {
          _external = true;
        }
      } else if (key.startsWith('k:')) {
        for (final kind in MediaKind.values) {
          if (key == 'k:${kind.wireValue}') {
            (excluded ? _excludedKinds : _kinds).add(kind);
          }
        }
      }
    }
  }
  factory TokenQuery.parse(String text) =>
      TokenQuery(keys: split('$text ').keys);
  final List<String> keys;
  final _fields = <SearchField>{}, _excludedFields = <SearchField>{};
  final _scopes = <SearchScope>{}, _excludedScopes = <SearchScope>{};
  final _kinds = <MediaKind>{}, _excludedKinds = <MediaKind>{};
  final _terms = <String>[],
      _excludedTerms = <String>[],
      _excludedFolders = <String>[];
  String? _folder;
  bool _recent = false,
      _external = false,
      _excludeRecent = false,
      _excludeExternal = false;
  List<String> get terms => List.unmodifiable(_terms);
  List<String> get excludedTerms => List.unmodifiable(_excludedTerms);
  String? get folder => _folder;
  Set<MediaKind> get allowedKinds =>
      (_kinds.isEmpty ? MediaKind.values.toSet() : _kinds).difference(
        _excludedKinds,
      );
  MediaKind? get kind => allowedKinds.length == 1 ? allowedKinds.single : null;
  SearchScope get scope {
    if (_scopes.contains(SearchScope.common)) return SearchScope.common;
    if (_scopes.containsAll([SearchScope.mine, SearchScope.ai])) {
      return SearchScope.both;
    }
    if (_scopes.contains(SearchScope.mine)) return SearchScope.mine;
    if (_scopes.contains(SearchScope.ai)) return SearchScope.ai;
    return SearchScope.both;
  }

  SearchFields get searchFields {
    final tagsOnly = _scopes.difference({SearchScope.both}).isNotEmpty;
    return SearchFields(
      tags:
          (_fields.isEmpty || _fields.contains(SearchField.tags)) &&
          !_excludedFields.contains(SearchField.tags),
      text:
          (_fields.isEmpty ? !tagsOnly : _fields.contains(SearchField.text)) &&
          !_excludedFields.contains(SearchField.text),
      author:
          (_fields.isEmpty
              ? !tagsOnly
              : _fields.contains(SearchField.author)) &&
          !_excludedFields.contains(SearchField.author),
    );
  }

  List<int>? get origins {
    if (_excludedScopes.isEmpty) return null;
    final mask = switch (scope) {
      SearchScope.common => 4,
      SearchScope.mine => 1,
      SearchScope.ai => 2,
      SearchScope.both => 3,
    };
    return [1, 2, 3]
        .where(
          (o) =>
              (mask == 4 ? o == 3 : o & mask & 3 != 0) &&
              !(_excludedScopes.contains(SearchScope.mine) && o & 1 != 0) &&
              !(_excludedScopes.contains(SearchScope.ai) && o & 2 != 0) &&
              !(_excludedScopes.contains(SearchScope.common) && o == 3),
        )
        .toList();
  }

  bool get isContradictory {
    final f = searchFields;
    return allowedKinds.isEmpty ||
        (_recent && _excludeRecent) ||
        (_external && _excludeExternal) ||
        (_folder != null && _excludedFolders.contains(_folder)) ||
        (_terms.isNotEmpty && !f.tags && !f.text && !f.author);
  }

  FeedFilter filter({FeedFilter? over}) {
    final json = (over ?? FeedFilter()).toJson();
    if (_folder != null) json['folder'] = _folder;
    if (_recent) json['recent_only'] = true;
    if (_external) json['loose_only'] = true;
    if (kind != null) json['kind'] = kind!.wireValue;
    final fields = searchFields;
    if (fields.tags || fields.text || fields.author) {
      json['exclude_terms'] = _excludedTerms;
    }
    json.addAll({
      'origins': origins,
      'exclude_folders': _excludedFolders,
      'exclude_recent': _excludeRecent,
      'exclude_loose': _excludeExternal,
    });
    return FeedFilter.fromJson(json);
  }

  /// As Swift does, builds the request even for a contradiction. The caller MUST
  /// return an empty result without calling Core.feed when isContradictory.
  FeedRequest request({
    FeedFilter? over,
    int? seed,
    bool newestFirst = false,
  }) => FeedRequest(
    terms: terms,
    scope: scope,
    seed: seed,
    newest_first: newestFirst,
    // no fuzzy or semantic matching in the Flutter apps: a term matches its tag exactly
    fuzzy: false,
    fields: searchFields,
    filter: filter(over: over),
  );
  SearchMarks get marks => SearchMarks(terms: terms, fields: searchFields);
  static const pendingFolder = 'p:folder';
  static const minusSigns = {
    '-',
    '\uFF0D',
    '\u2212',
    '\u2013',
  }; // i18n-exempt: parser input characters, not UI text
  static String termKey(String term) => 't:$term';
  static String folderKey(String name) => 'd:$name';
  static bool isExcluded(String key) => key.startsWith('-');
  static String? negated(String word) =>
      word.length > 1 && minusSigns.contains(word[0])
      ? word.substring(1)
      : null;
  static String keyFor(String word, {String? after}) {
    if (after == pendingFolder) return folderKey(word);
    if (after == '-$pendingFolder') {
      return '-${folderKey(negated(word) ?? word)}';
    }
    final rest = negated(word);
    if (rest != null) {
      final keyword = SearchKeyword.from(rest);
      return '-${keyword != null && keyword.excludable ? keyword.key : termKey(rest.toLowerCase())}';
    }
    return SearchKeyword.from(word)?.key ?? termKey(word);
  }

  static ({List<String> keys, String rest}) split(String text) {
    final separators = RegExp('[ \u3000\n\t]');
    final matches = separators.allMatches(text).toList();
    if (matches.isEmpty) return (keys: const [], rest: text);
    final last = matches.last;
    final done = text
        .substring(0, last.start)
        .split(separators)
        .where((s) => s.isNotEmpty);
    final keys = <String>[];
    for (final word in done) {
      final previous = keys.isEmpty ? null : keys.last;
      final key = keyFor(word, after: previous);
      if (previous == pendingFolder || previous == '-$pendingFolder') {
        keys[keys.length - 1] = key;
      } else {
        keys.add(key);
      }
    }
    return (keys: List.unmodifiable(keys), rest: text.substring(last.end));
  }

  static String title(String key) {
    final bare = isExcluded(key) ? key.substring(1) : key;
    if (bare.startsWith('t:')) return bare.substring(2);
    if (bare.startsWith('d:')) {
      return L('search.token.folder', [bare.substring(2)]);
    }
    if (bare == pendingFolder) return L('search.token.folderPending');
    for (final keyword in SearchKeyword.values) {
      if (keyword.key == bare) return keyword.word;
    }
    return bare;
  }

  static String spoken(String key) =>
      isExcluded(key) ? L('search.token.excluded', [title(key)]) : title(key);
}
