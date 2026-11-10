import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ai/local_models.dart';
import '../app/library.dart';
import '../l10n/l10n.dart';
import 'media_actions.dart';
import 'tag_picker.dart';
import '../widgets/text_menu.dart';

/// What 浏览 does for the card menu's filter and search entries.
class CardMenuHost {
  const CardMenuHost({required this.onlyAuthor, required this.onlyLabel, required this.addTerm});
  final void Function(String authorKey, String display) onlyAuthor;
  final void Function(String label) onlyLabel;
  final void Function(String term) addTerm;
}

/// An entry of a menu: an action, or a submenu (opened in place, as the native nested menus).
class _E {
  const _E(this.icon, this.label, {this.action, this.children, this.danger = false, this.key});
  final IconData icon;
  final String label;
  final VoidCallback? action;
  final List<_E>? children;
  final bool danger;
  final String? key;
}

/// Groups separated by dividers, shown at [position]; a submenu opens where the menu was.
Future<void> _show(BuildContext context, Offset position, List<List<_E>> groups) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final error = Theme.of(context).colorScheme.error;
  final items = <PopupMenuEntry<_E>>[];
  for (final g in groups.where((g) => g.isNotEmpty)) {
    if (items.isNotEmpty) items.add(const PopupMenuDivider(height: 9));
    for (final e in g) {
      items.add(PopupMenuItem<_E>(
        key: e.key == null ? null : ValueKey(e.key),
        value: e,
        height: 44,
        child: Row(children: [
          Icon(e.icon, size: 20, color: e.danger ? error : null),
          const SizedBox(width: 12),
          Flexible(child: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: e.danger ? TextStyle(color: error) : null)),
          if (e.children != null) ...[const SizedBox(width: 8), const Icon(Icons.chevron_right, size: 18)],
        ]),
      ));
    }
  }
  final chosen = await showMenu<_E>(
    context: context,
    position: RelativeRect.fromRect(overlay.globalToLocal(position) & const Size(1, 1), Offset.zero & overlay.size),
    popUpAnimationStyle: menuAnimation,
    items: items,
  );
  if (chosen == null || !context.mounted) return;
  if (chosen.children != null) return _show(context, position, [chosen.children!]);
  chosen.action?.call();
}

