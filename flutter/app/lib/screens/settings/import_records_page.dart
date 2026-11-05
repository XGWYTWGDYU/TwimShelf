import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../../actions/search_export.dart';
import '../../l10n/l10n.dart';
import '../settings_page.dart';

/// 导入记录: every import, newest first, with how many of its files did not import normally;
/// each opens its details. Records can be deleted one by one or all at once.
class ImportRecordsPage extends StatefulWidget {
  const ImportRecordsPage({super.key, required this.ownedRoots});
  /// Where the app keeps its own copies of what it imported.
  final Future<List<String>> Function() ownedRoots;

  @override
  State<ImportRecordsPage> createState() => _ImportRecordsPageState();
}

String _date(BuildContext context, DateTime d) {
  final ml = MaterialLocalizations.of(context);
  return '${ml.formatShortMonthDay(d)} ${ml.formatTimeOfDay(TimeOfDay.fromDateTime(d), alwaysUse24HourFormat: true)}';
}

String _name(String path) => path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).lastOrNull ?? path;

String _bytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB']; // i18n-exempt: unit symbols
  var v = b.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
}

/// Deletes records after asking; the app's own copies of their sources go too, never a file of
/// the user's elsewhere.
Future<bool> deleteImportRecords(BuildContext context, List<String> files, String what, {required Future<List<String>> Function() owned}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(L('mac.importHistory.deleteTitle', [what])),
      content: Text(L('import.deleteAll.message')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(L('common.cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: Text(L('common.delete')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  try {
    final r = await Core.deleteImportReportsAsync(files, owned: await owned());
    if (!context.mounted) return true;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(L('mac.importHistory.deleted', [r.reports])),
        content: Text(r.sources > 0 ? L('import.deleted.sources', [r.sources, _bytes(r.bytes)]) : L('import.deleted.freed', [_bytes(r.bytes)])),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))],
      ),
    );
  } catch (e) {
    if (!context.mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
  return true;
}

class _ImportRecordsPageState extends State<ImportRecordsPage> {
  late var _list = Core.importReports();

  void _reload() => setState(() => _list = Core.importReports());

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(L('common.importRecords'))),
        body: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
          SettingsSection(footer: L('import.history.footer'), children: [
            if (_list.isEmpty) ListTile(title: Text(L('import.history.none'))),
            for (final r in _list)
              ListTile(
                leading: SettingsIcon(r.issues == 0 ? Icons.check : Icons.report),
                title: Text('${_date(context, r.date)} · ${_name(r.source)}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(r.issues == 0 ? L('mac.importHistory.ok') : L('import.issuesCount', [r.issues])),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final ImportReport rep;
                  try {
                    rep = await Core.importReportAsync(r.file);
                  } catch (_) {
                    return;
                  }
                  if (!context.mounted) return;
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ImportReportPage(ownedRoots: widget.ownedRoots, file: r.file, report: rep)));
                  _reload();
                },
              ),
          ]),
          if (_list.isNotEmpty)
            SettingsSection(children: [
              ListTile(
                leading: const SettingsIcon(Icons.delete, danger: true),
                title: Text(L('import.deleteAll'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () async {
                  if (await deleteImportRecords(context, [for (final r in _list) r.file], L('mac.importHistory.all', [_list.length]), owned: widget.ownedRoots)) _reload();
                },
              ),
            ]),
        ]),
      );
}

/// 导入详情: what did not import normally, by kind (where it was inside the source, why, and
/// what it matches); the problem files can be exported unchanged; the record can go.
class ImportReportPage extends StatelessWidget {
  const ImportReportPage({super.key, required this.file, required this.report, required this.ownedRoots});
  final Future<List<String>> Function() ownedRoots;
  final String file;
  final ImportReport report;

  static String _category(String c) => switch (c) {
        'not_media' || 'unsupported' || 'unreadable' || 'duplicate' || 'in_bin' || 'ignored_location' || 'unsafe_path' || 'post_not_imported' || 'post_hidden' || 'post_merged' || 'post_text_truncated' =>
          L('import.cat.$c'), // i18n-exempt: keys import.cat.<category>
        _ => L('sidebar.other'),
      };

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<ImportIssue>>{};
    for (final i in report.issues) {
      groups.putIfAbsent(i.category, () => []).add(i);
    }
    final secondary = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Scaffold(
      appBar: AppBar(title: Text(L('import.details'))),
      body: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
        if (report.source != null)
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 0), child: Text(L('import.source') + _name(report.source!), style: secondary)),
        if (report.issues.isNotEmpty)
          SettingsSection(footer: L('import.export.footer'), children: [
            ListTile(
              leading: const SettingsIcon(Icons.ios_share),
              title: Text(L('import.export')),
              onTap: () async {
                final out = await outputPath(L('import.problemsZip'));
                if (out == null) return;
                try {
                  await Core.exportImportIssuesAsync(file, out);
                  await deliver(out);
                } catch (e) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
                }
              },
            ),
          ]),
        for (final e in groups.entries)
          SettingsSection(
            title: L('format.nameDetail', [_category(e.key), e.value.length]),
            footer: e.value.length > 500 ? L('import.first500') : null,
            children: [
              for (final i in e.value.take(500))
                ListTile(
                  dense: true,
                  title: Text(i.path, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(i.reason + (i.same_as == null ? '' : L('import.matches') + i.same_as!), style: secondary),
                ),
            ],
          ),
        SettingsSection(footer: L('import.delete.footer'), children: [
          ListTile(
            leading: const SettingsIcon(Icons.delete, danger: true),
            title: Text(L('import.delete'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              if (await deleteImportRecords(context, [file], L('mac.importHistory.this'), owned: ownedRoots) && context.mounted) Navigator.of(context).pop();
            },
          ),
        ]),
      ]),
    );
  }
}
