import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/quick_action.dart';
import '../platform/share_inbox.dart';
import '../screens/share_sheet.dart';
import '../actions/folder_actions.dart';
import '../l10n/l10n.dart';
import '../widgets/drop_import.dart';
import '../mascot/mascot.dart';
import '../mascot/pet_layer.dart';
import '../platform/apple_platform.dart';
import '../platform/desktop_window.dart';
import '../screens/folders_page.dart';
import '../screens/grid_page.dart';
import '../screens/settings_page.dart';
import '../screens/data_home_page.dart';
import '../services/updates.dart';
import '../screens/browse_page.dart';
import 'library.dart';
import 'places.dart';
import 'prefs.dart';

/// How much room the window gives, decided from its size only — never from the device (a
/// phone, a foldable folded or open, a tablet in split view, a desktop window of any size).
enum ShellLayout {
  /// A bottom navigation bar (a phone's width).
  bar,
  /// A sidebar with every place (wide and tall enough).
  sidebar;

  static ShellLayout of(Size s) {
    return s.width < 840 || s.height < 480 ? bar : sidebar;
  }
}

/// The app's frame: the places of the library in the navigation the window has room for, and
/// the chosen place beside or above it.
///  * The bar (narrow or short) has 浏览, 文件夹 and 设置, as the native iPhone app; the media kinds
///    and the special collections are on the folders page. There is nothing in between.
///  * The sidebar lists every place, and the folders page then holds only the folders.
/// Each place keeps its own navigation stack, so a subpage (a settings page, a folder's grid)
/// opens in the content area and the navigation stays beside it. Widening the window leaves
/// 整理 mode (with room for it, 整理 is a place of its own).
class Shell extends StatefulWidget {
  const Shell({super.key, required this.library});
  final LibraryModel library;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  Place _place = Place.browse;
  final _navigators = <String, GlobalKey<NavigatorState>>{};
  ShellLayout? _layout;
  /// The sidebar's width while its edge is being dragged.
  double? _dragWidth;

  LibraryModel get library => widget.library;
  Prefs get prefs => Prefs.instance;

  /// One per place. The phone's stacks and the wide ones are kept apart (their pages differ: the
  /// folders page lists every kind); each set survives switching back and forth.
  GlobalKey<NavigatorState> _navigator(Place p) {
    final bar = _layout == ShellLayout.bar;
    final id = '${bar ? 'bar' : 'wide'}:${p.id}';
    return _navigators.putIfAbsent(id, GlobalKey<NavigatorState>.new);
  }

  static const _barPlaces = [Place.browse, Place.allFolders, Place.settings];