/// 浏览 card's long-press menu, as the native one: the author (only theirs, their
/// profile), tagging (this media, the whole post, approve the AI's, retag with a model, where
/// the tags came from), each tag (only it, search it, approve, rename, delete), folders (add the
/// media or the post, take it out of a folder), download again, and the deletions.
Future<void> showCardMenu(
  BuildContext context, {
  required LibraryModel library,
  required FeedItem item,
  required Offset position,
  required CardMenuHost host,
}) async {
  final loose = item.post_id.startsWith('loose:');
  final authorKey = item.screen_name ?? item.author_name;
  final authorDisplay = item.screen_name != null ? '@${item.screen_name}' : item.author_name ?? L('common.unknownAuthor');
  final messenger = ScaffoldMessenger.of(context);
  bool isAI(TagView t) => t.origin & 2 != 0;
  bool isUser(TagView t) => t.origin & 1 != 0;

  final top = <_E>[
    if (!loose && authorKey != null) _E(Icons.account_circle_outlined, L('card.menu.onlyAuthor', [authorDisplay]), action: () => host.onlyAuthor(authorKey, authorDisplay)),
    if (!loose && item.screen_name != null)
      _E(Icons.open_in_new, L('card.menu.openProfile', [item.screen_name!]), action: () => launchUrl(Uri.parse('https://x.com/${item.screen_name}'))),
  ];

  final pending = item.tags.where((t) => isAI(t) && !isUser(t)).toList();
  // on-device models too, not only external ones
  final local = LocalModels.instance;
  final retagModels = [
    for (final m in local.installed.where((m) => m.vision)) (id: m.id, title: local.title(m)),
    for (final m in library.aiModels.all) (id: m.id, title: m.title),
  ];
  List<_E> retagFor(String model) => [
        _E(Icons.add_circle_outline, L('card.menu.retagAdd'), action: () => library.tagger.retag([_ref(item)], model: model)),
        _E(Icons.sync, L('card.menu.retagReplace'), action: () => library.tagger.retag([_ref(item)], model: model, replaceOld: true)),
      ];
  final tagging = <_E>[
    _E(Icons.sell_outlined, L('card.menu.tagMedia'), key: 'menu-tagMedia', action: () => showTagPicker(context, library, item)),
    if (!loose) _E(Icons.layers_outlined, L('card.menu.tagPost'), action: () => showTagPicker(context, library, item, wholePost: true)),
    if (pending.isNotEmpty)
      _E(Icons.verified_outlined, L('card.menu.approveAll'), action: () {
        for (final t in pending) {
          Core.addTag(t.label, item.media_id);
        }
        library.refresh();
      }),
    if (retagModels.isNotEmpty)
      _E(Icons.auto_awesome, L('card.menu.retag'),
          children: retagModels.length == 1
              ? retagFor(retagModels.single.id)
              : [
                  for (final m in retagModels)
                    _E(m.id == library.aiModels.activeTaggerId ? Icons.star : Icons.public, m.title, children: retagFor(m.id)),
                ]),
    if (item.tags.isNotEmpty) _E(Icons.info_outline, L('card.menu.sources'), action: () => _showSources(context, library, item)),
  ];

  void deleteTag(TagView t) {
    Core.removeTag(t.label, item.media_id);
    library.refresh();
    messenger.showSnackBar(SnackBar(
      content: Text(L('tag.deleted', [t.label])),
      // with an action a SnackBar otherwise stays until the action is used
      persist: false,
      action: SnackBarAction(
        label: L('common.undo'),
        onPressed: () {
          // the same origin back (yours, AI, or endorsed)
          if (isAI(t)) Core.addTag(t.label, item.media_id, ai: true);
          if (isUser(t)) Core.addTag(t.label, item.media_id);
          library.refresh();
        },
      ),
    ));
  }

  final perTag = <_E>[
    for (final t in item.tags)
      _E(isAI(t) ? (isUser(t) ? Icons.verified : Icons.auto_awesome) : Icons.sell, t.label, children: [
        _E(Icons.filter_alt_outlined, L('card.menu.onlyTag'), action: () => host.onlyLabel(t.label)),
        _E(Icons.search, L('card.menu.searchTag'), action: () => host.addTerm(t.label)),
        if (isAI(t) && !isUser(t))
          _E(Icons.verified_outlined, L('card.menu.approve'), action: () {
            Core.addTag(t.label, item.media_id);
            library.refresh();
          }),
        _E(Icons.edit_outlined, L('card.menu.renameTag'), action: () => _renameTag(context, library, t.label)),
        _E(Icons.label_off_outlined, L('card.menu.deleteTag'), danger: true, action: () => deleteTag(t)),
      ]),
  ];

  final inFolders = Core.mediaFolders(item.media_id);
  final folders = <_E>[
    _E(Icons.create_new_folder_outlined, L('common.addToFolder'), action: () => _toFolder(context, library, media: [item.media_id])),
    if (!loose) _E(Icons.drive_folder_upload_outlined, L('card.menu.postToFolder'), action: () => _toFolder(context, library, posts: [item.post_id])),
    if (inFolders.isNotEmpty)
      _E(Icons.folder_off_outlined, L('common.removeFromFolder'), children: [
        for (final f in inFolders)
          _E(Icons.folder_outlined, f, children: [
            _E(Icons.photo_outlined, L('card.menu.removeMedia'),
                action: () => runMediaAction(context, library, ActionKind.folderRemove, media: [item.media_id], folder: f, done: (_) => L('common.removeFromFolder'))),
            if (!loose)
              _E(Icons.layers_outlined, L('card.menu.removePost'),
                  action: () => runMediaAction(context, library, ActionKind.folderRemove, posts: [item.post_id], folder: f, done: (_) => L('common.removeFromFolder'))),
          ]),
      ]),
  ];

  final repair = <_E>[
    if (item.canRedownload) _E(Icons.cloud_sync_outlined, item.bad == null ? L('card.menu.redownload') : L('card.menu.redownloadBad'), action: () => _repair(context, library, item)),
  ];

  final delete = <_E>[
    if (item.tags.isNotEmpty)
      _E(Icons.label_off_outlined, L('card.menu.deleteTag'), danger: true, children: [
        for (final t in item.tags) _E(Icons.remove_circle_outline, t.label, danger: true, action: () => deleteTag(t)),
      ]),
    _E(Icons.delete_outline, L('card.menu.deleteMedia'), danger: true, key: 'menu-deleteMedia',
        action: () => runMediaAction(context, library, ActionKind.trash, media: [item.media_id], done: (n) => L('trash.moved', [n]))),
    if (!loose)
      _E(Icons.delete_sweep_outlined, L('card.menu.deletePost'), danger: true,
          action: () => runMediaAction(context, library, ActionKind.trash, posts: [item.post_id], done: (n) => L('trash.moved', [n]))),
  ];

  await _show(context, position, [top, tagging, perTag, folders, repair, delete]);
}

