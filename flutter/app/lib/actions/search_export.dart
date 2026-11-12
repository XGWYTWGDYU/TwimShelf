
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tl_core/tl_core.dart';

import '../l10n/l10n.dart';
import '../platform/apple_platform.dart';
import '../platform/os.dart';
import '../platform/files.dart';
import '../widgets/haptics.dart';

/// 导出搜索结果, as the native button beside the search field: the media of the current result
/// as a .tlpack (with their posts, and tags and folder memberships if chosen) or a plain zip of
/// the media. Desktops save where the user chooses; phones and tablets hand the file on (save to
/// Files, AirDrop, another app).
Future<void> exportSearchResult(BuildContext context, List<FeedItem> items, {List<String> terms = const []}) async {
  final prefs = await SharedPreferences.getInstance();
  if (!context.mounted) return;
  final ids = [for (final i in items) i.media_id];
  final go = await showDialog<bool>(context: context, builder: (c) => _ExportDialog(count: ids.length, prefs: prefs));
  if (go != true || !context.mounted) return;
  final mediaOnly = prefs.getBool('export.mediaOnly') ?? false;
  final options = mediaOnly
      ? ExportOptions(tags: false, folders: false, media_only: true)
      : ExportOptions(tags: prefs.getBool('export.tags') ?? true, folders: prefs.getBool('export.folders') ?? true);
  final name = '${searchExportName(terms)}.${mediaOnly ? 'zip' : 'tlpack'}';
  await exportToFile(context, ids, options, name);
}

/// "<app> 猫咪搜索结果": only the words searched for, not conditions or words left out; what no
/// system accepts in a file name goes.
String searchExportName(List<String> terms) {
  final words = terms.map((t) => t.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ').trim()).where((t) => t.isNotEmpty).join(' ');
  return words.isEmpty ? L('export.search.fileNameAll') : L('export.search.fileName', [words]);
}

/// Exports [ids] with [options] to a file named [name]: saved where the user chooses on a
/// desktop, handed on (Files, AirDrop, another app) on phones and tablets; then what was
/// exported and what was left out, with each media's reason.
Future<void> exportToFile(BuildContext context, List<String> ids, ExportOptions options, String name) async {
  final desktop = OS.isMacOS || OS.isWindows || OS.isLinux;
  String path;
  if (desktop) {
    final loc = await getSaveLocation(suggestedName: name);
    if (loc == null) return;
    path = loc.path;
  } else {
    path = '${(await getTemporaryDirectory()).path}${OS.pathSeparator}$name';
  }
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(content: Text(L('export.running', [ids.length])), duration: const Duration(minutes: 10)));
  ExportReport report;
  try {
    report = await Core.exportMediaAsync(ids, path, options: options);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text('$e')));
    return;
  }
  messenger.hideCurrentSnackBar();
  if (!desktop) await deliver(path);
  if (!context.mounted) return;
  final skipped = report.skipped;
  var more = '';
  if (skipped.isNotEmpty) {
    more = L('export.skipped', [skipped.length]);
    for (final s in skipped.take(15)) {
      more += L('export.skip.line', [s.post_id.startsWith('loose:') ? L('card.loose') : L('common.post', [s.post_id]), s.media_id.length > 10 ? s.media_id.substring(0, 10) : s.media_id, s.reason]);
    }
    if (skipped.length > 15) more += L('export.skip.more', [skipped.length - 15]);
  }
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(more.isEmpty ? L('export.done') : L('export.doneIncomplete')),
      content: SingleChildScrollView(child: Text(L('export.summary', [report.posts, report.media, _bytes(report.bytes)]) + (more.isEmpty ? '' : '\n\n$more'))),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(L('common.ok')))],
    ),
  );
}

String _bytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB']; // i18n-exempt: unit symbols
  var v = b.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return '${v.toStringAsFixed(u == 0 ? 0 : 1)} ${units[u]}';
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.count, required this.prefs});
  final int count;
  final SharedPreferences prefs;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  SharedPreferences get p => widget.prefs;
  late bool tags = p.getBool('export.tags') ?? true;
  late bool folders = p.getBool('export.folders') ?? true;
  late bool mediaOnly = p.getBool('export.mediaOnly') ?? false;

  Widget _row(String title, String detail, bool value, ValueChanged<bool>? onChanged) => Opacity(
        opacity: onChanged == null ? 0.55 : 1,
        child: SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(title), subtitle: Text(detail), value: value, onChanged: withHaptic(onChanged)),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(L('export.search.title')),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.count == 0 ? L('export.search.none') : mediaOnly ? L('export.search.countMedia', [widget.count]) : L('export.search.countWithPosts', [widget.count]),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            // with 以纯媒体导出 on, these two show as off and cannot be changed
            _row(L('export.option.tags'), L('export.option.tags.detail'), tags && !mediaOnly, mediaOnly ? null : (v) {
              setState(() => tags = v);
              p.setBool('export.tags', v);
            }),
            _row(L('export.option.folders'), L('export.option.folders.detail'), folders && !mediaOnly, mediaOnly ? null : (v) {
              setState(() => folders = v);
              p.setBool('export.folders', v);
            }),
            const Divider(),
            _row(L('export.option.mediaOnly'), L('export.option.mediaOnly.detail'), mediaOnly, (v) {
              setState(() => mediaOnly = v);
              p.setBool('export.mediaOnly', v);
            }),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(L('common.cancel'))),
          FilledButton(key: const ValueKey('searchExportGo'), onPressed: widget.count == 0 ? null : () => Navigator.pop(context, true), child: Text(L('export.go'))),
        ],
      );
}

/// Where a file the user asked for goes: a place chosen in a save dialog on a desktop, the
/// temporary folder (then the share sheet) on phones and tablets. Null when cancelled.
Future<String?> outputPath(String name) async {
  if (OS.isMacOS || OS.isWindows || OS.isLinux) return (await getSaveLocation(suggestedName: name))?.path;
  return '${(await getTemporaryDirectory()).path}${OS.pathSeparator}$name';
}

/// After writing to an [outputPath]: on phones and tablets the file is handed on.
Future<void> deliver(String path) async {
  // the web build: the browser downloads it from the server
  if (OS.isWeb) return downloadToBrowser(path);
  if (OS.isMacOS || OS.isWindows || OS.isLinux) return;
  if (!await ApplePlatform.instance.share([path])) await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
}
