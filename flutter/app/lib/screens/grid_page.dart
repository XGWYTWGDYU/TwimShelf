
import 'package:flutter/material.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../app/places.dart';

import 'package:flutter/services.dart';

import '../actions/folder_actions.dart';
import '../actions/media_actions.dart';
import '../actions/search_export.dart';
import '../grid/zoom_grid.dart';
import '../l10n/l10n.dart';
import 'viewer_page.dart';
import '../app/jobs.dart';

/// A place's media on the zoomable grid (图片, 视频, a folder, 回收站…): tap opens the viewer
/// over the same list.
class GridPage extends StatefulWidget {
  const GridPage({super.key, required this.library, required this.place});
  final LibraryModel library;
  final Place place;

  @override
  State<GridPage> createState() => _GridPageState();
}

class _GridPageState extends State<GridPage> {
  final _grid = GlobalKey<ZoomGridState>();
  bool _canZoomIn = true, _canZoomOut = true;

  /// The "…" menu, as the native grid's: 在浏览中查看, and for a folder its ZIP,
  /// renaming and deleting; the bin's: when it empties itself, restore all, empty it.
  Widget _moreMenu(List<FeedItem> items) {
    final folder = widget.place.folder;
    final inBin = widget.place == Place.trash;
    PopupMenuEntry<VoidCallback> e(IconData icon, String label, VoidCallback action, {bool danger = false, String? key}) => PopupMenuItem(
          key: key == null ? null : ValueKey(key),
          value: action,
          child: Row(children: [
            Icon(icon, size: 20, color: danger ? Theme.of(context).colorScheme.error : null),
            const SizedBox(width: 12),
            Flexible(child: Text(label, style: danger ? TextStyle(color: Theme.of(context).colorScheme.error) : null)),
          ]),
        );
    return PopupMenuButton<VoidCallback>(
      key: const ValueKey('gridMore'),
      icon: const Icon(Icons.more_horiz),
      popUpAnimationStyle: menuAnimation,
      onSelected: (a) => a(),
      itemBuilder: (context) => [
        if (inBin) ...[
          e(Icons.schedule, L('trash.autoDelete', [_keepTitle(Core.trashKeepDays())]), _chooseKeep),
          e(Icons.undo, L('trash.restoreAll'), () => runMediaAction(context, widget.library, ActionKind.restore, media: [for (final i in items) i.media_id], done: (n) => L('trash.restored', [n]))),
          const PopupMenuDivider(),
          e(Icons.delete_forever_outlined, L('trash.emptyEllipsis'), () => purgeMedia(context, widget.library, [for (final i in items) i.media_id]), danger: true),
        ] else ...[
          if (widget.place.filter != null)
            e(Icons.view_agenda_outlined, L('grid.revealMedia'), () {
              widget.library.showInBrowse(widget.place.filter!);
              Navigator.of(context).popUntil((r) => r.isFirst);
            }),
          if (folder != null) ...[
            const PopupMenuDivider(),
            e(Icons.folder_zip_outlined, L('folder.exportZip'), () => exportToFile(context, Core.mediaIdsInFolder(folder),
                ExportOptions(tags: false, folders: false, media_only: true), '${folder.replaceAll('/', '_')}.zip')),
            e(Icons.edit_outlined, L('folder.renameEllipsis'), () => renameFolder(context, widget.library, folder, onDone: () => Navigator.of(context).maybePop())),
            e(Icons.delete_outline, L('folder.deleteEllipsis'), () => deleteFolder(context, widget.library, folder, onDone: () => Navigator.of(context).maybePop()), danger: true),
          ],
        ],
      ],
    );
  }

  static const _keepChoices = [7, 30, 90, 365, 0];
  static String _keepTitle(int days) => switch (days) {
        7 || 30 || 90 || 365 => L('trash.keep.$days'), // i18n-exempt: keys trash.keep.<days>
        0 => L('trash.neverShort'),
        _ => L('trash.keep.days', [days]),
      };

