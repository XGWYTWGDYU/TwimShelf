import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import '../mascot/mascot.dart';
import '../search/history.dart';
import '../search/query.dart';
import '../search/suggestions.dart';
import 'text_menu.dart';

/// The native apps' search field: finished words turn into capsules (a keyword, a folder, a
/// term; with a leading minus they exclude), and while typing a panel under the field suggests
/// keywords, tags, folders and recent searches. Every change reports the whole query.
class CapsuleSearch extends StatefulWidget {
  const CapsuleSearch({
    super.key,
    required this.onChanged,
    required this.folders,
    this.initialKeys = const [],
    this.fullScreen = false,
    this.inline = false,
    this.autofocus = false,
    this.trailing,
    this.addKey,
    this.flat = false,
  });
  /// On a capsule of its own: no fill of its own.
  final bool flat;
  /// Set to a key (a term, a folder…) to add it as a capsule from outside (a card's 搜索此标签).
  final ValueNotifier<String?>? addKey;
  /// Beside the field in the inline layout (the full-screen page's 完成).
  final Widget Function(List<String> keys)? trailing;
  final void Function(TokenQuery query) onChanged;
  final List<String> initialKeys;
  /// A phone's way (the native iPhone app's): the field only shows the query; a tap opens
  /// searching full screen, and the query chosen there comes back.
  final bool fullScreen;
  /// The suggestions as a list under the field filling the space (the full-screen page), rather
  /// than a panel floating over the page.
  final bool inline;
  final bool autofocus;
  /// The folders to suggest (name and media count).
  final List<SearchFolder> Function() folders;

  @override
  State<CapsuleSearch> createState() => _CapsuleSearchState();
}

