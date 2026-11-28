import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../../app/library.dart';
import '../../app/prefs.dart';
import '../../app/jobs.dart';
import '../../app/shell.dart' show ShellLayout;
import '../../actions/media_actions.dart' show menuAnimation;
import '../../l10n/l10n.dart';
import '../../widgets/text_menu.dart';

/// 标签: every tag with how many media carry it (yours and the AI's); rename or merge one, put
/// its media into a folder, delete it; delete all AI tags.
///  * Wide screen (`ShellLayout.sidebar`): macOS-aligned tag card grid.
///  * Narrow screen (`ShellLayout.bar`): high-density 2-column micro-tiles without per-row icons,
///    using compact colored dot counts and a bottom 3-segment proportion bar (Mine / Common / AI).
List<TagCount> sortedTags(List<TagCount> tags, int order) {
  int by(int a, int b, TagCount x, TagCount y) => a != b ? b.compareTo(a) : x.label.compareTo(y.label);
  return [...tags]..sort((x, y) => switch (order) {
        1 => by(x.user, y.user, x, y),
        2 => by(x.ai, y.ai, x, y),
        3 => x.label.compareTo(y.label),
        _ => by(x.count, y.count, x, y),
      });
}

enum _TagShow { all, mine, ai, both }

const _tagMineColor = Color(0xFF007AFF);
const _tagAiColor = Color(0xFFAF52DE);
const _tagBothColor = Color(0xFF34C759);

int _commonCount(TagCount t) => math.max(0, t.user + t.ai - t.count);