  Future<void> _chooseKeep() async {
    final now = Core.trashKeepDays();
    final days = await showDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: Text(L('trash.autoDelete', [_keepTitle(now)])),
        children: [
          RadioGroup<int>(
            groupValue: now,
            onChanged: (v) => Navigator.pop(c, v),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final d in _keepChoices) RadioListTile<int>(value: d, title: Text(d == 0 ? L('trash.never') : L('trash.after', [_keepTitle(d)]))),
            ]),
          ),
        ],
      ),
    );
    if (days == null || days == now) return;
    Core.setTrashKeepDays(days);
    await coreRunAsync(Core.expireTrash);
    await widget.library.refresh();
    _load();
  }

  List<FeedItem>? _items;
  int _revision = -1;
  int _generation = 0;
  /// Selection mode: the media chosen, by id (a reload may put others at the same places); null
  /// when not selecting.
  Set<String>? _selected;

  void _toggle(int i) {
    final id = _items![i].media_id;
    setState(() => _selected!.contains(id) ? _selected!.remove(id) : _selected!.add(id));
  }

  List<FeedItem> get _chosen => [for (final i in _items ?? const <FeedItem>[]) if (_selected?.contains(i.media_id) ?? false) i];

  /// The places of the chosen media in the list on screen.
  Set<int>? get _selectedPlaces {
    final ids = _selected;
    if (ids == null) return null;
    final items = _items ?? const <FeedItem>[];
    return {for (var i = 0; i < items.length; i++) if (ids.contains(items[i].media_id)) i};
  }

  void _endSelecting() => setState(() => _selected = null);

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_changed);
    HardwareKeyboard.instance.addHandler(_key);
    _load();
  }

  /// Ctrl or ⌘ with + or −: for the grid on top, wherever the keyboard focus is at the moment
  /// (coming from the sidebar it is not in the grid).
  bool _key(KeyEvent e) {
    if (e is KeyUpEvent) return false;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return false;
    final k = e.logicalKey;
    final step = k == LogicalKeyboardKey.equal || k == LogicalKeyboardKey.add || k == LogicalKeyboardKey.numpadAdd
        ? -1
        : k == LogicalKeyboardKey.minus || k == LogicalKeyboardKey.numpadSubtract
            ? 1
            : 0;
    if (step == 0 || !mounted || !_onTop()) return false;
    _grid.currentState?.step(step);
    return true;
  }

  /// Nothing over this page, in its own navigator or the ones around it, and its tab is showing.
  bool _onTop() {
    if (!TickerMode.valuesOf(context).enabled) return false;
    var at = context;
    while (true) {
      final route = ModalRoute.of(at);
      if (route == null) return true;
      if (!route.isCurrent) return false;
      final navigator = route.navigator;
      if (navigator == null) return true;
      at = navigator.context;
    }
  }

  @override
  void dispose() {
    widget.library.removeListener(_changed);
    HardwareKeyboard.instance.removeHandler(_key);
    super.dispose();
  }

  void _changed() {
    if (widget.library.revision != _revision) _load();
  }

  Future<void> _load() async {
    _revision = widget.library.revision;
    final gen = ++_generation;
    final place = widget.place;
    final List<FeedItem> items;
    if (place == Place.trash) {
      items = await loadBin();
    } else {
      items = await widget.library.feed(FeedRequest(filter: place.filter));
    }
    if (!mounted || gen != _generation) return;
    setState(() {
      _items = items;
      // what has gone from the list is no longer chosen
      final here = {for (final i in items) i.media_id};
      _selected = _selected?.where(here.contains).toSet();
    });
  }

  String _subtitle(List<FeedItem> items) {
    final videos = items.where((i) => i.kind == MediaKind.video).length;
    final photos = items.length - videos;
    return [
      if (photos > 0) L('grid.photos', [photos]),
      if (videos > 0) L('grid.videos', [videos]),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final selected = _selectedPlaces;
    final inBin = widget.place == Place.trash;
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.paddingOf(context);
    // Material 3 Expressive's floating toolbars: where you are, and what can be done here, as
    // capsules of their own; the grid runs under them
    Widget capsule(Widget child, {Key? key}) => Material(
          key: key,
          color: scheme.surfaceContainer,
          elevation: 4,
          shadowColor: Colors.black38,
          shape: const StadiumBorder(),
          child: SizedBox(height: 52, child: child),
        );
    final canPop = Navigator.of(context).canPop();
    final floating = Padding(
      padding: EdgeInsets.only(top: pad.top + 6, left: 12, right: 12),
      child: Row(children: [
        Expanded(
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: capsule(
            key: const ValueKey('gridTitle'),
            Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: canPop ? 4 : 18),
              if (canPop) const BackButton(),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(right: 18),
                  child: selected != null
                      ? Text(selected.isEmpty ? L('grid.selectItems') : L('grid.selected', [selected.length]), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall)
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                          Text(widget.place.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleSmall),
                          if (items != null && items.isNotEmpty) Text(_subtitle(items), maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                ),
              ),
            ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        capsule(
          key: const ValueKey('gridTools'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected != null && items != null)
            TextButton(
              onPressed: () => setState(() => selected.length == items.length ? _selected!.clear() : _selected!.addAll(items.map((i) => i.media_id))),
              child: Text(selected.length == items.length ? L('grid.deselectAll') : L('grid.selectAll')),
            ),
          if (selected == null && items != null && items.isNotEmpty) ...[
            IconButton(key: const ValueKey('gridZoomOut'), tooltip: L('grid.zoomOut'), icon: const Icon(Icons.zoom_out), onPressed: _canZoomOut ? () => _grid.currentState?.step(1) : null),
            IconButton(key: const ValueKey('gridZoomIn'), tooltip: L('grid.zoomIn'), icon: const Icon(Icons.zoom_in), onPressed: _canZoomIn ? () => _grid.currentState?.step(-1) : null),
          ],
          if (selected == null) _moreMenu(items ?? const []),
          if (items != null && items.isNotEmpty)
            TextButton(
              key: const ValueKey('gridSelect'),
              onPressed: () => setState(() => _selected = selected == null ? <String>{} : null),
              child: Text(selected == null ? L('common.select') : L('common.cancel')),
            ),
            ]),
          ),
        ),
      ]),
    );
    return Scaffold(
      bottomNavigationBar: selected == null || selected.isEmpty
          ? null
          : BottomAppBar(
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                if (inBin) ...[
                  TextButton.icon(
                    icon: const Icon(Icons.restore),
                    label: Text(L('common.restore')),
                    onPressed: () {
                      runMediaAction(context, widget.library, ActionKind.restore, media: [for (final i in _chosen) i.media_id], done: (n) => L('trash.restored', [n]));
                      _endSelecting();
                    },
                  ),
                  TextButton.icon(
                    icon: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                    label: Text(L('common.deletePermanently'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onPressed: () async {
                      await purgeMedia(context, widget.library, [for (final i in _chosen) i.media_id]);
                      _endSelecting();
                    },
                  ),
                ] else ...[
                  TextButton.icon(
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: Text(L('common.addToFolder')),
                    onPressed: () async {
                      await addToFolder(context, widget.library, _chosen);
                      _endSelecting();
                    },
                  ),
                  TextButton.icon(
                    key: const ValueKey('gridTrash'),
                    icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                    label: Text(L('grid.moveToTrash'), style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    onPressed: () {
                      runMediaAction(context, widget.library, ActionKind.trash, media: [for (final i in _chosen) i.media_id], done: (n) => L('trash.moved', [n]));
                      _endSelecting();
                    },
                  ),
                ],
              ]),
            ),
      body: Stack(children: [
        Positioned.fill(child: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? Center(child: Text(widget.place == Place.trash ? L('grid.trashEmpty') : L('grid.empty')))
              : ZoomGrid(
                  key: _grid,
                  items: items,
                  store: widget.library.thumbs,
                  padding: EdgeInsets.only(top: pad.top + 64, bottom: pad.bottom),
                  selected: selected,
                  onZoomLimits: (zoomIn, zoomOut) {
                    if (mounted) {
                      setState(() {
                        _canZoomIn = zoomIn;
                        _canZoomOut = zoomOut;
                      });
                    }
                  },
                  onLongPress: (i, at) => showMediaMenu(context, library: widget.library, item: items[i], position: at, place: widget.place),
                  onOpen: (i) => selected != null ? _toggle(i) : Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
                        fullscreenDialog: true,
                        builder: (_) => ViewerPage(library: widget.library, items: items, index: i),
                      )),
                ),
              ),
        Positioned(left: 0, right: 0, top: 0, child: floating),
      ]),
    );
  }
}
