import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tl_core/tl_core.dart';
import 'package:tl_native/tl_native.dart';

import '../../app/jobs.dart';
import '../../app/library.dart';
import '../../l10n/l10n.dart';
import '../settings_page.dart';
import 'ai_page.dart';
import '../../widgets/text_menu.dart';
import '../../platform/os.dart';

/// 设置 → 存储空间: what the app takes on this device, as a bar of its parts and a list that says
/// what each part holds. The same groups and the same actions as the native apps': how it compares
/// with the free space, clearing what can be made again or was asked to go, managing the models.
class StoragePage extends StatefulWidget {
  const StoragePage({super.key, required this.library});
  final LibraryModel library;

  @override
  State<StoragePage> createState() => _StoragePageState();
}

/// The app's own places for the core: itself, the thumbnails, the caches without them.
Future<Map<String, List<String>>> storagePlaces(String thumbnails) async {
  final app = await TlNative.appPaths();
  final places = <String, List<String>>{
    // desktops: the folder the program was installed into
    'app': app.isNotEmpty ? app : [File(OS.resolvedExecutable).parent.path],
    'thumbnails': [thumbnails],
    'cache': [],
  };
  final sep = OS.pathSeparator;
  final thumbPath = Directory(thumbnails).absolute.path;
  // on a desktop the temporary folder is shared with every other program of this user: not ours to count
  final phone = OS.isIOS || OS.isAndroid;
  for (final dir in [await getApplicationCacheDirectory(), if (phone) await getTemporaryDirectory()]) {
    if (!dir.existsSync()) continue;
    // a cache folder holding the thumbnails: its other entries, so nothing counts twice
    if (thumbPath.startsWith('${dir.absolute.path}$sep')) {
      for (final e in dir.listSync(followLinks: false)) {
        if (!thumbPath.startsWith(e.absolute.path)) places['cache']!.add(e.path);
      }
    } else if (!places['cache']!.contains(dir.path)) {
      places['cache']!.add(dir.path);
    }
  }
  return places;
}

/// The groups this page may clear; everything else is the library or the app itself. The bin is
/// permanent, so it starts unticked.
const clearableStorage = {'thumbnails', 'cache', 'bin'};
const _selectedAtFirst = {'thumbnails', 'cache'};

/// What could not be cleared, and why.
typedef StorageSkip = ({String path, String reason});

/// Clears the files of [keys] among [places], off the main thread, and gives back what stayed.
/// Thumbnails: the files only, the running grid keeps writing into its folders. The cache: files
/// touched in the last hour stay, a share or an export may be using them. The bin is the core's
/// (the caller's) to empty. [recentReason] is the wording for those left because they are recent.
Future<List<StorageSkip>> clearStorageFiles(Set<String> keys, Map<String, List<String>> places, {required String recentReason}) => coreRunAsync(() {
      final skipped = <StorageSkip>[];
      final recent = DateTime.now().subtract(const Duration(hours: 1));
      void remove(FileSystemEntity e, {bool keepRecent = false}) {
        try {
          if (keepRecent && e.statSync().modified.isAfter(recent)) {
            skipped.add((path: e.path, reason: recentReason));
            return;
          }
          e.deleteSync(recursive: true);
        } on FileSystemException catch (error) {
          skipped.add((path: e.path, reason: error.osError?.message ?? error.message));
        }
      }

      for (final key in keys.intersection(clearableStorage)) {
        for (final place in places[key] ?? const <String>[]) {
          final type = FileSystemEntity.typeSync(place, followLinks: false);
          if (type == FileSystemEntityType.notFound) continue;
          // the caches folder's entries may be listed one by one: an entry may be a file
          if (type != FileSystemEntityType.directory) {
            remove(File(place), keepRecent: key == 'cache');
          } else if (key == 'thumbnails') {
            for (final e in Directory(place).listSync(recursive: true, followLinks: false).whereType<File>()) {
              remove(e);
            }
          } else {
            for (final e in Directory(place).listSync(followLinks: false)) {
              remove(e, keepRecent: key == 'cache');
            }
          }
        }
      }
      return skipped;
    });

class _StoragePageState extends State<StoragePage> {
  StorageUsage? _usage;
  Object? _error;
  final _selected = {..._selectedAtFirst};
  bool _clearing = false;