  @override
  void initState() {
    super.initState();
    library.addListener(_changed);
    library.revealRequest.addListener(_reveal);
    library.filterRequest.addListener(_showFilter);
    QuickAction.requests.addListener(_quickDownload);
    _shareEvents = library.shares.events.listen(_shareEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) => library.shares.pendingChoices.toList().forEach(_shareEvent));
    prefs.addListener(_changed);
    ApplePlatform.instance.windowControls.addListener(_changed);
    // GitHub builds: a newer release, at most once a day
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // what opening repaired or found missing first, then a newer release
      await StartupChecks.run(context);
      if (mounted) await Updates.checkOnLaunch(context);
    });
  }

  /// 下载帖子 on the app's icon: back to 浏览, which opens the card.
  void _quickDownload() {
    Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
    setState(() => _place = Place.browse);
  }

  /// What was shared here and is not confirmed yet: the share page, one at a time.
  Future<void>? _sharePage;
  StreamSubscription<ShareInboxEvent>? _shareEvents;
  final _shown = <String>{};
  void _shareEvent(ShareInboxEvent e) {
    if (e is! ShareNeedsChoice || !mounted || !_shown.add(e.id)) return;
    _sharePage = (_sharePage ?? Future.value()).then((_) async {
      if (mounted) await showShareSheet(context, library: library, batch: e);
    });
  }

  /// 在浏览中查看帖子: back to 浏览, wherever the request came from.
  void _reveal() {
    if (library.revealRequest.value == null) return;
    setState(() => _place = Place.browse);
  }

  void _showFilter() {
    if (library.filterRequest.value == null) return;
    setState(() => _place = Place.browse);
  }

  @override
  void dispose() {
    library.removeListener(_changed);
    library.revealRequest.removeListener(_reveal);
    library.filterRequest.removeListener(_showFilter);
    QuickAction.requests.removeListener(_quickDownload);
    _shareEvents?.cancel();
    prefs.removeListener(_changed);
    ApplePlatform.instance.windowControls.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<Place> _primary(ShellLayout l) => l == ShellLayout.bar ? _barPlaces : Place.primary;

  /// The main place a place belongs to in the bar.
  Place _primaryOf(Place p, ShellLayout l) => _primary(l).contains(p) ? p : Place.allFolders;

  void _select(Place p) => setState(() => _place = p);

  /// 浏览 tapped twice in a row reshuffles it.
  DateTime? _lastBrowseTap;
  void _barTapped(Place p) {
    final now = DateTime.now();
    final again = p == Place.browse && _place == p && _lastBrowseTap != null && now.difference(_lastBrowseTap!) < const Duration(milliseconds: 400);
    _lastBrowseTap = p == Place.browse && !again ? now : null;
    if (again) library.shuffleRequest.value++;
    _select(p);
  }

  /// Opens a place from inside a page (the folders page opening a grid).
  void open(Place p) {
    final layout = ShellLayout.of(MediaQuery.sizeOf(context));
    if (layout != ShellLayout.bar) {
      setState(() => _place = p);
    } else {
      setState(() => _place = Place.allFolders);
      _navigator(Place.allFolders).currentState?.push(MaterialPageRoute(builder: (_) => _page(p, layout)));
    }
  }

  Widget _page(Place p, ShellLayout layout) {
    if (p == Place.browse) return BrowsePage(library: library);
    if (p == Place.settings) return SettingsPage(library: library, layout: layout);
    if (p == Place.allFolders) return FoldersPage(library: library, onOpen: open, foldersOnly: layout != ShellLayout.bar);
    return GridPage(library: library, place: p, key: ValueKey(p.id));
  }

  /// A place's page in its own navigator: its subpages open beside the navigation.
  Widget _stack(Place p, ShellLayout layout) => Navigator(
        key: _navigator(p),
        onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _page(p, layout)),
      );

  @override
  Widget build(BuildContext context) {
    final layout = ShellLayout.of(MediaQuery.sizeOf(context));
    _layout = layout;
    return ShellBackHandler(
      navigator: () => _navigator(layout == ShellLayout.bar ? _primaryOf(_place, layout) : _place).currentState,
      child: DropImport(
        shares: library.shares,
        child: MascotPetLayer(
          child: switch (layout) {
            ShellLayout.bar => _withChrome(_barLayout()),
            ShellLayout.sidebar => _sidebarLayout(),
          },
        ),
      ),
    );
  }

  /// The bar touches the window's top-leading corner: everything moves below the window's
  /// controls (a windowed iPad's, macOS's traffic lights, the caption buttons on Windows and
  /// Linux), and on a desktop the strip there moves the window.
  Widget _withChrome(Widget child) {
    final top = WindowChrome.top(context);
    if (top == 0) return child;
    final mq = MediaQuery.of(context);
    return Stack(children: [
      MediaQuery(
        data: mq.copyWith(padding: mq.padding.copyWith(top: mq.padding.top > top ? mq.padding.top : top)),
        child: child,
      ),
      const Positioned(left: 0, right: 0, top: 0, child: WindowStrip()),
    ]);
  }

  Widget _primaryStacks(Place current, ShellLayout layout) {
    final places = _primary(layout);
    return IndexedStack(
      index: places.indexOf(current),
      children: [for (final p in places) _stack(p, layout)],
    );
  }

  Widget _barLayout() {
    final current = _primaryOf(_place, ShellLayout.bar);
    return Scaffold(
      // the pages run under the floating bar; their padding keeps what is last above it
      extendBody: true,
      body: _primaryStacks(current, ShellLayout.bar),
      bottomNavigationBar: FloatingNavBar(places: _barPlaces, current: current, onTap: _barTapped),
    );
  }

  /// The sidebar: every place, one tap away.
  Widget _sidebarLayout() {
    final folders = library.folders?.folders ?? const [];
    final scheme = Theme.of(context).colorScheme;
    Widget item(Place p, {String? count}) {
      final selected = _place == p;
      final row = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: ListTile(
          key: ValueKey('side-${p.id}'),
          dense: true,
          visualDensity: VisualDensity.compact,
          shape: const StadiumBorder(),
          selected: selected,
          selectedColor: scheme.onSecondaryContainer,
          selectedTileColor: scheme.secondaryContainer,
          leading: MascotIcon(p.mascotIcon, fallback: Icon(selected ? p.selectedIcon : p.icon)),
          title: Text(p.title, overflow: TextOverflow.ellipsis),
          trailing: count == null ? null : Text(count, style: Theme.of(context).textTheme.labelMedium),
          onTap: () => _select(p),
        ),
      );
      final folder = p.folder;
      if (folder == null) return row;
      // the folder that was open and is gone: back to all folders
      void open(Offset at) => showFolderMenu(context, library, folder, at, onRenamed: () { if (_place == p) _select(Place.allFolders); }, onDeleted: () { if (_place == p) _select(Place.allFolders); });
      return GestureDetector(onLongPressStart: (d) => open(d.globalPosition), onSecondaryTapUp: (d) => open(d.globalPosition), child: row);
    }

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 4),
          child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary)),
        );

    final stats = library.stats;
    final leading = WindowChrome.leading(context);
    final trailingTop = WindowChrome.trailing(context).bottom;
    final mq = MediaQuery.of(context);
    return Scaffold(
      // the page area below gets `mq`, keyboard included, and each page's own Scaffold makes room
      // for it: here too, and it counts twice (on an iPad, more than the height of the screen)
      resizeToAvoidBottomInset: false,
      body: Stack(children: [
        Row(children: [
          SizedBox(
            width: _dragWidth ?? prefs.sidebarWidth,
            child: Material(
              color: scheme.surfaceContainerLow,
              child: SafeArea(
                right: false,
                child: Column(children: [
                  // in line with the window's controls (a windowed iPad, macOS): the app, at the
                  // sidebar's end so the controls keep the start; the places start below them
                  // room for the window's controls (a windowed iPad, macOS): the places start below
                  if (leading.height > 0) SizedBox(height: (leading.bottom - mq.padding.top).clamp(28, 200)),
                  Expanded(
                    child: ListenableBuilder(listenable: prefs, builder: (context, _) => ListView(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      children: [
                        item(Place.browse),
                        item(Place.settings),
                        header(L('sidebar.mediaTypes')),
                        item(Place.photos, count: stats == null ? null : '${stats.photos}'),
                        item(Place.videos, count: stats == null ? null : '${stats.videos}'),
                        header(L('place.folders')),
                        item(Place.allFolders),
                        for (final f in folders) item(Place.folder(f.name), count: '${f.count}'),
                        header(L('sidebar.other')),
                        for (final p in Place.offered) item(p),
                      ],
                    )),
                  ),
                ]),
              ),
            ),
          ),
          // the sidebar's edge: drag it to make the sidebar wider or narrower
          MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                key: const ValueKey('sidebarEdge'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (_) => _dragWidth = prefs.sidebarWidth,
                onHorizontalDragUpdate: (d) => setState(() => _dragWidth = ((_dragWidth ?? prefs.sidebarWidth) + d.delta.dx).clamp(200.0, 420.0)),
                onHorizontalDragEnd: (_) {
                  prefs.sidebarWidth = _dragWidth ?? prefs.sidebarWidth;
                  _dragWidth = null;
                },
                child: const SizedBox(width: 9, child: Center(child: VerticalDivider(width: 1))),
              ),
            ),
          Expanded(
            // the caption buttons on Windows and Linux sit over the content's top end
            child: MediaQuery(
              data: mq.copyWith(padding: mq.padding.copyWith(top: mq.padding.top > trailingTop ? mq.padding.top : trailingTop)),
              child: KeyedSubtree(key: ValueKey('page-${_place.id}'), child: _stack(_place, ShellLayout.sidebar)),
            ),
          ),
        ]),
        const Positioned(left: 0, right: 0, top: 0, child: WindowStrip()),
      ]),
    );
  }
}