MediaRef _ref(FeedItem i) => MediaRef(media_id: i.media_id, path: i.path, kind: i.kind.wireValue, text: i.text);

Future<void> _toFolder(BuildContext context, LibraryModel library, {List<String> media = const [], List<String> posts = const []}) async {
  final folder = await pickFolder(context, library);
  if (folder == null || !context.mounted) return;
  runMediaAction(context, library, ActionKind.folderAdd, media: media, posts: posts, folder: folder, done: (_) => L('tags.toFolder.done', [folder]));
}

Future<void> _renameTag(BuildContext context, LibraryModel library, String label) async {
  final c = TextEditingController(text: label);
  final to = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(L('card.menu.renameTag')),
      content: TextField(contextMenuBuilder: appTextMenu, controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(L('common.done'))),
      ],
    ),
  );
  final t = to?.trim() ?? '';
  if (t.isEmpty || t == label) return;
  Core.renameTag(label, t);
  await library.refresh();
}

Future<void> _repair(BuildContext context, LibraryModel library, FeedItem item) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(L('common.redownloading')), duration: const Duration(minutes: 2)));
  String title;
  String? message;
  try {
    final r = await Core.repairAsync(item.media_id);
    (title, message) = switch (r) {
      RepairResult.replaced => (L('repair.fixed'), null),
      RepairResult.replacedNew => (L('repair.replacedNew.title'), L('repair.replacedNew.message')),
      RepairResult.fromPeers => (L('repair.fromPeers.title'), L('repair.fromPeers.message')),
    };
  } catch (e) {
    (title, message) = (L('repair.failed'), '$e');
  }
  messenger.hideCurrentSnackBar();
  await library.refresh();
  if (!context.mounted) return;
  if (message == null) {
    messenger.showSnackBar(SnackBar(content: Text(title)));
  } else {
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(title: Text(title), content: Text(message!), actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.ok')))]),
    );
  }
}

/// 标签来源: where each tag of the media came from (you, AI and which models, or both).
void _showSources(BuildContext context, LibraryModel library, FeedItem item) {
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text(L('tag.sources.title'), style: Theme.of(c).textTheme.titleLarge)),
            for (final t in item.tags)
              ListTile(
                leading: Icon(t.origin & 2 != 0 ? (t.origin & 1 != 0 ? Icons.verified : Icons.auto_awesome) : Icons.person, color: t.origin & 2 != 0 && t.origin & 1 == 0 ? scheme.tertiary : scheme.primary),
                title: Text(t.label),
                subtitle: Text([
                  t.origin & 3 == 3 ? L('tag.source.both') : (t.origin & 2 != 0 ? 'AI' : L('tag.source.me')), // i18n-exempt: "AI" as native
                  if (t.models.isNotEmpty) t.models.map((m) => library.aiModels.find(m)?.title ?? m).join(L('list.separator')),
                ].join(' · ')),
              ),
            Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Text(L('tag.sources.legend'), style: Theme.of(c).textTheme.bodySmall)),
          ]),
        ),
      );
    },
  );
}
