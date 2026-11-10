
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../l10n/l10n.dart';
import '../widgets/text_menu.dart';

/// The tag adder (a card's "+", the menus' 添加标签), as the native apps have it: type to filter
/// the existing tags (yours first, then by use) or to create one; Enter adds what is typed and
/// the picker stays open for more; for a media of a post a switch chooses this media or the
/// whole post. A sheet on a narrow window, a dialog on a wide one.
Future<void> showTagPicker(BuildContext context, LibraryModel library, FeedItem media, {bool wholePost = false}) async {
  final all = await coreRunAsync(Core.allTags);
  final scope = Core.postScope(media.post_id);
  if (!context.mounted) return;
  final picker = _TagPicker(library: library, media: media, scope: scope, all: all, wholePost: wholePost && !media.post_id.startsWith('loose:'));
  if (MediaQuery.sizeOf(context).width < 600) {
    await showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true, useSafeArea: true, builder: (_) => FractionallySizedBox(heightFactor: 0.75, child: picker));
  } else {
    await showDialog<void>(context: context, builder: (_) => Dialog(child: SizedBox(width: 420, height: 520, child: picker)));
  }
}

class _TagPicker extends StatefulWidget {
  const _TagPicker({required this.library, required this.media, required this.scope, required this.all, required this.wholePost});
  final LibraryModel library;
  final FeedItem media;
  final MediaScope scope;
  final List<TagCount> all;
  final bool wholePost;

  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  late MediaScope _scope = widget.scope;
  late bool _wholePost = widget.wholePost;
  final List<String> _added = [];
  final Map<String, List<ActionReceipt>> _receipts = {};
  final _query = TextEditingController();
  String? _error;

  List<String> get _targets => _wholePost ? _scope.ids : [widget.media.media_id];

  /// Tags every target already has (they are not offered again).
  Set<String> get _existing {
    final ids = _targets;
    if (ids.isEmpty) return {};
    var common = (_scope.user_tags[ids.first] ?? const []).toSet();
    for (final id in ids.skip(1)) {
      common = common.intersection((_scope.user_tags[id] ?? const []).toSet());
    }
    return common;
  }

  String get _trimmed => _query.text.trim().toLowerCase();

  List<TagCount> get _suggestions {
    final q = _trimmed, existing = _existing;
    final list = widget.all.where((t) => !existing.contains(t.label) && (q.isEmpty || t.label.contains(q))).toList()
      // the user's own tags first, then by use
      ..sort((a, b) {
        final u = (b.user > 0 ? 1 : 0) - (a.user > 0 ? 1 : 0);
        return u != 0 ? u : b.count.compareTo(a.count);
      });
    return list.take(40).toList();
  }

  bool get _canCreate => _trimmed.isNotEmpty && !widget.all.any((t) => t.label == _trimmed) && !_existing.contains(_trimmed);

  int _taggedCount(String label) => _targets.where((id) => (_scope.user_tags[id] ?? const []).contains(label)).length;

  void _add(String label) {
    final l = label.trim().toLowerCase();
    if (l.isEmpty || _existing.contains(l)) return;
    try {
      final receipt = Core.action(ActionKind.tag,
          media: _wholePost ? const [] : [widget.media.media_id], posts: _wholePost ? [widget.media.post_id] : const [], label: l);
      (_receipts[l] ??= []).add(receipt);
    } catch (e) {
      setState(() => _error = '$e');
      return;
    }
    setState(() {
      _scope = Core.postScope(widget.media.post_id);
      if (!_added.contains(l)) _added.add(l);
      _query.clear();
      _error = null;
    });
    widget.library.refresh();
  }

  void _undoAddition(String label) {
    try {
      final receipts = _receipts[label]!;
      while (receipts.isNotEmpty) {
        Core.undo(receipts.last);
        receipts.removeLast();
      }
      setState(() {
        _receipts.remove(label);
        _added.remove(label);
        _scope = Core.postScope(widget.media.post_id);
        _error = null;
      });
      widget.library.refresh();
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loose = widget.media.post_id.startsWith('loose:');
    final suggestions = _suggestions;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (loose)
            Text(L('tagPicker.title'), style: theme.textTheme.titleMedium)
          else
            SegmentedButton<bool>(
              key: const ValueKey('tagPickerScope'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text(L('tagPicker.thisMedia'))),
                ButtonSegment(value: true, label: Text(L('tagPicker.wholePost', [_scope.ids.length]))),
              ],
              selected: {_wholePost},
              onSelectionChanged: (s) => setState(() {
                _wholePost = s.first;

              }),
            ),
          const Spacer(),
          FilledButton.tonal(key: const ValueKey('pickerDone'), onPressed: () => Navigator.pop(context), child: Text(L('common.done'))),
        ]),
        if (_scope.pending_count > 0)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(L('tagPicker.pending', [_scope.pending_count]), style: theme.textTheme.bodySmall)),
        const SizedBox(height: 12),
        TextField(contextMenuBuilder: appTextMenu, 
          key: const ValueKey('tagPickerField'),
          controller: _query,
          autofocus: true,
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: L('tagPicker.placeholder'), filled: true, border: const OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(12)))),
          onChanged: (_) => setState(() {}),
          onSubmitted: (v) => _trimmed.isEmpty ? Navigator.pop(context) : _add(v),
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(L('tagPicker.error'), style: TextStyle(color: theme.colorScheme.error))),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(children: [
            if (_canCreate)
              ListTile(
                key: const ValueKey('tagPickerCreate'),
                leading: Icon(Icons.add_circle, color: theme.colorScheme.primary),
                title: Text(L('tagPicker.create', [_trimmed]), style: TextStyle(color: theme.colorScheme.primary)),
                onTap: () => _add(_trimmed),
              ),
            if (_added.isNotEmpty) ...[
              _Header(L('tagPicker.justAdded')),
              for (final t in _added) ListTile(key: ValueKey('tagPickerUndo-$t'), dense: true, leading: Icon(Icons.check_circle, color: theme.colorScheme.primary), title: Text(t), trailing: Text(L('common.undo')), onTap: () => _undoAddition(t)),
            ],
            _Header(_trimmed.isEmpty ? L('tagPicker.frequent') : L('tagPicker.matching')),
            for (final t in suggestions)
              ListTile(
                key: ValueKey('tagPickerRow-${t.label}'),
                dense: true,
                leading: Icon(t.user > 0 ? Icons.sell_outlined : Icons.auto_awesome, color: t.user > 0 ? theme.colorScheme.primary : theme.colorScheme.tertiary),
                title: Text(t.label),
                trailing: Text(L('tagPicker.tagged', [_taggedCount(t.label), _targets.length]), style: theme.textTheme.bodySmall),
                onTap: () => _add(t.label),
              ),
          ]),
        ),
      ]),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
