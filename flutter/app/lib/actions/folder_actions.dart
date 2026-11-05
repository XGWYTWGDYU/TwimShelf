import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../l10n/l10n.dart';
import 'media_actions.dart' show menuAnimation;
import 'search_export.dart' show exportToFile;
import '../widgets/text_menu.dart';

/// 重命名文件夹: a name another folder has merges the two, after asking (as native).
Future<void> renameFolder(BuildContext context, LibraryModel library, String name, {VoidCallback? onDone}) async {
  final c = TextEditingController(text: name);
  final to = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(L('folder.rename.title')),
      content: TextField(contextMenuBuilder: appTextMenu, controller: c, autofocus: true, decoration: InputDecoration(hintText: L('common.folderName')), onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: Text(L('common.rename'))),
      ],
    ),
  );
  final next = to?.trim() ?? '';
  if (next.isEmpty || next == name || !context.mounted) return;
  if (library.folders?.folders.any((f) => f.name == next) ?? false) {
    final merge = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(L('folder.merge.title', [next])),
        content: Text(L('folder.merge.message', [next, name, name])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L('folder.merge'))),
        ],
      ),
    );
    if (merge != true || !context.mounted) return;
  }
  try {
    Core.renameFolder(name, next);
  } catch (e) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (d) => AlertDialog(title: Text(L('common.couldNotRename')), content: Text('$e'), actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.ok')))]),
    );
    return;
  }
  await library.refresh();
  onDone?.call();
}

/// 删除文件夹: the folder goes, its media stay in the library.
Future<void> deleteFolder(BuildContext context, LibraryModel library, String name, {VoidCallback? onDone}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(L('folder.delete.title', [name])),
      content: Text(L('folder.delete.message')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L('common.cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(d).colorScheme.error),
          onPressed: () => Navigator.pop(d, true),
          child: Text(L('folder.delete.confirm')),
        ),
      ],
    ),
  );
  if (ok != true) return;
  Core.deleteFolder(name);
  await library.refresh();
  onDone?.call();
}

/// What a long press or a right click on a folder offers, as the native apps'.
Future<void> showFolderMenu(BuildContext context, LibraryModel library, String name, Offset at, {VoidCallback? onRenamed, VoidCallback? onDeleted}) async {
  PopupMenuItem<VoidCallback> e(IconData icon, String label, VoidCallback action, {bool danger = false, String? key}) => PopupMenuItem(
        key: key == null ? null : ValueKey(key),
        value: action,
        child: Row(children: [
          Icon(icon, size: 20, color: danger ? Theme.of(context).colorScheme.error : null),
          const SizedBox(width: 12),
          Flexible(child: Text(label, style: danger ? TextStyle(color: Theme.of(context).colorScheme.error) : null)),
        ]),
      );
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final chosen = await showMenu<VoidCallback>(
    context: context,
    popUpAnimationStyle: menuAnimation,
    position: RelativeRect.fromRect(at & Size.zero, Offset.zero & overlay.size),
    items: [
      e(Icons.view_agenda_outlined, L('grid.revealMedia'), () => library.showInBrowse(FeedFilter(folder: name)), key: 'folderMenu-reveal'),
      e(Icons.folder_zip_outlined, L('folder.exportZip'), () => exportToFile(context, Core.mediaIdsInFolder(name), ExportOptions(tags: false, folders: false, media_only: true), '${name.replaceAll('/', '_')}.zip'), key: 'folderMenu-export'),
      e(Icons.edit_outlined, L('folder.renameEllipsis'), () => renameFolder(context, library, name, onDone: onRenamed), key: 'folderMenu-rename'),
      const PopupMenuDivider(),
      e(Icons.delete_outline, L('folder.deleteEllipsis'), () => deleteFolder(context, library, name, onDone: onDeleted), danger: true, key: 'folderMenu-delete'),
    ],
  );
  if (context.mounted) chosen?.call();
}
