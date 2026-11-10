import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../app/places.dart';
import '../app/jobs.dart';
import '../l10n/l10n.dart';
import 'tag_picker.dart';
import '../widgets/text_menu.dart';

/// Menus open quickly and whole (the default fades the items in one by one).
const menuAnimation = AnimationStyle(duration: Duration(milliseconds: 120), reverseDuration: Duration(milliseconds: 80));

/// The long-press menu of a media, the same in every grid and on the cards (the native apps'
/// context menus): show its post in 浏览, tags, folders, the bin. Every change can be undone from
/// the message it leaves.
Future<void> showMediaMenu(
  BuildContext context, {
  required LibraryModel library,
  required FeedItem item,
  required Offset position,
  Place? place,
}) async {
  final inBin = place == Place.trash;
  final loose = item.post_id.startsWith('loose:');
  final folder = place?.folder;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  PopupMenuItem<VoidCallback> entry(IconData icon, String label, VoidCallback action, {String? key, bool danger = false}) => PopupMenuItem(
        key: key == null ? null : ValueKey(key),
        value: action,
        child: Row(children: [
          Icon(icon, size: 20, color: danger ? Theme.of(context).colorScheme.error : null),
          const SizedBox(width: 12),
          Flexible(child: Text(label, style: danger ? TextStyle(color: Theme.of(context).colorScheme.error) : null)),
        ]),
      );
  final chosen = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromRect(overlay.globalToLocal(position) & const Size(1, 1), Offset.zero & overlay.size),
    popUpAnimationStyle: menuAnimation,
    items: [
      if (inBin) ...[
        entry(Icons.restore, L('common.restore'), () => runMediaAction(context, library, ActionKind.restore, media: [item.media_id], done: (n) => L('trash.restored', [n]))),
        entry(Icons.delete_forever_outlined, L('common.deletePermanently'), () => purgeMedia(context, library, [item.media_id]), danger: true),
      ] else ...[
        entry(Icons.dynamic_feed_outlined, L('grid.revealPost'), () => library.reveal(item), key: 'menu-reveal'),
        entry(Icons.sell_outlined, L('card.menu.tagMedia'), () => showTagPicker(context, library, item)),
        if (!loose) entry(Icons.sell, L('card.menu.tagPost'), () => showTagPicker(context, library, item, wholePost: true)),
        entry(Icons.create_new_folder_outlined, L('common.addToFolder'), () => addToFolder(context, library, [item])),
        if (folder != null)
          entry(Icons.folder_off_outlined, L('card.menu.removeMedia'),
              () => runMediaAction(context, library, ActionKind.folderRemove, media: [item.media_id], folder: folder, done: (n) => L('common.removeFromFolder'))),
        entry(Icons.delete_outline, L('grid.trashMedia'), () => runMediaAction(context, library, ActionKind.trash, media: [item.media_id], done: (n) => L('trash.moved', [n])), danger: true),
        if (!loose)
          entry(Icons.delete_sweep_outlined, L('grid.trashPost'), () => runMediaAction(context, library, ActionKind.trash, posts: [item.post_id], done: (n) => L('trash.moved', [n])), danger: true),
      ],
    ],
  );
  chosen?.call();
}

/// Runs an action and leaves a message with 撤销.
Future<void> runMediaAction(BuildContext context, LibraryModel library, ActionKind kind,
    {List<String> media = const [], List<String> posts = const [], String? folder, required String Function(int n) done}) async {
  final messenger = ScaffoldMessenger.of(context);
  final ActionReceipt receipt;
  try {
    // a large selection takes a while: never on the thread that draws
    receipt = await Core.actionAsync(kind, media: media, posts: posts, folder: folder);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  library.refresh();
  messenger.showSnackBar(SnackBar(
    content: Text(done(receipt.changes.length)),
    // with an action a SnackBar otherwise stays until the action is used
      persist: false,
      action: SnackBarAction(
      label: L('common.undo'),
      onPressed: () {
        final n = Core.undo(receipt);
        library.refresh();
        messenger.showSnackBar(SnackBar(content: Text(L('undo.done', [n]))));
      },
    ),
  ));
}

Future<void> purgeMedia(BuildContext context, LibraryModel library, List<String> media) async {
  // what the person sees now is what the confirmation is about: a media restored and binned again
  // on another device meanwhile is a new one, and the core leaves it alone
  final snapshot = await Core.binSnapshotAsync(media: media);
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(L('trash.purgeTitle')),
      content: Text(L('trash.purgeMessage', [L('trash.moved', [media.length])])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L('common.cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: Text(L('common.deletePermanently')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final n = (await Core.actionAsync(ActionKind.purge, media: media, snapshot: snapshot)).changes.length;
  await library.refresh();
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L('trash.purged', [n]))));
}

/// Chooses a folder, or names a new one (made here); null when cancelled.
Future<String?> pickFolder(BuildContext context, LibraryModel library) async {
  final folders = library.folders?.folders ?? const <Folder>[];
  final name = TextEditingController();
  final chosen = await showDialog<String>(
    context: context,
    builder: (c) => StatefulBuilder(builder: (c, setState) {
      final typed = name.text.trim();
      return AlertDialog(
        title: Text(L('common.addToFolder')),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L('folderPicker.message'), style: Theme.of(c).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextField(contextMenuBuilder: appTextMenu, controller: name, decoration: InputDecoration(hintText: L('common.newFolder')), onChanged: (_) => setState(() {})),
            if (typed.isNotEmpty && !folders.any((f) => f.name == typed))
              ListTile(leading: const Icon(Icons.create_new_folder_outlined), title: Text(L('folderPicker.new', [typed])), onTap: () => Navigator.pop(c, typed)),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final f in folders)
                  ListTile(leading: const Icon(Icons.folder_outlined), title: Text(f.name), trailing: Text('${f.count}'), onTap: () => Navigator.pop(c, f.name)),
              ]),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel')))],
      );
    }),
  );
  if (chosen == null || chosen.isEmpty) return null;
  if (!folders.any((f) => f.name == chosen)) await createFolder(chosen);
  return chosen;
}

/// Puts media into a folder: each media's whole post (a loose media alone), as the native apps do.
Future<void> addToFolder(BuildContext context, LibraryModel library, List<FeedItem> items) async {
  final folder = await pickFolder(context, library);
  if (folder == null || !context.mounted) return;
  final loose = items.where((i) => i.post_id.startsWith('loose:')).map((i) => i.media_id).toList();
  final posts = items.where((i) => !i.post_id.startsWith('loose:')).map((i) => i.post_id).toSet().toList();
  runMediaAction(context, library, ActionKind.folderAdd, media: loose, posts: posts, folder: folder, done: (_) => L('tags.toFolder.done', [folder]));
}