class TagsPage extends StatefulWidget {
  const TagsPage({super.key, required this.library});
  final LibraryModel library;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  List<TagCount>? _tags;
  /// 筛选标签: only the tags whose name holds this (as the native apps' field).
  String _query = '';
  _TagShow _show = _TagShow.all;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final t = await coreRunAsync(Core.allTags);
    if (mounted) setState(() => _tags = t);
  }

  static String _orderTitle(int order) => switch (order) {
        1 => L('tags.sort.mine'),
        2 => L('tags.sort.ai'),
        3 => L('common.name'),
        _ => L('tags.sort.count'),
      };

  static String _showTitle(_TagShow s) => switch (s) {
        _TagShow.all => L('search.kw.all.word'),
        _TagShow.mine => L('search.kw.mine.word'),
        _TagShow.ai => L('search.kw.ai.word'),
        _TagShow.both => L('search.kw.common.word'),
      };

  Future<void> _changed() async {
    await widget.library.refresh();
    await _load();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  void _showOnHome(String label) {
    widget.library.showInBrowse(FeedFilter(labels: [label]));
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<String?> _ask(String title, String message, String initial, String action) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [Text(message), TextField(contextMenuBuilder: appTextMenu, controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v))]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(action)),
        ],
      ),
    );
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L('common.cancel'))),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error), onPressed: () => Navigator.pop(d, true), child: Text(action)),
          ],
        ),
      ) ??
      false;

  Future<void> _rename(TagCount t) async {
    final to = (await _ask(L('tags.rename.title', [t.label]), '${L('tags.rename.countMessage', [t.count])}\n${L('tags.rename.message')}', t.label, L('common.done')))?.trim().toLowerCase();
    if (to == null || to.isEmpty || to == t.label) return;
    Core.renameTag(t.label, to);
    _toast(L('tags.renamed'));
    await _changed();
  }

  Future<void> _toFolder(TagCount t) async {
    final folder = (await _ask(L('tags.toFolder.title', [t.label, t.count]), L('tags.toFolder.message'), '', L('common.addToFolder')))?.trim();
    if (folder == null || folder.isEmpty) return;
    final n = await tagToFolder(t.label, folder, create: !(widget.library.folders?.folders.any((f) => f.name == folder) ?? false));
    if (!mounted) return;
    _toast(n < t.count ? L('tags.toFolder.partly', [n]) : L('tags.toFolder.done', [folder]));
    await _changed();
  }

  Future<void> _delete(TagCount t) async {
    if (!await _confirm(L('tags.delete.title', [t.label]), L('tags.delete.message', [t.count]), L('common.delete'))) return;
    Core.deleteTag(t.label);
    await _changed();
  }

  Future<void> _deleteAI() async {
    final ai = _tags?.where((t) => t.ai > 0).length ?? 0;
    if (!await _confirm(L('tags.deleteAI.title', [ai]), L('tags.deleteAI.message'), L('tags.deleteAI.confirm'))) return;
    await coreRunAsync(Core.removeAITags);
    await _changed();
  }

  Future<void> _openCardMenu(TagCount t, Offset position) async {
    final theme = Theme.of(context);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<void Function()>(
      context: context,
      popUpAnimationStyle: menuAnimation,
      position: RelativeRect.fromRect(Rect.fromLTWH(position.dx, position.dy, 0, 0), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: () => _showOnHome(t.label), child: Text(L('tags.onlyOnHome'))),
        PopupMenuItem(value: () => _toFolder(t), child: Text(L('common.addToFolder'))),
        const PopupMenuDivider(),
        PopupMenuItem(value: () => _rename(t), child: Text(L('tags.renameOrMerge'))),
        PopupMenuItem(value: () => _delete(t), child: Text(L('tags.deleteEllipsis'), style: TextStyle(color: theme.colorScheme.error))),
      ],
    );
    action?.call();
  }

  List<TagCount> _filtered(List<TagCount> all, int order) {
    final q = _query.trim().toLowerCase();
    var list = q.isEmpty ? all : all.where((t) => t.label.toLowerCase().contains(q)).toList();
    list = switch (_show) {
      _TagShow.all => list,
      _TagShow.mine => list.where((t) => t.user > 0).toList(),
      _TagShow.ai => list.where((t) => t.ai > 0).toList(),
      _TagShow.both => list.where((t) => _commonCount(t) > 0).toList(),
    };
    return sortedTags(list, order);
  }

  Widget _legend(BuildContext context, {bool compact = false}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final dotSize = compact ? 6.0 : 8.0;
    final style = (compact ? theme.textTheme.labelSmall : theme.textTheme.bodySmall)?.copyWith(color: cs.onSurfaceVariant);
    Widget item(String name, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: dotSize, height: dotSize, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(name, style: style),
          ],
        );
    return Wrap(
      spacing: compact ? 10 : 12,
      runSpacing: 4,
      children: [
        item(L('search.kw.mine.word'), _tagMineColor),
        item(L('search.kw.common.word'), _tagBothColor),
        item('AI', _tagAiColor),
      ],
    );
  }

  Widget _emptyState(BuildContext context, bool libraryEmpty) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(libraryEmpty ? Icons.sell_outlined : Icons.search, size: 36, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
            const SizedBox(height: 10),
            Text(libraryEmpty ? L('tags.none') : L('tags.noMatch'), style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(libraryEmpty ? L('tags.none.message') : L('tags.noMatch.message'),
                style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = ShellLayout.of(MediaQuery.sizeOf(context)) == ShellLayout.sidebar;
    return wide ? _buildWide(context) : _buildNarrow(context);
  }

  // ---- Wide-screen card grid (aligned with macOS TagCardsView) ----------------------------------

  Widget _buildWide(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final order = Prefs.instance.tagSort;
    final all = _tags;
    final tags = all == null ? null : _filtered(all, order);
    final summary = all == null || all.isEmpty
        ? ''
        : '${L('tags.total', [all.length])}${tags!.length == all.length ? '' : L('tags.shown', [tags.length])}';

    return Scaffold(
      appBar: AppBar(title: Text(L('common.tags'))),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 948),
                child: CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 18),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    key: const ValueKey('tagFilter'),
                                    controller: _searchController,
                                    contextMenuBuilder: appTextMenu,
                                    onChanged: (v) => setState(() => _query = v),
                                    decoration: InputDecoration(
                                      hintText: L('tags.filter'),
                                      prefixIcon: const Icon(Icons.search, size: 18),
                                      suffixIcon: _query.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: L('common.clear'),
                                              icon: const Icon(Icons.close, size: 18),
                                              onPressed: () {
                                                _searchController.clear();
                                                setState(() => _query = '');
                                              },
                                            ),
                                      isDense: true,
                                      filled: true,
                                      fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.65),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide.none),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                PopupMenuButton<int>(
                                  key: const ValueKey('tagSort'),
                                  tooltip: L('tags.sort'),
                                  popUpAnimationStyle: menuAnimation,
                                  onSelected: (v) => setState(() => Prefs.instance.tagSort = v),
                                  itemBuilder: (_) => [
                                    for (var o = 0; o < 4; o++) CheckedPopupMenuItem(value: o, checked: o == order, child: Text(_orderTitle(o))),
                                  ],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.swap_vert, size: 18, color: cs.onSurfaceVariant),
                                        const SizedBox(width: 4),
                                        Text('${L('tags.sortBy')}${_orderTitle(order)}', style: theme.textTheme.bodyMedium),
                                      ],
                                    ),
                                  ),
                                ),
                                PopupMenuButton<void Function()>(
                                  popUpAnimationStyle: menuAnimation,
                                  icon: const Icon(Icons.more_horiz),
                                  onSelected: (f) => f(),
                                  itemBuilder: (_) => [
                                    PopupMenuItem(value: _deleteAI, child: Text(L('tags.deleteAIEllipsis'), style: TextStyle(color: cs.error))),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 14,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              alignment: WrapAlignment.spaceBetween,
                              children: [
                                SegmentedButton<_TagShow>(
                                  showSelectedIcon: false,
                                  style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                                  segments: [
                                    for (final s in _TagShow.values) ButtonSegment(value: s, label: Text(_showTitle(s))),
                                  ],
                                  selected: {_show},
                                  onSelectionChanged: (v) => setState(() => _show = v.first),
                                ),
                                _legend(context),
                              ],
                            ),
                            if (summary.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Text(summary, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (tags!.isEmpty)
                      SliverFillRemaining(hasScrollBody: false, child: _emptyState(context, all.isEmpty))
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + MediaQuery.paddingOf(context).bottom),
                        sliver: SliverGrid(
                          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 260,
                            mainAxisSpacing: 14,
                            crossAxisSpacing: 14,
                            mainAxisExtent: 176,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _TagCard(
                              tag: tags[i],
                              onOpen: () => _showOnHome(tags[i].label),
                              onMenu: (pos) => _openCardMenu(tags[i], pos),
                            ),
                            childCount: tags.length,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  // ---- Narrow-screen 2-column micro-tiles (Plan B) ----------------------------------------------

  Widget _buildNarrow(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final order = Prefs.instance.tagSort;
    final all = _tags;
    final tags = all == null ? null : _filtered(all, order);
    final summary = all == null || all.isEmpty
        ? ''
        : '${L('tags.total', [all.length])}${tags!.length == all.length ? '' : L('tags.shown', [tags.length])}';

    return Scaffold(
      appBar: AppBar(
        title: Text(L('common.tags')),
        actions: [
          PopupMenuButton<int>(
            key: const ValueKey('tagSort'),
            icon: const Icon(Icons.sort),
            tooltip: L('tags.sort'),
            popUpAnimationStyle: menuAnimation,
            onSelected: (v) => setState(() => Prefs.instance.tagSort = v),
            itemBuilder: (_) => [
              for (var o = 0; o < 4; o++) CheckedPopupMenuItem(value: o, checked: o == order, child: Text(_orderTitle(o))),
            ],
          ),
          PopupMenuButton<void Function()>(
            popUpAnimationStyle: menuAnimation,
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(value: _deleteAI, child: Text(L('tags.deleteAIEllipsis'), style: TextStyle(color: cs.error))),
            ],
          ),
        ],
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : all.isEmpty
              ? _emptyState(context, true)
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SearchBar(
                              key: const ValueKey('tagFilter'),
                              controller: _searchController,
                              hintText: L('tags.filter'),
                              leading: const Icon(Icons.search),
                              elevation: const WidgetStatePropertyAll(0),
                              onChanged: (v) => setState(() => _query = v),
                              trailing: [
                                if (_query.isNotEmpty)
                                  IconButton(
                                    tooltip: L('common.clear'),
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _searchController.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            SegmentedButton<_TagShow>(
                              showSelectedIcon: false,
                              style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
                              segments: [
                                for (final s in _TagShow.values) ButtonSegment(value: s, label: Text(_showTitle(s))),
                              ],
                              selected: {_show},
                              onSelectionChanged: (v) => setState(() => _show = v.first),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                if (summary.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      summary,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.labelSmall?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontFeatures: const [FontFeature.tabularFigures()],
                                      ),
                                    ),
                                  ),
                                _legend(context, compact: true),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (tags!.isEmpty)
                      SliverFillRemaining(hasScrollBody: false, child: _emptyState(context, false))
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom),
                        sliver: SliverGrid(
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            mainAxisExtent: 84,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _NarrowTagTile(
                              tag: tags[i],
                              onOpen: () => _showOnHome(tags[i].label),
                              onMenu: (pos) => _openCardMenu(tags[i], pos),
                            ),
                            childCount: tags.length,
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}

class _TagProportionBar extends StatelessWidget {
  const _TagProportionBar({required this.tag, required this.height});
  final TagCount tag;
  final double height;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final common = _commonCount(tag);
    final onlyMine = tag.user - common;
    final onlyAi = tag.ai - common;
    final parts = <(int, Color)>[
      if (onlyMine > 0) (onlyMine, _tagMineColor),
      if (common > 0) (common, _tagBothColor),
      if (onlyAi > 0) (onlyAi, _tagAiColor),
    ];

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final total = math.max(tag.count, 1);
          final gaps = math.max(parts.length - 1, 0) * 2.0;
          final usable = math.max(0.0, constraints.maxWidth - gaps);
          return Container(
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                for (var i = 0; i < parts.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Container(
                    width: math.max(5.0, usable * parts[i].$1 / total),
                    height: height,
                    decoration: BoxDecoration(
                      color: parts[i].$2,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _NarrowTagTile extends StatelessWidget {
  const _NarrowTagTile({required this.tag, required this.onOpen, required this.onMenu});
  final TagCount tag;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final common = _commonCount(tag);

    Widget dot(int count, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 11,
                color: cs.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        );

    return GestureDetector(
      key: ValueKey('tag-${tag.label}'),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      onLongPressStart: (d) => onMenu(d.globalPosition),
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.55), width: 0.6),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Expanded(
                      child: Text(
                        tag.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${tag.count}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 2,
                  children: [
                    if (tag.user > 0) dot(tag.user, _tagMineColor),
                    if (common > 0) dot(common, _tagBothColor),
                    if (tag.ai > 0) dot(tag.ai, _tagAiColor),
                  ],
                ),
                _TagProportionBar(tag: tag, height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TagCard extends StatelessWidget {
  const _TagCard({required this.tag, required this.onOpen, required this.onMenu});
  final TagCount tag;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final common = _commonCount(tag);

    Widget stat(String name, int count, Color color) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text(
              '$name $count',
              style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        );

    return GestureDetector(
      key: ValueKey('tag-${tag.label}'),
      onSecondaryTapUp: (d) => onMenu(d.globalPosition),
      onLongPressStart: (d) => onMenu(d.globalPosition),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.65), width: 0.8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: Text(
                        tag.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(fontSize: 16, fontWeight: FontWeight.w600, height: 1.25),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      tooltip: L('tags.onlyOnHome'),
                      color: cs.primary,
                      onPressed: onOpen,
                      icon: const Icon(Icons.north_east),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${tag.count}',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      height: 1.05,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(L('tags.itemsUnit'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                ],
              ),
              const SizedBox(height: 10),
              _TagProportionBar(tag: tag, height: 8),
              const Spacer(),
              Wrap(
                spacing: 10,
                runSpacing: 4,
                children: [
                  if (tag.user > 0) stat(L('search.kw.mine.word'), tag.user, _tagMineColor),
                  if (tag.ai > 0) stat('AI', tag.ai, _tagAiColor),
                  if (common > 0) stat(L('search.kw.common.word'), common, _tagBothColor),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
