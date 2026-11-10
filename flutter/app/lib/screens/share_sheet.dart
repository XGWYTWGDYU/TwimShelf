import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../l10n/l10n.dart';
import '../widgets/choice_menu.dart';
import '../platform/share_inbox.dart';
import '../widgets/media_image.dart';
import 'settings_page.dart' show SettingsIcon, SettingsSection;
import '../widgets/text_menu.dart';
import '../platform/os.dart';

/// The share page where the system has no share page of its own for an app (Android, Linux), and
/// for what is dropped on a window: a sheet as tall as what it shows, with what was shared on a
/// card and the folder it goes into, or none. Links are downloaded here into a staging folder.
/// Nothing reaches the library until 导入; closing the sheet in any way deletes what was brought here.
Future<void> showShareSheet(BuildContext context, {required LibraryModel library, required ShareNeedsChoice batch}) => presentShareSheet(
      context,
      shares: library.shares,
      batch: batch,
      folders: [for (final f in library.folders?.folders ?? const <Folder>[]) f.name],
      confirm: library.shares.confirm,
    );

/// The sheet, wherever it is shown from; closed without importing, what was brought here goes.
Future<void> presentShareSheet(
  BuildContext context, {
  required ShareInbox shares,
  required ShareNeedsChoice batch,
  required List<String> folders,
  required ShareConfirm confirm,
}) async {
  final imported = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 560),
    backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
    builder: (_) => ShareSheet(shares: shares, batch: batch, folders: folders, confirm: confirm),
  );
  if (imported != true) await shares.discard(batch);
}

typedef ShareConfirm = Future<void> Function(ShareNeedsChoice batch, {String? folder, bool staged});

class ShareSheet extends StatefulWidget {
  const ShareSheet({super.key, required this.shares, required this.batch, required this.folders, required this.confirm});
  final ShareInbox shares;
  final ShareNeedsChoice batch;
  final List<String> folders;
  final ShareConfirm confirm;

