import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../platform/data_home.dart';
import '../platform/desktop_entry.dart';
import 'settings_page.dart';
import '../app/library.dart';
import 'package:tl_core/tl_core.dart';
import '../widgets/text_menu.dart';
import '../platform/os.dart';

/// First start on Windows and Linux: where the data folder goes.
class DataHomeSetupPage extends StatefulWidget {
  const DataHomeSetupPage({super.key, required this.onReady});
  final VoidCallback onReady;

  @override
  State<DataHomeSetupPage> createState() => _DataHomeSetupPageState();
}

class _DataHomeSetupPageState extends State<DataHomeSetupPage> {
  String _folder = DataHome.suggested;
  String? _error;

  Future<void> _pick() async {
    final p = await getDirectoryPath();
    if (p == null) return;
    setState(() {
      _folder = p;
      _error = DataHome.problem(p) == null ? null : L('datahome.notEmpty');
    });
  }

  Future<void> _use() async {
    if (DataHome.problem(_folder) != null) return setState(() => _error = L('datahome.notEmpty'));
    await DataHome.choose(_folder);
    widget.onReady();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.folder_special_rounded, size: 56, color: t.colorScheme.primary),
              const SizedBox(height: 16),
              Text(L('datahome.title'), style: t.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(L('datahome.message'), style: t.textTheme.bodyLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 24),
              Card(
                margin: EdgeInsets.zero,
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(_folder, key: const ValueKey('datahome-folder')),
                  subtitle: _error == null ? null : Text(_error!, style: TextStyle(color: t.colorScheme.error)),
                ),
              ),
              const SizedBox(height: 24),
              Wrap(spacing: 12, runSpacing: 12, children: [
                FilledButton(key: const ValueKey('datahome-use'), onPressed: _error == null ? _use : null, child: Text(L('datahome.useSuggested'))),
                OutlinedButton(onPressed: _pick, child: Text(L('datahome.chooseOther'))),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Settings on Windows and Linux: where the data folder is, and moving it.
class DataHomeSection extends StatefulWidget {
  const DataHomeSection({super.key, required this.library});
  final LibraryModel library;

  @override
  State<DataHomeSection> createState() => _DataHomeSectionState();
}

class _DataHomeSectionState extends State<DataHomeSection> {
  (int, int)? _progress;

  Future<void> _move() async {
    final target = await getDirectoryPath();
    if (target == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (DataHome.problem(target) != null) {
      messenger.showSnackBar(SnackBar(content: Text(L('datahome.notEmpty'))));
      return;
    }
    final old = DataHome.path!;
    try {
      await widget.library.stopWriting();
      await DataHome.moveTo(
        target,
        databaseFile: '${widget.library.directory}${OS.pathSeparator}library.sqlite',
        snapshot: (out) => coreRunAsync(() => Core.dbSnapshot(out)),
        progress: (d, n) => mounted ? setState(() => _progress = (d, n)) : null,
      );
    } catch (e) {
      if (mounted) setState(() => _progress = null);
      messenger.showSnackBar(SnackBar(content: Text(L('datahome.moveFailed', ['$e']))));
      return;
    }
    if (!mounted) return;
    setState(() => _progress = null);
    final deleteOld = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(L('datahome.setting')),
        content: Text(L('datahome.moved')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, true), child: Text(L('datahome.deleteOld'))),
          FilledButton(onPressed: () => Navigator.pop(c, false), child: Text(L('datahome.restart'))),
        ],
      ),
    );
    // the old folder goes only after the new one is in use and the person said so
    if (deleteOld == true) await _rememberDelete(target, old);
    await DataHome.restart();
  }

  /// Deleted at the next start, from the new folder (the running app still has files open in it).
  static Future<void> _rememberDelete(String target, String old) async {
    final f = File('$target${OS.pathSeparator}delete-after-move.json');
    await f.writeAsString(jsonEncode({'path': old}));
  }

  @override
  Widget build(BuildContext context) {
    final p = _progress;
    return SettingsSection(title: L('datahome.setting'), footer: L('datahome.footer'), children: [
      ListTile(leading: const Icon(Icons.folder_outlined), title: SelectableText(contextMenuBuilder: appTextMenu, DataHome.path ?? '')),
      if (p != null)
        ListTile(title: Text(L('datahome.moving', [p.$1, p.$2])), subtitle: LinearProgressIndicator(value: p.$2 == 0 ? null : p.$1 / p.$2))
      else
        ListTile(key: const ValueKey('datahome-move'), leading: const Icon(Icons.drive_file_move_outline), title: Text(L('datahome.move')), onTap: _move),
      // an AppImage: uninstalling is deleting the file; its menu entry goes here
      if (OS.isLinux && OS.environment['APPIMAGE'] != null)
        ListTile(
          leading: const Icon(Icons.playlist_remove),
          title: Text(L('linux.removeEntry')),
          onTap: () async {
            await removeDesktopEntry();
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(L('linux.removeEntry.done'))));
          },
        ),
    ]);
  }
}

/// After opening: a data-folder move that finished deletes the old folder, if the person
/// chose to.
class StartupChecks {
  static Future<void> run(BuildContext context) async {
    if (DataHome.path == null) return;
    final f = File('${DataHome.path}${OS.pathSeparator}delete-after-move.json');
    if (!f.existsSync()) return;
    try {
      await DataHome.deleteOld((jsonDecode(f.readAsStringSync()) as Map)['path'] as String);
    } catch (_) {}
    f.deleteSync();
  }
}
