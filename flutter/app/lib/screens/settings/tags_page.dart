import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../../app/library.dart';
import '../../app/jobs.dart';
import '../../actions/media_actions.dart' show menuAnimation;
import '../../l10n/l10n.dart';
import '../settings_page.dart' show SettingsIcon, SettingsPiece;
import '../../widgets/text_menu.dart';

/// 标签: every tag with how many media carry it (yours and the AI's); rename or merge one, put
/// its media into a folder, delete it; delete all AI tags.
class TagsPage extends StatefulWidget {
  const TagsPage({super.key, required this.library});
  final LibraryModel library;

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  List<TagCount>? _tags;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await Isolate.run(Core.allTags);
    t.sort((a, b) => b.count.compareTo(a.count));
    if (mounted) setState(() => _tags = t);
  }

  Future<void> _changed() async {
    await widget.library.refresh();
    await _load();
  }

  void _toast(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

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
    await Isolate.run(Core.removeAITags);
    await _changed();
  }

  @override
  Widget build(BuildContext context) {
    final tags = _tags;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L('common.tags')),
        actions: [
          PopupMenuButton<void Function()>(
            popUpAnimationStyle: menuAnimation,
            onSelected: (f) => f(),
            itemBuilder: (_) => [
              PopupMenuItem(value: _deleteAI, child: Text(L('tags.deleteAIEllipsis'), style: TextStyle(color: theme.colorScheme.error))),
            ],
          ),
        ],
      ),
      body: tags == null
          ? const Center(child: CircularProgressIndicator())
          : tags.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text(L('tags.none'), style: theme.textTheme.titleMedium), Text(L('tags.none.message'))]))
              : ListView.builder(
                  padding: EdgeInsets.only(top: 8, bottom: 24 + MediaQuery.paddingOf(context).bottom),
                  itemCount: tags.length,
                  itemBuilder: (context, i) {
                    final t = tags[i];
                    return Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(16, i == 0 ? 0 : 3, 16, 0),
                          child: SettingsPiece(
                            first: i == 0,
                            last: i == tags.length - 1,
                            child: ListTile(
                              key: ValueKey('tag-${t.label}'),
                              leading: SettingsIcon(t.user > 0 ? Icons.sell_outlined : Icons.auto_awesome),
                              title: Text(t.label),
                              subtitle: Text(L('common.count', [t.count])),
                              trailing: PopupMenuButton<void Function()>(
                                popUpAnimationStyle: menuAnimation,
                                onSelected: (f) => f(),
                                itemBuilder: (_) => [
                                  PopupMenuItem(value: () => _rename(t), child: Text(L('tags.renameOrMerge'))),
                                  PopupMenuItem(value: () => _toFolder(t), child: Text(L('common.addToFolder'))),
                                  PopupMenuItem(value: () => _delete(t), child: Text(L('tags.deleteEllipsis'), style: TextStyle(color: theme.colorScheme.error))),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}