  @override
  State<ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<ShareSheet> {
  ShareStaged? _staged;
  Object? _stageError;
  bool _working = false;
  String _folder = '';
  /// Folders made here: they come to exist with the import.
  final _made = <String>[];
  static const _newChoice = '\u0000new';

  ShareNeedsChoice get _batch => widget.batch;
  bool get _downloading => _batch.links.isNotEmpty && _staged == null && _stageError == null;

  @override
  void initState() {
    super.initState();
    if (_batch.links.isNotEmpty) _stage();
  }

  Future<void> _stage() async {
    try {
      final s = await widget.shares.stage(_batch.id, _batch.links);
      if (mounted) setState(() => _staged = s);
    } catch (e) {
      if (mounted) setState(() => _stageError = e);
    }
  }

  List<({String path, bool video})> get _media => [
        for (final f in _batch.files) (path: f, video: _isVideo(f)),
        for (final i in _staged?.items ?? const <FeedItem>[]) (path: i.path, video: i.kind == MediaKind.video),
      ];

  static bool _isVideo(String path) => const {'.mp4', '.mov', '.m4v', '.webm', '.mkv'}.any(path.toLowerCase().endsWith);

  Future<void> _import() async {
    setState(() => _working = true);
    final folder = _folder.isEmpty ? null : _folder;
    final navigator = Navigator.of(context);
    try {
      await widget.confirm(_batch, folder: folder, staged: _staged?.items.isNotEmpty ?? false);
      navigator.pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _working = false;
          _stageError = e;
        });
      }
    }
  }

  Future<void> _newFolder() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(L('common.newFolder')),
        content: TextField(contextMenuBuilder: appTextMenu, key: const ValueKey('shareNewFolderName'), controller: c, autofocus: true, decoration: InputDecoration(hintText: L('common.folderName')), onSubmitted: (v) => Navigator.pop(d, v)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(L('common.cancel'))),
          FilledButton(key: const ValueKey('shareNewFolderCreate'), onPressed: () => Navigator.pop(d, c.text), child: Text(L('common.create'))),
        ],
      ),
    );
    final n = name?.trim() ?? '';
    if (n.isEmpty || !mounted) return;
    setState(() {
      if (!_made.contains(n)) _made.insert(0, n);
      _folder = n;
    });
  }

  int get _bytes {
    var sum = 0;
    for (final m in _media) {
      try {
        sum += File(m.path).lengthSync();
      } catch (_) {}
    }
    return sum;
  }

  static String _size(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : b >= 1 << 20 ? '${(b / (1 << 20)).toStringAsFixed(1)} MB' : '${(b / (1 << 10)).ceil()} KB';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final media = _media;
    final folders = [..._made, for (final f in widget.folders) if (!_made.contains(f)) f];
    final problems = [
      for (final f in _staged?.failed ?? const <({String link, String reason})>[]) '${f.link}\n${f.reason}',
      if (_stageError != null) '$_stageError',
    ];
    final busy = _downloading || _working;
    final kind = media.length == 1 && media.first.path.contains('.') ? '${media.first.path.split('.').last.toUpperCase()} · ' : '';
    final status = Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      DecoratedBox(
        key: const ValueKey('shareStatus'),
        decoration: ShapeDecoration(color: scheme.secondaryContainer, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(L('share.readyCount', [media.length]), style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600)),
        ),
      ),
      Text('$kind${_size(_bytes)}', style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
    final hint = Text(L('share.hint'), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant));
    final mediaBody = media.isEmpty
        ? Text(L('share.nothing'), key: const ValueKey('shareStatus'), style: theme.textTheme.bodyMedium)
        : media.length == 1
            ? Row(children: [
                ShareThumb(media: media.first, side: 76),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    status,
                    const SizedBox(height: 6),
                    Text(media.first.path.split(OS.pathSeparator).last.replaceFirst(RegExp(r'^\d+[-_]'), ''), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 2),
                    hint,
                  ]),
                ),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                status,
                const SizedBox(height: 12),
                ShareThumbGrid(media: media),
                const SizedBox(height: 10),
                hint,
              ]);
    return Padding(
      key: const ValueKey('shareSheet'),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // the title in the middle, whatever the buttons' widths
            child: Stack(alignment: Alignment.center, children: [
              Text(L('common.import'), maxLines: 1, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Row(children: [
                TextButton(key: const ValueKey('shareClose'), onPressed: _working ? null : () => Navigator.of(context).pop(false), child: Text(L('common.close'))),
                const Spacer(),
                FilledButton(key: const ValueKey('shareImport'), onPressed: busy || media.isEmpty ? null : _import, child: Text(L('share.import'))),
              ]),
            ]),
          ),
          SettingsSection(children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: busy
                  ? Column(children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 12),
                      Text(_working ? L('share.handingOver') : L('share.downloading', [_batch.links.length]), textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    ])
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      mediaBody,
                      if (_staged?.items.firstOrNull?.text case final text? when text.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(text, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                      ],
                      if (problems.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SelectableText(contextMenuBuilder: appTextMenu, problems.join('\n\n'), key: const ValueKey('shareProblems'), style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
                      ],
                    ]),
            ),
          ]),
          if (media.isNotEmpty && !busy)
            SettingsSection(title: L('share.place'), children: [
              ListTile(
                leading: const SettingsIcon(Icons.folder_outlined),
                title: Text(L('share.targetFolder')),
                trailing: ChoiceMenu<String>(
                  key: const ValueKey('shareFolder'),
                  value: _folder,
                  items: [('', L('share.noFolder')), for (final f in folders) (f, f), (_newChoice, L('common.newFolderEllipsis'))],
                  onChanged: (v) => v == _newChoice ? _newFolder() : setState(() => _folder = v),
                ),
              ),
            ]),
        ]),
      ),
    );
  }
}

/// One shared media, small: a large photo costs its size on the screen, not its size on disk.
class ShareThumb extends StatelessWidget {
  const ShareThumb({super.key, required this.media, required this.side});
  final ({String path, bool video}) media;
  final double side;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      key: const ValueKey('shareCards'),
      borderRadius: BorderRadius.circular(14),
      child: SizedBox.square(
        dimension: side,
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: media.video
              ? Icon(Icons.play_circle_fill, size: side * 0.42, color: scheme.onSurfaceVariant)
              : Image(image: mediaImage(media.path, cacheWidth: 320, maxSide: 640), fit: BoxFit.cover, errorBuilder: (_, _, _) => Icon(Icons.image_outlined, color: scheme.onSurfaceVariant)),
        ),
      ),
    );
  }
}

/// Several: as many rows as they take, up to eight pictured, the last saying how many more.
class ShareThumbGrid extends StatelessWidget {
  const ShareThumbGrid({super.key, required this.media});
  final List<({String path, bool video})> media;
  static const _limit = 8;

  @override
  Widget build(BuildContext context) {
    final shown = media.take(_limit).toList();
    final more = media.length - shown.length;
    return Semantics(
      label: L('share.cards', [media.length]),
      child: LayoutBuilder(builder: (context, c) {
        final across = (c.maxWidth / 76).floor().clamp(3, 8);
        final side = (c.maxWidth - 8 * (across - 1)) / across;
        return Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < shown.length; i++)
            Stack(alignment: Alignment.center, children: [
              ShareThumb(media: shown[i], side: side),
              if (more > 0 && i == shown.length - 1)
                Container(
                  key: const ValueKey('shareCount'),
                  width: side,
                  height: side,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                  child: Text('+${more + 1}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
            ]),
        ]);
      }),
    );
  }
}