class _CapsuleSearchState extends State<CapsuleSearch> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _panel = OverlayPortalController();
  final _link = LayerLink();
  final _scroll = ScrollController();
  late List<String> _keys = widget.initialKeys;
  List<TagCount> _tags = const [];
  SearchHistory? _history;

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    if (widget.inline) _loadTags();
    if (_keys.isNotEmpty) _setText('');
    widget.addKey?.addListener(_external);
    _focus.addListener(() {
      if (widget.fullScreen || widget.inline) return;
      if (_focus.hasFocus) {
        _loadTags();
        _panel.show();
      } else {
        // a tap on a panel row arrives after the field loses focus
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_focus.hasFocus) _panel.hide();
        });
      }
      setState(() {});
    });
    SharedPreferences.getInstance().then((p) {
      if (mounted) setState(() => _history = SearchHistory(p));
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    widget.addKey?.removeListener(_external);
    super.dispose();
  }

  void _external() {
    final k = widget.addKey?.value;
    if (k == null) return;
    widget.addKey!.value = null;
    setState(() => _keys = _appendKey(_keys, k));
    _setText(_typedText);
    widget.onChanged(query);
  }

  void _loadTags() {
    try {
      _tags = Core.allTags();
    } catch (_) {}
  }

  /// Opens searching full screen with the current capsules; what is chosen there comes back.
  Future<void> _openFullScreen() async {
    final keys = await Navigator.of(context, rootNavigator: true).push<List<String>>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => SearchScreen(initialKeys: _keys, folders: widget.folders),
    ));
    if (keys == null || !mounted) return;
    setState(() => _keys = keys);
    _setText(_typedText);
    widget.onChanged(query);
  }

  /// The query: the capsules and the word being typed.
  TokenQuery get query {
    final rest = _typedText.trim();
    final keys = [..._keys];
    if (rest.isNotEmpty && !TokenQuery.minusSigns.contains(rest)) {
      final last = keys.isEmpty ? null : keys.last;
      final key = TokenQuery.keyFor(rest, after: last);
      if (last == TokenQuery.pendingFolder || last == '-${TokenQuery.pendingFolder}') {
        keys[keys.length - 1] = key;
      } else {
        keys.add(key);
      }
    }
    return TokenQuery(keys: keys);
  }

  /// With capsules, the field holds an invisible mark before what is typed: an on-screen
  /// keyboard says nothing about a delete in an empty field, but deleting the mark is a change —
  /// it takes the last capsule away, as deleting does in the native search field.
  static const _mark = '\u200B';
  String get _typedText => _text.text.replaceAll(_mark, '');

  /// The field shows [rest] (after the mark while there are capsules), the cursor at the end.
  void _setText(String rest) {
    final t = (_keys.isNotEmpty ? _mark : '') + rest;
    _text.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  void _typed(String raw) {
    if (_keys.isNotEmpty && !raw.startsWith(_mark)) {
      // the mark was deleted: the last capsule goes
      setState(() => _keys = [..._keys]..removeLast());
      _setText(raw.replaceAll(_mark, ''));
      widget.onChanged(query);
      return;
    }
    final value = raw.replaceAll(_mark, '');
    final split = TokenQuery.split(value);
    if (split.keys.isNotEmpty) {
      var keys = [..._keys];
      for (final k in split.keys) {
        keys = _appendKey(keys, k);
      }
      _keys = keys;
      _setText(split.rest);
    }
    setState(() {});
    widget.onChanged(query);
    _toEnd();
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  static List<String> _appendKey(List<String> keys, String key) {
    final last = keys.isEmpty ? null : keys.last;
    if ((last == TokenQuery.pendingFolder || last == '-${TokenQuery.pendingFolder}') && key.contains('d:')) {
      return [...keys.sublist(0, keys.length - 1), key];
    }
    if (keys.contains(key)) return keys;
    return [...keys, key];
  }

  void _pick(SearchSuggestion row) {
    switch (row.kind) {
      case SuggestionKind.clearHistory:
        _history?.clear().catchError((_) {});
      case SuggestionKind.history:
        _keys = TokenQuery.split('${row.label} ').keys;
        _setText('');
      case SuggestionKind.empty:
        return;
      default:
        final key = row.key;
        if (key == null) return;
        _keys = _appendKey(_keys, key);
        _setText('');
    }
    setState(() {});
    widget.onChanged(query);
    _focus.requestFocus();
  }

  void _remove(String key) {
    setState(() => _keys = [..._keys]..remove(key));
    _setText(_typedText);
    widget.onChanged(query);
  }

  void _submit() {
    final q = query;
    if (q.keys.isNotEmpty) {
      final words = [for (final k in q.keys) _word(k)].join(' ');
      _history?.add(words).catchError((_) {});
    }
    _focus.unfocus();
    if (widget.inline) Navigator.of(context).pop(q.keys);
  }

  /// A key written back as the user would type it (for the history).
  static String _word(String key) {
    final ex = TokenQuery.isExcluded(key);
    final bare = ex ? key.substring(1) : key;
    final word = bare.startsWith('d:')
        ? '${SearchKeyword.folder.word} ${bare.substring(2)}'
        : TokenQuery.title(bare);
    return ex ? '-$word' : word;
  }

  void _clear() {
    setState(() {
      _keys = const [];
      _setText('');
    });
    widget.onChanged(query);
  }

  static IconData _icon(String? symbol) => switch (symbol) {
        'tag' => Icons.sell_outlined,
        'text.quote' => Icons.notes,
        'person' => Icons.person_outline,
        'person.crop.circle' => Icons.account_circle_outlined,
        'sparkles' => Icons.auto_awesome_outlined,
        'checkmark.seal' => Icons.verified_outlined,
        'circle.grid.2x2' => Icons.apps,
        'video' => Icons.videocam_outlined,
        'photo' => Icons.photo_outlined,
        'folder' => Icons.folder_outlined,
        'clock.badge.checkmark' => Icons.history_toggle_off,
        'square.and.arrow.down' => Icons.download_outlined,
        'minus.circle' => Icons.remove_circle_outline,
        'clock' || 'clock.arrow.circlepath' => Icons.history,
        'trash' => Icons.delete_outline,
        _ => Icons.search,
      };

  List<Widget> _rows(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sections = suggestionSections(_typedText, _keys, _tags, widget.folders(), history: _history?.items ?? const []);
    final rows = <Widget>[];
    for (final s in sections) {
      if (s.rows.isEmpty) continue;
      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(s.title, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ));
      for (final r in s.rows) {
        final color = switch (r.tint) {
          SuggestionTint.exclude => scheme.error,
          SuggestionTint.folder => scheme.tertiary,
          SuggestionTint.secondary => scheme.onSurfaceVariant,
          SuggestionTint.accent => scheme.primary,
        };
        rows.add(ListTile(
          key: ValueKey('suggest-${r.id}'),
          dense: true,
          enabled: r.kind != SuggestionKind.empty,
          leading: Icon(_icon(r.symbol), color: r.destructive ? scheme.error : color),
          title: Text(r.label, style: r.destructive ? TextStyle(color: scheme.error) : null),
          subtitle: r.detail == null ? null : Text(r.detail!),
          onTap: () => _pick(r),
        ));
      }
    }
    return rows;
  }

  Widget _panelView(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows(context);
    if (rows.isEmpty) return const SizedBox.shrink();
    return Material(
      elevation: 3,
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5, maxWidth: width),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 8), children: rows),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.inline) {
      return LayoutBuilder(builder: (context, c) {
        final width = c.maxWidth.isFinite ? c.maxWidth : 480.0;
        return Column(children: [
          Row(children: [
            Expanded(child: _field(context, width)),
            if (widget.trailing != null) widget.trailing!(query.keys),
          ]),
          Expanded(child: ListView(padding: const EdgeInsets.only(top: 8, bottom: 24), children: _rows(context))),
        ]);
      });
    }
    return LayoutBuilder(builder: (context, c) {
      final width = c.maxWidth.isFinite ? c.maxWidth : 480.0;
      return OverlayPortal(
        controller: _panel,
        overlayChildBuilder: (context) => CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomLeft,
          offset: const Offset(0, 6),
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: _panelView(context, width))),
        ),
        child: CompositedTransformTarget(
          link: _link,
          child: _field(context, width),
        ),
      );
    });
  }

  Widget _field(BuildContext context, double width) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: widget.flat ? Colors.transparent : scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(24)),
            child: Row(children: [
              // once something is searched for
              MascotIcon(_keys.isEmpty ? null : 'search', fallback: Icon(Icons.search, color: scheme.onSurfaceVariant)),
              const SizedBox(width: 8),
              // the capsules (at most about 60% of the field, scrolling, the newest in view), then
              // the text field in all the room left: what is typed always starts at its own edge
              if (_keys.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width * 0.6),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [
                      for (final k in _keys)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 6),
                          child: InputChip(
                            key: ValueKey('capsule-$k'),
                            label: Text(TokenQuery.title(k)),
                            tooltip: TokenQuery.spoken(k),
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            avatar: TokenQuery.isExcluded(k) ? Icon(Icons.remove, size: 16, color: scheme.error) : null,
                            backgroundColor: TokenQuery.isExcluded(k) ? scheme.errorContainer : null,
                            onDeleted: () => _remove(k),
                          ),
                        ),
                    ]),
                  ),
                ),
              Expanded(
                child: TextField(contextMenuBuilder: appTextMenu, 
                  key: const ValueKey('search'),
                  controller: _text,
                  focusNode: _focus,
                  textAlign: TextAlign.start,
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                    hintText: _keys.isEmpty ? L('search.placeholder') : null,
                    hintMaxLines: 1,
                  ),
                  readOnly: widget.fullScreen,
                  onTap: widget.fullScreen ? _openFullScreen : null,
                  onChanged: _typed,
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (_keys.isNotEmpty || _typedText.isNotEmpty)
                IconButton(key: const ValueKey('searchClear'), tooltip: L('common.clear'), icon: const Icon(Icons.close), onPressed: _clear),
            ]),
          );
  }
}

/// Searching full screen (a phone): the field at the top with 取消, the suggestions filling the
/// rest. Done hands the capsules back to the page that opened it.
class SearchScreen extends StatelessWidget {
  const SearchScreen({super.key, required this.initialKeys, required this.folders});
  final List<String> initialKeys;
  final List<SearchFolder> Function() folders;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: CapsuleSearch(
              key: const ValueKey('searchScreen'),
              inline: true,
              autofocus: true,
              initialKeys: initialKeys,
              folders: folders,
              onChanged: (_) {},
              trailing: (keys) => TextButton(
                key: const ValueKey('searchDone'),
                onPressed: () => Navigator.of(context).pop(keys),
                child: Text(L('common.done')),
              ),
            ),
          ),
        ),
      );
}
