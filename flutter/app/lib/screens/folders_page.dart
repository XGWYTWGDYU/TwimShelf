
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../app/prefs.dart';
import '../app/places.dart';
import '../l10n/l10n.dart';
import '../widgets/core_thumbnail.dart';
import 'settings_page.dart' show SettingsIcon, SettingsSection;
import '../actions/folder_actions.dart';
import '../app/jobs.dart';
import '../widgets/text_menu.dart';
import '../platform/os.dart';

/// 文件夹: the user's folders as covers, then the media kinds and the other collections — the
/// way to every place where the window has no sidebar.
class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.library, required this.onOpen, this.foldersOnly = false});
  final LibraryModel library;
  /// Beside a sidebar the media kinds and the other collections are places of their own there:
  /// only the folders here (as the Mac's 文件夹 page).
  final bool foldersOnly;
  final void Function(Place) onOpen;

  Future<void> _newFolder(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('common.newFolder')),
        content: TextField(contextMenuBuilder: appTextMenu, controller: controller, autofocus: true, onSubmitted: (v) => Navigator.pop(c, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: Text(L('common.create'))),
        ],
      ),
    );
    final n = name?.trim() ?? '';
    if (n.isEmpty) return;
    await createFolder(n);
    await library.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final overview = library.folders;
        final folders = overview?.folders ?? const <Folder>[];
        Widget chevron() => Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant);
        return Scaffold(
          appBar: AppBar(
            title: Text(L('place.folders')),
            actions: [IconButton(tooltip: L('common.newFolder'), icon: const Icon(Icons.create_new_folder_outlined), onPressed: () => _newFolder(context))],
          ),
          body: SafeArea(
            top: false,
            bottom: false,
            child: ListView(
              padding: EdgeInsets.only(top: 4, bottom: 24 + MediaQuery.paddingOf(context).bottom),
              children: [
                SettingsSection(title: L('folders.mine'), footer: folders.isEmpty ? L('folders.empty.hint') : null, children: [
                  if (folders.isEmpty)
                    ListTile(
                      leading: const SettingsIcon(Icons.create_new_folder_outlined),
                      title: Text(L('search.noFolders')),
                      onTap: () => _newFolder(context),
                    ),
                  for (final f in folders)
                    _FolderRow(library: library, folder: f, cacheDir: '${library.directory}${OS.pathSeparator}.covers', onOpen: () => onOpen(Place.folder(f.name))),
                ]),
                if (!foldersOnly) ...[
                  SettingsSection(title: L('sidebar.mediaTypes'), children: [
                    for (final (p, n) in [(Place.photos, overview?.photos), (Place.videos, overview?.videos)])
                      ListTile(
                        key: ValueKey('kind-${p.id}'),
                        leading: SettingsIcon(p.icon, mascot: p.mascotIcon),
                        title: Text(p.title),
                        subtitle: n == null ? null : Text('$n'),
                        trailing: chevron(),
                        onTap: () => onOpen(p),
                      ),
                  ]),
                  ListenableBuilder(
                    listenable: Prefs.instance,
                    builder: (context, _) => SettingsSection(title: L('grid.more'), children: [
                      for (final p in Place.offered)
                        ListTile(
                          key: ValueKey('more-${p.id}'),
                          leading: SettingsIcon(p.icon, mascot: p.mascotIcon, danger: p == Place.bad),
                          title: Text(p.title),
                          trailing: chevron(),
                          onTap: () => onOpen(p),
                        ),
                    ]),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A folder as a row of the list: its cover, its name, how many media.
class _FolderRow extends StatelessWidget {
  const _FolderRow({required this.library, required this.folder, required this.cacheDir, required this.onOpen});
  final LibraryModel library;
  final Folder folder;
  final String cacheDir;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final f = folder;
    return GestureDetector(
      onLongPressStart: (d) => showFolderMenu(context, library, f.name, d.globalPosition),
      onSecondaryTapUp: (d) => showFolderMenu(context, library, f.name, d.globalPosition),
      child: ListTile(
        key: ValueKey('folder-${f.name}'),
        // the names in line with the rows of the other sections, whose icons are narrower
        horizontalTitleGap: 6,
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox.square(
            dimension: 48,
            child: f.cover_id == null
                ? ColoredBox(color: scheme.secondaryContainer, child: Icon(Icons.folder_outlined, color: scheme.onSecondaryContainer))
                : CoreThumbnail(mediaId: f.cover_id!, cacheDir: cacheDir, size: 48, video: f.cover_video, videoPath: f.cover_video ? f.cover_path : null),
          ),
        ),
        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(L('grid.countSuffix', [f.count]).trim()),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        onTap: onOpen,
      ),
    );
  }
}
