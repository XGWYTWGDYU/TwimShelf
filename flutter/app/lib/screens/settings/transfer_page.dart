import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';

import '../../actions/search_export.dart';
import '../../app/jobs.dart';
import '../../app/library.dart';
import '../../l10n/l10n.dart';
import 'import_records_page.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';

/// 导入与备份: old-format ZIPs (a folder per post), ZIPs of loose media, .tlpack export packs,
/// and a backup of the whole library.
class TransferPage extends StatelessWidget {
  const TransferPage({super.key, required this.library});
  final LibraryModel library;

  static const _zip = XTypeGroup(label: 'ZIP', extensions: ['zip'], uniformTypeIdentifiers: ['public.zip-archive'], mimeTypes: ['application/zip']);
  static const _pack = XTypeGroup(label: 'tlpack', extensions: ['tlpack'], uniformTypeIdentifiers: ['public.data'], mimeTypes: ['application/octet-stream']);

  /// 导入到文件夹？ as native: an existing one, a new one named after the file by default, or none
  /// (an empty name). Null when cancelled.
  Future<String?> _askFolder(BuildContext context, String suggested) {
    final name = TextEditingController();
    final folders = [for (final f in library.folders?.folders ?? const <Folder>[]) f.name];
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('common.importToFolder')),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(key: const ValueKey('importNoFolder'), contentPadding: EdgeInsets.zero, leading: const Icon(Icons.block), title: Text(L('share.noFolder')), onTap: () => Navigator.pop(c, '')),
              for (final f in folders) ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.folder_outlined), title: Text(f, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(c, f)),
              TextField(contextMenuBuilder: appTextMenu, key: const ValueKey('importNewFolder'), controller: name, decoration: InputDecoration(labelText: L('share.newFolder'), hintText: suggested)),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.cancel'))),
          FilledButton(onPressed: () => Navigator.pop(c, name.text.trim().isEmpty ? suggested : name.text.trim()), child: Text(L('share.import'))),
        ],
      ),
    );
  }

  Future<void> _import(BuildContext context, XTypeGroup type, Future<ImportReport> Function(String path, String folder) run) async {
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file == null || !context.mounted) return;
    final name = file.name.contains('.') ? file.name.substring(0, file.name.lastIndexOf('.')) : file.name;
    final folder = await _askFolder(context, name);
    if (folder == null || !context.mounted) return;
    if (folder.isNotEmpty) {
      try {
        await createFolder(folder);
      } on CoreError {
        // it is there already; a real problem shows when the import uses it
      }
    }
    if (!context.mounted) return;
    final report = await withProgress<ImportReport>(context, L('common.importing'), run(file.path, folder), () async {
      final p = await Core.importStatusAsync();
      return p == null || p.folders_total == 0 ? null : p.folders_done / p.folders_total;
    }, cancel: Core.cancelImportAsync);
    await library.refresh();
    if (!context.mounted || report == null) return;
    final text = L('import.summary.added', [report.posts, report.media]).trim() +
        (report.skipped.isEmpty ? L('import.summary.allOK') : L('import.summary.canView'));
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('import.done')),
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))],
      ),
    );
  }

  Future<void> _backup(BuildContext context) async {
    final now = DateTime.now();
    final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)} ${_two(now.hour)}.${_two(now.minute)}';
    final name = '${L('settings.backup.fileName', [stamp])}.tlpack';
    // iOS has no folder picker here: a temporary file, handed on with the share sheet afterwards
    final String out;
    if (Platform.isIOS) {
      out = '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$name';
    } else {
      final dir = await getDirectoryPath();
      if (dir == null) return;
      out = '$dir${Platform.pathSeparator}$name';
    }
    if (!context.mounted) return;
    final report = await withProgress<ExportReport>(context, L('settings.backup.running'), Core.exportBackupAsync(out), () async {
      final p = await Core.exportStatusAsync();
      return p == null || p.total == 0 ? null : p.done / p.total;
    }, cancel: Core.cancelExportAsync);
    if (!context.mounted || report == null) return;
    if (Platform.isIOS) await deliver(out);
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(report.skipped.isEmpty ? L('settings.backup.done') : L('settings.backup.doneIncomplete')),
        content: Text(L('settings.backup.result', [report.posts, report.media, report.trashed, _size(report.bytes), out]) +
            (report.skipped.isEmpty ? '' : L('settings.backup.skipped', [report.skipped.length]))),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _size(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1000 && i < units.length - 1) {
      v /= 1000;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  /// Shows a progress dialog while [work] runs (the fraction polled from the core; null =
  /// indeterminate) and returns its result, or null after showing the error.
  /// The dialog sits on the root navigator, above the shell's own ones (this page lives in one),
  /// so it is closed by its route: a pop on this page's navigator would close something else and
  /// leave the dialog behind the result.
  static Future<T?> withProgress<T>(BuildContext context, String title, Future<T> work, Future<double?> Function() progress, {Future<Object?> Function()? cancel}) async {
    final value = ValueNotifier<double?>(null);
    final poll = Timer.periodic(const Duration(milliseconds: 500), (_) async => value.value = await progress());
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<double?>(valueListenable: value, builder: (_, v, _) => LinearProgressIndicator(value: v)),
        // what is done so far stays; the report says what was not
        actions: [if (cancel != null) TextButton(key: const ValueKey('progressCancel'), onPressed: () => unawaited(cancel()), child: Text(L('common.cancel')))],
      ),
    );
    unawaited(navigator.push(route));
    void close() {
      if (route.isActive) navigator.removeRoute(route);
    }
    try {
      return await work;
    } catch (e) {
      close();
      if (context.mounted) {
        await showDialog<void>(context: context, builder: (c) => AlertDialog(content: Text('$e'), actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))]));
      }
      return null;
    } finally {
      poll.cancel();
      close();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(L('common.importAndBackup'))),
        body: ListView(padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom), children: [
          SettingsSection(title: L('common.import'), footer: L('settings.import.footer'), children: [
            ListTile(leading: const Icon(Icons.archive_outlined), title: Text(L('settings.import.legacy')), onTap: () => _import(context, _zip, (p, f) => Core.importLegacyZipAsync(p, f))),
            ListTile(leading: const Icon(Icons.crop_free), title: Text(L('settings.import.loose')), onTap: () => _import(context, _zip, (p, f) => Core.importLooseZipAsync(p, f))),
            ListTile(leading: const Icon(Icons.inventory_2_outlined), title: Text(L('settings.import.pack')), onTap: () => _import(context, _pack, (p, f) => Core.importPackAsync(p, f))),
            ListTile(
              key: const ValueKey('importRecords'),
              leading: const Icon(Icons.list_alt),
              title: Text(L('common.importRecords')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImportRecordsPage(ownedRoots: library.shares.ownedRoots))),
            ),
          ]),
          SettingsSection(title: L('common.backup'), footer: L('settings.backup.footer'), children: [
            ListTile(leading: const Icon(Icons.backup_outlined), title: Text(L('settings.backup.button')), onTap: () => _backup(context)),
          ]),
        ]),
      );
}