  /// The parts by what a person does with them, each with its colour and symbol.
  static const _sections = [
    ('storage.section.aiAndApp', ['models', 'app']),
    ('storage.section.library', ['database', 'photos', 'videos', 'libraryOther']),
    ('storage.section.free', ['bin', 'thumbnails', 'cache']),
  ];
  static const _looks = {
    'models': (Color(0xFF7E57C2), Icons.auto_awesome_outlined),
    'app': (Color(0xFF5C6BC0), Icons.terminal_outlined),
    'database': (Color(0xFF42A5F5), Icons.storage_rounded),
    'photos': (Color(0xFFFFA726), Icons.image_outlined),
    'videos': (Color(0xFFEF5350), Icons.videocam_outlined),
    'libraryOther': (Color(0xFF26A69A), Icons.sync_alt_rounded),
    'bin': (Color(0xFF8D6E63), Icons.delete_outline_rounded),
    'thumbnails': (Color(0xFF66BB6A), Icons.grid_view_rounded),
    'cache': (Color(0xFF78909C), Icons.cached_rounded),
  };
  static (Color, IconData) _look(String key) => _looks[key] ?? (Colors.blueGrey, Icons.folder_outlined);

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    setState(() {
      _usage = null;
      _error = null;
    });
    try {
      final places = await storagePlaces(widget.library.thumbs.cacheDir);
      final u = await loadStorageUsage(places);
      if (mounted) {
        setState(() => _usage = u);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  List<StorageGroup> _chosen(StorageUsage u) => u.groups.where((g) => g.bytes > 0 && clearableStorage.contains(g.key) && _selected.contains(g.key)).toList();

  Future<void> _confirmClear(StorageUsage u) async {
    final size = _chosen(u).fold<int>(0, (a, g) => a + g.bytes);
    final bin = _selected.contains('bin') && _chosen(u).any((g) => g.key == 'bin');
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(L('storage.clear.title')),
        content: Text([L('storage.clear.message', [_bytes(size)]), if (bin) L('storage.clear.binWarning')].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(L('common.cancel'))),
          FilledButton(key: const ValueKey('storage-clear-confirm'), style: FilledButton.styleFrom(backgroundColor: Theme.of(dialog).colorScheme.error, foregroundColor: Theme.of(dialog).colorScheme.onError), onPressed: () => Navigator.pop(dialog, true), child: Text(L('storage.clear.confirm'))),
        ],
      ),
    );
    if (yes == true) await _clear(u);
  }

  Future<void> _clear(StorageUsage u) async {
    final keys = _chosen(u).map((g) => g.key).toSet();
    setState(() => _clearing = true);
    final places = await storagePlaces(widget.library.thumbs.cacheDir);
    final skipped = await clearStorageFiles(keys, places, recentReason: L('storage.clear.recent'));
    if (keys.contains('bin')) {
      try {
        await emptyTrashOff();
        await widget.library.refresh();
      } catch (e) {
        skipped.add((path: L('storage.group.bin'), reason: '$e'));
      }
    }
    await _measure();
    if (!mounted) return;
    setState(() => _clearing = false);
    final after = _usage?.total ?? u.total;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(L('storage.clear.done', [_bytes(u.total > after ? u.total - after : 0)])),
        content: skipped.isEmpty
            ? null
            : SingleChildScrollView(child: SelectableText(contextMenuBuilder: appTextMenu, [L('storage.clear.skipped'), for (final s in skipped) '${s.path}\n${s.reason}'].join('\n\n'))),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(L('common.ok')))],
      ),
    );
  }

  static String _bytes(int b) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB']; // i18n-exempt: unit symbols
    var v = b.toDouble();
    var u = 0;
    while (v >= 1000 && u < units.length - 1) {
      v /= 1000;
      u++;
    }
    return '${u == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final u = _usage;
    return Scaffold(
      appBar: AppBar(title: Text(L('storage.title'))),
      body: SafeArea(
        top: false,
        bottom: false,
        child: u == null
            ? SettingsSection(footer: L('storage.footer'), children: [
                ListTile(
                  key: const ValueKey('storage-state'),
                  leading: _error == null ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(Icons.error_outline, color: scheme.error),
                  title: Text(_error == null ? L('storage.measuring') : L('storage.failed', ['$_error'])),
                ),
              ])
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: ListView(padding: EdgeInsets.fromLTRB(24, 16, 24, 16 + MediaQuery.paddingOf(context).bottom), children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_bytes(u.total), key: const ValueKey('storage-total'), style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w800, color: scheme.onSurface)),
                        const SizedBox(height: 12),
                        _SegmentBar(groups: u.groups, height: 10),
                        const SizedBox(height: 12),
                        Text(
                          L('storage.footer'),
                          key: const ValueKey('storage-summary'),
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ]),
                    ),
                    for (final (title, keys) in _sections) _section(context, u, title, keys),
                    Center(child: TextButton.icon(onPressed: _measure, icon: const Icon(Icons.refresh, size: 18), label: Text(L('storage.refresh')))),
                  ]),
                ),
              ),
      ),
    );
  }

  /// A heading with the section's total, then its parts as joined cards, largest first.
  Widget _section(BuildContext context, StorageUsage u, String title, List<String> keys) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final parts = u.groups.where((g) => keys.contains(g.key)).toList()..sort((a, b) => b.bytes.compareTo(a.bytes));
    if (parts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(children: [
            Expanded(child: Text(L(title), style: theme.textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700))), // i18n-exempt: keys from _sections
            Text(_bytes(parts.fold(0, (a, g) => a + g.bytes)), style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
        for (var i = 0; i < parts.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 3),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.vertical(top: Radius.circular(i == 0 ? 24 : 6), bottom: Radius.circular(i == parts.length - 1 ? 24 : 6)),
            ),
            child: _row(context, parts[i]),
          ),
        if (title == 'storage.section.free') _clearButton(context, u),
      ]),
    );
  }

  Widget _clearButton(BuildContext context, StorageUsage u) {
    final size = _chosen(u).fold<int>(0, (a, g) => a + g.bytes);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const ValueKey('storage-clear'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
          onPressed: size == 0 || _clearing ? null : () => _confirmClear(u),
          child: Text(size > 0 ? '${L('storage.clear.selected')}  ${_bytes(size)}' : L('storage.clear.selected')),
        ),
      ),
    );
  }

  /// A round tick in the part's colour.
  Widget _tick(StorageGroup g, Color color) {
    final on = _selected.contains(g.key);
    return Semantics(
      checked: on,
      label: L('storage.group.${g.key}'), // i18n-exempt: keys storage.group.<key>
      button: true,
      child: InkResponse(
        key: ValueKey('storage-tick-${g.key}'),
        radius: 22,
        onTap: _clearing ? null : () => setState(() => on ? _selected.remove(g.key) : _selected.add(g.key)),
        child: SizedBox.square(
          dimension: 36,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 24,
              height: 24,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? color : Colors.transparent, border: Border.all(color: on ? color : Theme.of(context).colorScheme.outline, width: 1.5)),
              child: on ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, StorageGroup g) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (color, icon) = _look(g.key);
    return Padding(
      key: ValueKey('storage-${g.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (clearableStorage.contains(g.key))
          _tick(g, color)
        else
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, size: 20, color: color),
          ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(L('storage.group.${g.key}'), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)), // i18n-exempt: keys storage.group.<key>
            const SizedBox(height: 2),
            Text(
              [
                L('storage.group.${g.key}.detail'), // i18n-exempt: keys storage.group.<key>.detail
                if (g.files > 0 && g.key != 'app') L('storage.files', [g.files]),
              ].join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ]),
        ),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_bytes(g.bytes), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          if (g.key == 'models')
            TextButton(
              key: const ValueKey('storage-manageModels'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute(builder: (_) => AiPage(models: widget.library.aiModels, ai: widget.library.ai, tagger: widget.library.tagger, sync: widget.library.sync)));
                _measure();
              },
              child: Text(L('storage.manage')),
            ),
        ]),
      ]),
    );
  }
}

/// The parts side by side, each as wide as its share and at least a sliver.
class _SegmentBar extends StatelessWidget {
  const _SegmentBar({required this.groups, required this.height});
  final List<StorageGroup> groups;
  final double height;

  @override
  Widget build(BuildContext context) {
    final shown = groups.where((g) => g.bytes > 0).toList()..sort((a, b) => b.bytes.compareTo(a.bytes));
    final total = shown.fold<int>(0, (a, g) => a + g.bytes);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height / 2),
      child: SizedBox(
        height: height,
        child: Row(children: [
          for (var i = 0; i < shown.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Flexible(flex: (shown[i].bytes * 1000 ~/ total).clamp(6, 1000), child: ColoredBox(color: _StoragePageState._look(shown[i].key).$1, child: const SizedBox.expand())),
          ],
        ]),
      ),
    );
  }
}