/// The system's back goes to the open place's own navigator first: left alone it only asks the root
/// one, which has nothing to go back to and leaves the app from any subpage.
class ShellBackHandler extends StatelessWidget {
  const ShellBackHandler({super.key, required this.navigator, required this.child});
  final NavigatorState? Function() navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final open = navigator();
          if (open != null && await open.maybePop()) return;
          await SystemNavigator.pop();
        },
        child: child,
      );
}

/// A phone's places as Material 3 Expressive's floating bar: a capsule over the page, as wide as
/// its contents; the chosen place opens up to show its name.
class FloatingNavBar extends StatelessWidget {
  const FloatingNavBar({super.key, required this.places, required this.current, required this.onTap});
  final List<Place> places;
  final Place current;
  final void Function(Place) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 12),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.max, children: [
        Material(
          key: const ValueKey('floatingBar'),
          color: scheme.surfaceContainer,
          elevation: 4,
          shadowColor: Colors.black38,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final p in places) _FloatingNavItem(place: p, selected: p == current, onTap: () => onTap(p)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _FloatingNavItem extends StatelessWidget {
  const _FloatingNavItem({required this.place, required this.selected, required this.onTap});
  final Place place;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant;
    const spring = Curves.easeOutCubic;
    const time = Duration(milliseconds: 260);
    return Tooltip(
      message: selected ? '' : place.title,
      child: Semantics(
        selected: selected,
        button: true,
        label: place.title,
        child: AnimatedContainer(
          duration: time,
          curve: spring,
          decoration: ShapeDecoration(color: selected ? scheme.secondaryContainer : Colors.transparent, shape: const StadiumBorder()),
          child: InkWell(
            key: ValueKey('bar-${place.id}'),
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: AnimatedSize(
                duration: time,
                curve: spring,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconTheme.merge(
                    data: IconThemeData(color: color),
                    child: MascotIcon(place.mascotIcon, fallback: Icon(selected ? place.selectedIcon : place.icon)),
                  ),
                  if (selected) ...[
                    const SizedBox(width: 8),
                    Text(place.title, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w600)),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
