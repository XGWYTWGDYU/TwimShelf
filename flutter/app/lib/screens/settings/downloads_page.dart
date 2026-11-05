
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../../app/jobs.dart';
import '../../actions/media_actions.dart' show pickFolder;
import '../../app/library.dart';
import '../../l10n/l10n.dart';
import '../../mascot/mascot.dart';
import '../../services/downloads.dart';
import '../settings_page.dart';
import '../../widgets/text_menu.dart';

/// 下载帖子: links pasted one per line, a bookmarks JSON (Twitter Web Exporter), the download
/// method, and the running job with pause / resume / cancel — the native 下载 page.
class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.downloads, this.library, this.initialLinks = ''});
  final DownloadService downloads;
  /// What the quick download card held, carried over to this page's field.
  final String initialLinks;
  /// For the folders 放入文件夹 offers (and making a new one).
  final LibraryModel? library;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final _links = TextEditingController(text: widget.initialLinks);
  DownloadService get d => widget.downloads;

  static const _json = XTypeGroup(label: 'JSON', extensions: ['json'], uniformTypeIdentifiers: ['public.json'], mimeTypes: ['application/json']);

  @override
  void dispose() {
    _links.dispose();
    super.dispose();
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on DownloadServiceException catch (e) {
      _toast(L(e.messageKey));
    } catch (_) {
      _toast(L('common.couldNotStartDownload'));
    }
  }

  Future<void> _downloadLinks() async {
    final lines = _links.text.split(RegExp(r'\s+')).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return _toast(L('settings.links.empty'));
    await _run(() async {
      await d.startLinks(lines);
      _links.clear();
    });
  }

  /// The batch: a bookmarks JSON chosen first (how many posts it holds shows), then started with
  /// the concurrency and the interval set here, as native.
  String? _batchPath;
  String? _batchName;
  int _batchCount = 0;

  Future<void> _pickBatch() async {
    final f = await openFile(acceptedTypeGroups: const [_json]);
    if (f == null) return;
    try {
      final urls = await loadBookmarkURLs(f.path);
      setState(() {
        _batchPath = f.path;
        _batchName = f.name;
        _batchCount = urls.length;
      });
    } catch (_) {
      _toast(L('settings.links.unrecognized'));
    }
  }

  Future<void> _startBatch() async {
    final path = _batchPath;
    if (path == null) return;
    await _run(() async {
      await d.importBookmarks(path);
      await d.start();
      setState(() {
        _batchPath = null;
        _batchName = null;
        _batchCount = 0;
      });
    });
  }

  /// 放入文件夹: none, a folder, or a new one (named here).
  Future<void> _chooseFolder() async {
    final folders = widget.library?.folders?.folders ?? const <Folder>[];
    final chosen = await showDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(L('settings.intoFolder')),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(c, ''), child: Text(L('common.notIntoFolder'))),
          for (final f in folders) SimpleDialogOption(onPressed: () => Navigator.pop(c, f.name), child: Text(f.name)),
          SimpleDialogOption(onPressed: () => Navigator.pop(c, '\u0000new'), child: Text(L('common.newFolderEllipsis'))),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    var name = chosen;
    if (chosen == '\u0000new') {
      final lib = widget.library;
      if (lib == null) return;
      name = await pickFolder(context, lib) ?? '';
      if (name.isEmpty) return;
    }
    setState(() => d.folder = name.isEmpty ? null : name);
  }

  String _summary(DownloadStatus s) =>
      L('activity.downloadSummary', [s.done, s.skipped, s.failed, s.total]);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: d,
        builder: (context, _) {
          final s = d.status;
          final phase = d.phase;
          final busy = phase == DownloadPhase.running || phase == DownloadPhase.queued || phase == DownloadPhase.pausing;
          final text = Theme.of(context).textTheme;
          return Scaffold(
            appBar: AppBar(title: Text(L('common.downloadPosts'))),
            body: SafeArea(
              top: false,
              bottom: false,
              child: ListView(padding: EdgeInsets.only(top: 8, bottom: 8 + MediaQuery.paddingOf(context).bottom), children: [
                if (s != null || phase != DownloadPhase.idle)
                  SettingsSection(title: L('settings.downloadStatus'), footer: phase == DownloadPhase.paused ? L('settings.paused.footer') : null, children: [
                    ListTile(
                      key: const ValueKey('download-status'),
                      leading: busy ? const MascotIcon('bag', size: 30, fallback: SizedBox.shrink()) : null,
                      title: Text(switch (phase) {
                        DownloadPhase.running || DownloadPhase.queued => L('settings.downloading'),
                        DownloadPhase.paused || DownloadPhase.pausing => L('download.paused'),
                        DownloadPhase.cancelled || DownloadPhase.cancelling => L('download.cancelled'),
                        DownloadPhase.failed => L('download.partial'),
                        DownloadPhase.idle => s == null ? L('download.notYet') : L('download.done'),
                      }),
                      subtitle: s == null ? null : Text(_summary(s)),
                    ),
                    if (busy && s != null && s.total > 0)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: LinearProgressIndicator(value: (s.done + s.skipped + s.failed) / s.total),
                      ),
                    if (d.errorKey != null) ListTile(leading: const Icon(Icons.error_outline), title: Text(L(d.errorKey!))),
                    if (busy)
                      ListTile(leading: const Icon(Icons.pause), title: Text(L('settings.pause')), onTap: () => _run(d.pause)),
                    if (phase == DownloadPhase.paused)
                      ListTile(leading: const Icon(Icons.play_arrow), title: Text(L('settings.resume')), onTap: () => _run(d.resume)),
                    if (busy || phase == DownloadPhase.paused)
                      ListTile(
                        leading: Icon(Icons.cancel_outlined, color: Theme.of(context).colorScheme.error),
                        title: Text(L('settings.cancelDownload'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        onTap: () => _run(d.cancel),
                      ),
                    if (s != null && s.errors.isNotEmpty)
                      ExpansionTile(
                        title: Text(L('settings.viewFailed')),
                        children: [
                          for (final e in s.errors)
                            ListTile(dense: true, title: SelectableText(contextMenuBuilder: appTextMenu, e.first), subtitle: e.length > 1 ? Text(e.sublist(1).join(' · ')) : null),
                        ],
                      ),
                  ]),
                SettingsSection(title: L('settings.section.method'), footer: L('settings.method.footer'), children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SegmentedButton<DownloadRoute>(
                      segments: [
                        ButtonSegment(value: DownloadRoute.auto, label: Text(L('common.auto'))),
                        ButtonSegment(value: DownloadRoute.fx, label: Text(L('settings.method.fx'))),
                        ButtonSegment(value: DownloadRoute.cookie, label: Text(L('settings.method.cookie'))),
                      ],
                      selected: {d.route},
                      onSelectionChanged: (v) => d.route = v.first,
                    ),
                  ),
                  ListTile(
                    key: const ValueKey('download-folder'),
                    leading: const SettingsIcon(Icons.folder),
                    title: Text(L('settings.intoFolder')),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(d.folder ?? L('common.notIntoFolder')),
                      const Icon(Icons.unfold_more, size: 18),
                    ]),
                    onTap: _chooseFolder,
                  ),
                ]),
                SettingsSection(title: L('common.download'), footer: L('settings.links.footer'), children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: TextField(contextMenuBuilder: appTextMenu, 
                      key: const ValueKey('download-links'),
                      controller: _links,
                      minLines: 3,
                      maxLines: 8,
                      keyboardType: TextInputType.multiline,
                      style: text.bodyMedium,
                      decoration: InputDecoration(hintText: L('settings.links.placeholder'), border: const OutlineInputBorder()),
                    ),
                  ),
                  ListTile(key: const ValueKey('download-start'), leading: const Icon(Icons.download), title: Text(L('common.download')), onTap: _downloadLinks),
                ]),
                SettingsSection(title: L('settings.batch'), footer: L('settings.batch.footer'), children: [
                  ListTile(
                    key: const ValueKey('batch-pick'),
                    leading: const SettingsIcon(Icons.note_add),
                    title: Text(_batchName == null ? L('settings.batch.pick') : L('settings.batch.loaded', [_batchName!])),
                    onTap: _pickBatch,
                  ),
                  ListTile(
                    leading: const SettingsIcon(Icons.numbers),
                    title: Text(L('settings.batch.posts')),
                    trailing: Text(_batchPath == null ? '—' : '$_batchCount'),
                  ),
                  _Stepper(
                    icon: const SettingsIcon(Icons.call_split),
                    title: L('settings.batch.concurrency'),
                    value: '${d.concurrency}',
                    onMinus: d.concurrency > 1 ? () => setState(() => d.concurrency--) : null,
                    onPlus: d.concurrency < 16 ? () => setState(() => d.concurrency++) : null,
                  ),
                  _Stepper(
                    icon: const SettingsIcon(Icons.timer),
                    title: L('settings.batch.interval'),
                    value: L('settings.batch.seconds', [d.intervalMs / 1000]),
                    onMinus: d.intervalMs > 0 ? () => setState(() => d.intervalMs = (d.intervalMs - 250).clamp(0, 10000)) : null,
                    onPlus: d.intervalMs < 10000 ? () => setState(() => d.intervalMs = (d.intervalMs + 250).clamp(0, 10000)) : null,
                  ),
                  ListTile(
                    key: const ValueKey('batch-start'),
                    enabled: _batchCount > 0,
                    leading: SettingsIcon(Icons.download_for_offline),
                    title: Text(L('settings.batch.start')),
                    onTap: _batchCount > 0 ? _startBatch : null,
                  ),
                ]),
                // the account Cookie that locked accounts' posts need, here as in the native apps
                const CookieSection(),
              ]),
            ),
          );
        },
      );
}

/// A value with − and + (the native stepper rows).
class _Stepper extends StatelessWidget {
  const _Stepper({required this.icon, required this.title, required this.value, this.onMinus, this.onPlus});
  final Widget icon;
  final String title;
  final String value;
  final VoidCallback? onMinus, onPlus;
  @override
  Widget build(BuildContext context) => ListTile(
        leading: icon,
        title: Text(title),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(value, style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
          const SizedBox(width: 8),
          IconButton.filledTonal(visualDensity: VisualDensity.compact, icon: const Icon(Icons.remove), onPressed: onMinus),
          IconButton.filledTonal(visualDensity: VisualDensity.compact, icon: const Icon(Icons.add), onPressed: onPlus),
        ]),
      );
}
