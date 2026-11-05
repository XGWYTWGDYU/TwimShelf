import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:tl_core/tl_core.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../platform/quick_action.dart';
import '../actions/media_actions.dart';
import '../actions/tag_picker.dart';
import '../app/library.dart';
import '../actions/card_menu.dart';
import '../actions/quick_download.dart';
import '../actions/search_export.dart';
import '../app/prefs.dart';
import '../app/shell.dart';
import '../l10n/l10n.dart';
import '../platform/video.dart';
import '../search/marks.dart';
import '../search/query.dart';
import '../widgets/capsule_search.dart';
import 'viewer_page.dart';
import '../app/feed_order.dart';
import '../widgets/media_image.dart';
import '../widgets/text_menu.dart';
import '../widgets/wheel_pager.dart';

/// 浏览: the library as cards — one per post (or one per media when not grouped) — in columns
/// whose cards are as tall as their content (text shown in full, no gap where a link is
/// missing), in a random order that a tap on 重新随机 deals again.
class BrowsePage extends StatefulWidget {
  const BrowsePage({super.key, required this.library});
  final LibraryModel library;

  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  List<List<FeedItem>>? _cards;
  List<FeedItem> _items = const [];
  /// Random order from the system's generator; ranks survive reloads until the next reshuffle.
  final _order = FeedOrder();
  bool _grouped = Prefs.instance.feedGrouped;
  /// The page each card was left on: a card that scrolled away comes back on it.
  final _cardPages = <String, int>{};
  TokenQuery _query = TokenQuery();
  /// What the chips under the search field narrow 浏览 to (only an author, tags, a
  /// grid's 在浏览中查看); each chip takes its part off again.
  String? _author;
  String? _authorDisplay;
  final List<String> _labels = [];
  FeedFilter? _shown;
  final _addKey = ValueNotifier<String?>(null);
  int _revision = -1;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.library.shuffleRequest.addListener(_shuffle);
    widget.library.addListener(_changed);
    Prefs.instance.addListener(_prefsChanged);
    widget.library.revealRequest.addListener(_reveal);
    widget.library.filterRequest.addListener(_showFilter);
    QuickAction.requests.addListener(_quickDownloadSoon);
    _quickDownloadSoon();
    _scroll.addListener(_scrolledUnder);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showFilter());
    _load();
  }

  /// The post asked for (在浏览中查看帖子) goes first, marked for a moment, and the list scrolls
  /// to the top.
  String? _highlight;
  final _scroll = ScrollController();
  /// Cards are under the floating search area (it turns frosted).
  bool _under = false;
  void _scrolledUnder() {
    final under = _scroll.hasClients && _scroll.offset > 2;
    if (under != _under) setState(() => _under = under);
  }
  void _reveal() {
    final item = widget.library.revealRequest.value;
    if (item == null) return;
    widget.library.revealRequest.value = null;
    _pendingReveal = item;
    _revealNow();
  }

  /// What a reveal still waits for: the list to load, or a search or filter that hid it to go.
  FeedItem? _pendingReveal;
  bool _clearedForReveal = false;

  void _revealNow() {
    final item = _pendingReveal;
    final cards = _cards;
    if (item == null || cards == null) return;
    final i = cards.indexWhere((c) => c.any((m) => m.post_id == item.post_id));
    if (i < 0) {
      // hidden by what narrows the list: that goes, once; a post that has really gone just stops here
      if (_clearedForReveal) {
        _pendingReveal = null;
        _clearedForReveal = false;
        return;
      }
      _clearedForReveal = true;
      setState(() {
        _query = TokenQuery();
        _author = null;
        _labels.clear();
        _shown = null;
      });
      Prefs.instance.badOnly = false;
      _badOnly = false;
      _load();
      return;
    }
    _pendingReveal = null;
    _clearedForReveal = false;
    setState(() {
      if (i > 0) cards.insert(0, cards.removeAt(i));
      _highlight = item.post_id;
    });
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _highlight = null);
    });
  }

  @override
  void dispose() {
    widget.library.shuffleRequest.removeListener(_shuffle);
    widget.library.removeListener(_changed);
    Prefs.instance.removeListener(_prefsChanged);
    widget.library.revealRequest.removeListener(_reveal);
    widget.library.filterRequest.removeListener(_showFilter);
    QuickAction.requests.removeListener(_quickDownloadSoon);
    _addKey.dispose();
    _scroll.dispose();
    super.dispose();
  }

  final _downloadButton = GlobalKey();

  /// 下载帖子 on the app's icon: the same card, under its button (under the search field's corner
  /// while a search has the button away), once the shell has come back to this page.
  void _quickDownloadSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !QuickAction.take()) return;
      final button = _downloadButton.currentContext;
      final size = MediaQuery.sizeOf(context);
      final top = MediaQuery.paddingOf(context).top + 58;
      showQuickDownload(
        button ?? context,
        downloads: widget.library.downloads,
        library: widget.library,
        at: button == null ? Rect.fromLTRB(size.width - 12, top, size.width - 12, top) : null,
      );
    });
  }

  /// The chips' filter, with 只看损坏 from 设置.
  FeedFilter get _filter {
    final j = (_shown ?? FeedFilter()).toJson();
    if (_author != null) j['author'] = _author;
    if (_labels.isNotEmpty) j['labels'] = [...(j['labels'] as List? ?? const []), ..._labels];
    if (Prefs.instance.badOnly) j['bad_only'] = true;
    return FeedFilter.fromJson(j);
  }

  void _showFilter() {
    final f = widget.library.filterRequest.value;
    if (f == null) return;
    widget.library.filterRequest.value = null;
    setState(() {
      _shown = f;
      _author = null;
      _labels.clear();
    });
    _load();
  }

  late final _menuHost = CardMenuHost(
    onlyAuthor: (key, display) {
      setState(() {
        _author = key;
        _authorDisplay = display;
      });
      _load();
    },
    onlyLabel: (label) {
      if (!_labels.contains(label)) setState(() => _labels.add(label));
      _load();
    },
    addTerm: (term) => _addKey.value = TokenQuery.termKey(term.toLowerCase()),
  );

  /// The chips: each takes its filter off again.
  List<Widget> _chips() {
    final shown = _shown;
    Widget chip(String key, String text, Color color, VoidCallback remove) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 8),
          child: InputChip(
            key: ValueKey(key),
            label: Text(text),
            labelStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            backgroundColor: color,
            deleteIconColor: Colors.white,
            side: BorderSide.none,
            onDeleted: () {
              setState(remove);
              _load();
            },
            deleteButtonTooltipMessage: L('feed.removeFilter', [text]),
          ),
        );
    return [
      if (_author != null) chip('chip-author', L('feed.chip.author', [_authorDisplay ?? _author!]), Colors.indigo, () => _author = null),
      for (final l in _labels) chip('chip-label-$l', L('feed.chip.label', [l]), Colors.green.shade700, () => _labels.remove(l)),
      if (shown?.loose_only ?? false) chip('chip-loose', L('card.loose'), Colors.indigo, () => _shown = null),
      if (shown?.album_only ?? false) chip('chip-album', L('card.album'), Colors.indigo, () => _shown = null),
      if (shown?.recent_only ?? false) chip('chip-recent', L('place.recent'), Colors.orange.shade800, () => _shown = null),
      if (shown?.kind != null) chip('chip-kind', shown!.kind == MediaKind.video ? L('feed.chip.videos') : L('feed.chip.photos'), Colors.pink, () => _shown = null),
      if (shown?.folder != null) chip('chip-folder', L('search.token.folder', [shown!.folder!]), Colors.teal, () => _shown = null),
      if (Prefs.instance.badOnly) chip('chip-bad', L('feed.chip.bad'), Colors.red, () => Prefs.instance.badOnly = false),
    ];
  }

  static bool get _touchShuffle => Platform.isIOS || Platform.isAndroid;

  void _shuffle() {
    if (Prefs.instance.feedByAdded) return;
    _order.reshuffle();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  bool _badOnly = Prefs.instance.badOnly;
  int _density = Prefs.instance.densityPortrait * 3 + Prefs.instance.densityLandscape;
  void _prefsChanged() {
    final density = Prefs.instance.densityPortrait * 3 + Prefs.instance.densityLandscape;
    if (density != _density) {
      _density = density;
      setState(() {});
    }
    if (Prefs.instance.badOnly == _badOnly) return;
    _badOnly = Prefs.instance.badOnly;
    _load();
  }

  void _changed() {
    if (widget.library.revision != _revision) _load();
  }

  Future<void> _load() async {
    _revision = widget.library.revision;
    final gen = ++_generation;
    // a contradiction (视频 -视频) finds nothing, as in the native apps, without asking the core
    final items = _query.isContradictory ? const <FeedItem>[] : await widget.library.feed(_query.request(newestFirst: Prefs.instance.feedByAdded, over: _filter));
    if (!mounted || gen != _generation) return;
    setState(() {
      _items = Prefs.instance.feedByAdded ? items : _order.apply(items);
      _cards = _group(_items);
    });
    _revealNow();
    if (!_sizesWatched && items.any((i) => i.width == 0)) {
      _sizesWatched = true;
      unawaited(_afterSizes());
    }
  }

  /// A feed read while the core was still reading the media's sizes in the background shows them
  /// once that has finished (first run after an update: until then the cards are 4:5).
  bool _sizesWatched = false;
  Future<void> _afterSizes() async {
    try {
      while (Core.mediaSizesFilling()) {
        await Future<void>.delayed(const Duration(seconds: 2));
        if (!mounted) return;
      }
    } catch (_) {
      return;
    }
    if (mounted) await _load();
  }

  List<List<FeedItem>> _group(List<FeedItem> items) {
    if (!_grouped) return [for (final i in items) [i]];
    return Prefs.instance.feedByAdded ? FeedOrder.postsInPlace(items) : _order.posts(items);
  }

  /// As native: every media in the order of the cards, so turning the page goes through a post's
  /// media and on into the next post's, photos and videos alike.
  void _open(FeedItem item) {
    final (items, index) = viewerList(_cards ?? const [], item);
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ViewerPage(library: widget.library, items: items, index: index),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cards = _cards;
    final pad = MediaQuery.paddingOf(context);
    final chips = _chips();
    final headerHeight = 64.0 + (chips.isNotEmpty ? 44 : 0);
    final scheme = Theme.of(context).colorScheme;
    // a phone's width leaves the search field its room beside the buttons
    final dense = ShellLayout.of(MediaQuery.sizeOf(context)) == ShellLayout.bar;
    final searchRow = SizedBox(
              height: dense ? 56 : 64,
              child: Row(children: [
                SizedBox(width: dense ? 4 : 12),
                Expanded(
                  child: CapsuleSearch(
              flat: dense,
              // a phone's width searches full screen, as the native iPhone app
              fullScreen: ShellLayout.of(MediaQuery.sizeOf(context)) == ShellLayout.bar,
              initialKeys: _query.keys,
              addKey: _addKey,
              folders: () => [for (final f in widget.library.folders?.folders ?? const <Folder>[]) (name: f.name, count: f.count)],
              onChanged: (q) {
                _query = q;
                _load();
              },
                  ),
                ),
              // 导出搜索结果 (while searching)
              if (_query.keys.isNotEmpty)
                _RoundButton(
                  key: const ValueKey('searchExport'),
                  tooltip: L('export.search.title'),
                  icon: Icons.ios_share,
                  dense: dense,
                  onPressed: () => exportSearchResult(context, _items, terms: _query.terms),
                ),
              // 按添加时间排序, 按帖子分组 and 快捷下载, as native: with nothing searched for and
              // nothing narrowing 浏览
              if (_query.keys.isEmpty && chips.isEmpty) ...[
                _RoundButton(
                  key: const ValueKey('sortByAdded'),
                  tooltip: L('feed.sortByAdded'),
                  icon: Icons.schedule,
                  dense: dense,
                  selected: Prefs.instance.feedByAdded,
                  onPressed: () {
                    setState(() => Prefs.instance.feedByAdded = !Prefs.instance.feedByAdded);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    _load();
                  },
                ),
                _RoundButton(
                  key: const ValueKey('groupToggle'),
                  tooltip: L('feed.groupByPost'),
                  icon: Icons.layers_outlined,
                  dense: dense,
                  selected: _grouped,
                  onPressed: () => setState(() {
                    _grouped = !_grouped;
                    Prefs.instance.feedGrouped = _grouped;
                    _cards = _group(_items);
                  }),
                ),
                Builder(
                  key: _downloadButton,
                  builder: (button) => _RoundButton(
                    key: const ValueKey('quickDownload'),
                    tooltip: L('common.downloadPosts'),
                    icon: Icons.arrow_downward,
                    dense: dense,
                    onPressed: () => showQuickDownload(button, downloads: widget.library.downloads, library: widget.library),
                  ),
                ),
              ],
              // by date there is nothing to shuffle: it leaves, and comes back with the random order.
              // Phones and tablets pull down at the top instead, or tap 浏览 twice.
              if (!_touchShuffle)
                CollapsingButton(
                  shown: !Prefs.instance.feedByAdded,
                  child: _RoundButton(
                    key: const ValueKey('reshuffle'),
                    tooltip: L('feed.reshuffle'),
                    icon: Icons.shuffle,
                    dense: dense,
                    onPressed: _shuffle,
                  ),
                ),
              SizedBox(width: dense ? 8 : 4),
              ]),
            );
    // at a phone's width: a capsule of its own, like the bar below (Material 3 Expressive's
    // floating toolbar), with the cards passing under it and the status bar kept readable
    final chipRow = chips.isEmpty
        ? null
        : SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 2, 12, 6), children: chips),
          );
    final Widget floatingHeader = Stack(children: [
      Positioned(
        left: 0,
        right: 0,
        top: 0,
        height: pad.top + 28,
        child: IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [scheme.surface.withValues(alpha: 0.85), scheme.surface.withValues(alpha: 0)]),
            ),
          ),
        ),
      ),
      Padding(
        padding: EdgeInsets.only(top: pad.top + 6),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Material(
              key: const ValueKey('floatingSearch'),
              color: scheme.surfaceContainer,
              elevation: 4,
              shadowColor: Colors.black38,
              shape: const StadiumBorder(),
              child: searchRow,
            ),
          ),
          if (chipRow != null) Padding(padding: const EdgeInsets.only(top: 2), child: chipRow),
        ]),
      ),
    ]);
    // the search area floats over the cards: clear over the top of the list, frosted (blurred
    // and tinted) once cards scroll underneath it
    final header = dense ? floatingHeader : ClipRect(
      child: BackdropFilter(
        filter: _under ? ImageFilter.blur(sigmaX: 18, sigmaY: 18) : ImageFilter.blur(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          color: _under ? scheme.surface.withValues(alpha: 0.72) : scheme.surface.withValues(alpha: 0),
          padding: EdgeInsets.only(top: pad.top),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            searchRow,
            // the chips, only while something narrows 浏览
            if (chips.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.fromLTRB(12, 2, 12, 6), children: chips),
              ),
          ]),
        ),
      ),
    );
    final top = pad.top + headerHeight;
    final Widget body = cards == null
            ? const Center(child: CircularProgressIndicator())
            : cards.isEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(_query.keys.isEmpty && _chips().isEmpty ? L('feed.empty.library') : L('feed.empty.noMatch'), textAlign: TextAlign.center)))
                : LayoutBuilder(builder: (context, c) {
                    final screen = MediaQuery.sizeOf(context);
                    final columns = Prefs.instance.feedColumns(c.maxWidth, screen.height);
                    final side = c.maxWidth > 700 ? 24.0 : 12.0;
                    final footer = Padding(
                      key: const ValueKey('feedEnd'),
                      padding: EdgeInsets.fromLTRB(24, 8, 24, 24 + MediaQuery.paddingOf(context).bottom),
                      // the end, as native: "共 12 条帖子，已经到底", across the whole width
                      child: Row(children: [
                        const Expanded(child: Divider()),
                        const SizedBox(width: 12),
                        Icon(Icons.check_circle_outline, size: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Text(L(_grouped ? 'feed.end.posts' : 'feed.end.media', [cards.length]),
                            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                        const SizedBox(width: 12),
                        const Expanded(child: Divider()),
                      ]),
                    );
                    final list = CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        SliverPadding(
                          // the cards start below the floating search area and pass under it
                          padding: EdgeInsets.fromLTRB(side, top + 4, side, 16),
                          sliver: SliverMasonryGrid.count(
                            crossAxisCount: columns,
                            mainAxisSpacing: 18,
                            crossAxisSpacing: 14,
                            childCount: cards.length,
                            itemBuilder: (context, i) => PostCard(
                              key: ValueKey(cards[i].first.media_id),
                              library: widget.library,
                              media: cards[i],
                              startPage: _cardPages[cards[i].first.media_id] ?? 0,
                              onPage: (p) => _cardPages[cards[i].first.media_id] = p,
                              highlighted: _highlight == cards[i].first.post_id,
                              menuHost: _menuHost,
                              marks: _query.marks,
                              onOpen: _open,
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(child: footer),
                        // room above the floating bar
                        SliverToBoxAdapter(child: SizedBox(height: pad.bottom)),
                      ],
                    );
                    if (!_touchShuffle) return list;
                    return RefreshIndicator(
                      key: const ValueKey('pullToShuffle'),
                      edgeOffset: top,
                      notificationPredicate: (n) => n.depth == 0 && !Prefs.instance.feedByAdded,
                      onRefresh: () async => _shuffle(),
                      child: list,
                    );
                  });
    return Scaffold(
      body: MediaQuery.removePadding(
        context: context,
        removeTop: true,
        child: Stack(children: [
          Positioned.fill(child: cards == null || cards.isEmpty ? Padding(padding: EdgeInsets.only(top: top), child: body) : body),
          Positioned(left: 0, right: 0, top: 0, child: header),
        ]),
      ),
    );
  }
}

/// One post (or one media): its media to swipe through, the author, the whole text (selectable
/// like any text), the link if there is one, and the tags.
class PostCard extends StatefulWidget {
  const PostCard({super.key, required this.library, required this.media, this.startPage = 0, this.onPage, required this.onOpen, this.highlighted = false, this.marks, this.menuHost});
  /// 浏览's filters and search for the card menu (none: the menu of a grid).
  final CardMenuHost? menuHost;
  final LibraryModel library;
  final List<FeedItem> media;
  final int startPage;
  final ValueChanged<int>? onPage;
  /// Just revealed: drawn with an outline for a moment.
  final bool highlighted;
  /// The searched words to mark, per field (none when not searching).
  final SearchMarks? marks;
  final void Function(FeedItem) onOpen;

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  void _menu(FeedItem item, Offset at) {
    final host = widget.menuHost;
    host == null
        ? showMediaMenu(context, library: widget.library, item: item, position: at)
        : showCardMenu(context, library: widget.library, item: item, position: at, host: host);
  }

  late int _page = widget.startPage.clamp(0, widget.media.length - 1);
  late final _pager = PageController(initialPage: _page);

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _turn(int by) => _pager.animateToPage(_page + by, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final first = widget.media.first;
    final theme = Theme.of(context);
    final loose = first.post_id.startsWith('loose:');
    final author = [if (first.author_name != null) first.author_name!, if (first.screen_name != null) '@${first.screen_name}'];
    final tags = widget.media[_page.clamp(0, widget.media.length - 1)].tags;
    final current = widget.media[_page.clamp(0, widget.media.length - 1)];
    return Card.filled(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: widget.highlighted ? BorderSide(color: theme.colorScheme.primary, width: 3) : BorderSide.none,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        // the card's media follows the pages: from the height of one to the next's, with the finger
        // (or the turn), and the cards under it move along
        AnimatedBuilder(
          animation: _pager,
          builder: (context, child) => AspectRatio(
            aspectRatio: cardAspectAt(widget.media, _pager.hasClients && _pager.position.haveDimensions ? _pager.page! : _page.toDouble()),
            child: child,
          ),
          child: Stack(children: [
            Positioned.fill(
              child: WheelPager(
                enabled: widget.media.length > 1,
                canStep: (by) => _page + by >= 0 && _page + by < widget.media.length,
                onStep: _turn,
                child: PageView.builder(
                  controller: _pager,
                  scrollBehavior: pageBehavior(context),
                  itemCount: widget.media.length,
                  onPageChanged: (p) {
                    widget.onPage?.call(p);
                    setState(() => _page = p);
                  },
                  itemBuilder: (context, i) => WheelGuard(child: GestureDetector(
                    onTap: () => widget.onOpen(widget.media[i]),
                    onLongPressStart: (d) => _menu(widget.media[i], d.globalPosition),
                    onSecondaryTapUp: (d) => _menu(widget.media[i], d.globalPosition),
                    child: _CardMedia(item: widget.media[i], library: widget.library, current: i == _page),
                  )),
                ),
              ),
            ),
            // a mouse does not drag pages
            if (widget.media.length > 1 && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) ...[
              if (_page > 0) _PageArrow(key: const ValueKey('cardPrev'), left: true, onTap: () => _turn(-1)),
              if (_page < widget.media.length - 1) _PageArrow(key: const ValueKey('cardNext'), left: false, onTap: () => _turn(1)),
            ],
            if (widget.media.length > 1)
              Positioned(
                top: 10,
                right: 10,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    child: Text('${_page + 1}/${widget.media.length}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (loose)
              Text(first.album ? L('place.album') : L('place.loose'), style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.tertiary))
            else
              Text.rich(TextSpan(children: [
                markedSpan(first.author_name ?? L('common.unknownAuthor'), widget.marks?.author ?? const [], theme.textTheme.titleSmall, theme.colorScheme),
                if (first.screen_name != null)
                  markedSpan('  @${first.screen_name}', widget.marks?.author ?? const [], theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant), theme.colorScheme),
              ]), maxLines: 1, overflow: TextOverflow.ellipsis, semanticsLabel: author.join(' ')),
            if ((first.text ?? '').isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText.rich(contextMenuBuilder: appTextMenu, markedSpan(first.text!, widget.marks?.text ?? const [], theme.textTheme.bodyMedium, theme.colorScheme), key: const ValueKey('postText')),
            ],
            if (first.url != null) ...[
              const SizedBox(height: 6),
              InkWell(
                onTap: () => launchUrl(Uri.parse(first.url!)),
                child: Text(first.url!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
              ),
            ],
            if (tags.isNotEmpty || !loose) ...[
              const SizedBox(height: 10),
              // one row of capsules that scrolls sideways, the + at its end (as native)
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: tags.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 6),
                      itemBuilder: (context, i) => _TagChip(tag: tags[i], marks: widget.marks?.tags ?? const []),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  key: const ValueKey('addTag'),
                  tooltip: L('card.addTag'),
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                  padding: EdgeInsets.zero,
                  onPressed: () => showTagPicker(context, widget.library, current),
                  icon: const Icon(Icons.add),
                ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Width per unit of height of a card's media at a place between two pages (1.5: halfway from the
/// second to the third): its height moves evenly from one page's to the next's.
double cardAspectAt(List<FeedItem> media, double position) {
  final p = position.clamp(0.0, media.length - 1.0);
  final a = p.floor(), b = p.ceil();
  final ha = 1 / media[a].cardAspectRatio, hb = 1 / media[b].cardAspectRatio;
  return 1 / (ha + (hb - ha) * (p - a));
}

class _PageArrow extends StatelessWidget {
  const _PageArrow({super.key, required this.left, required this.onTap});
  final bool left;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Positioned(
        left: left ? 8 : null,
        right: left ? null : 8,
        top: 0,
        bottom: 0,
        child: Center(
          child: IconButton(
            style: IconButton.styleFrom(backgroundColor: Colors.black38, foregroundColor: Colors.white),
            icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
            onPressed: onTap,
          ),
        ),
      );
}

class _CardMedia extends StatelessWidget {
  const _CardMedia({required this.item, required this.library, required this.current});
  final FeedItem item;
  final LibraryModel library;
  /// The page shown in a card with several media (only that one plays).
  final bool current;

  @override
  Widget build(BuildContext context) {
    if (item.kind == MediaKind.video) return _FeedVideo(item: item, library: library, current: current);
    return LayoutBuilder(builder: (context, c) {
      final px = (c.maxWidth * MediaQuery.devicePixelRatioOf(context)).ceil();
      return Image(image: mediaImage(item.path, cacheWidth: px.clamp(256, 2048), maxSide: 2048), fit: BoxFit.contain, gaplessPlayback: true,
          errorBuilder: (_, _, _) => Center(child: Icon(Icons.broken_image_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant)));
    });
  }
}

/// A video in a card: plays muted and looping while at least half of it is on screen, stops
/// (and lets its player go) once it leaves. Its poster shows until the first frame and whenever
/// it is not playing. A few play at once at most, the rest wait as posters.
class _FeedVideo extends StatefulWidget {
  const _FeedVideo({required this.item, required this.library, required this.current});
  final FeedItem item;
  final LibraryModel library;
  final bool current;

  @override
  State<_FeedVideo> createState() => _FeedVideoState();
}

class _FeedVideoState extends State<_FeedVideo> {
  /// Players alive at once (each is a decoder and a texture).
  static const _limit = 4;
  static final _playing = <_FeedVideoState>{};
  static final _waiting = <_FeedVideoState>[];

  VideoPlayback? _video;
  String? _poster;
  bool _visible = false;
  bool _firstFrame = false;
  StreamSubscription<Duration>? _position;

  @override
  void initState() {
    super.initState();
    _loadPoster();
  }

  @override
  void didUpdateWidget(_FeedVideo old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current || old.item.media_id != widget.item.media_id) _update();
  }

  Future<void> _loadPoster() async {
    final p = await videoCardPoster(widget.item, 1024, widget.library.thumbs.cacheDir);
    if (mounted && p != null) setState(() => _poster = p);
  }

  bool get _wants => _visible && widget.current;

  void _update() {
    if (_wants) {
      if (_video != null || _waiting.contains(this)) return;
      if (_playing.length < _limit) {
        _start();
      } else {
        _waiting.add(this);
      }
    } else {
      _waiting.remove(this);
      _stop();
    }
  }

  Future<void> _start() async {
    _playing.add(this);
    final v = VideoPlayback();
    setState(() => _video = v);
    try {
      await v.setMuted(true);
      await v.setLoop(true);
      _position = v.position.listen((p) {
        if (!_firstFrame && p > Duration.zero && mounted) setState(() => _firstFrame = true);
      });
      await v.open(widget.item.path);
      // scrolled away while it opened
      if (_video == v && !_wants) _stop();
    } catch (_) {
      if (_video == v) _stop();
    }
  }

  void _stop() {
    final v = _video;
    if (v == null) return;
    _position?.cancel();
    _position = null;
    _playing.remove(this);
    _video = null;
    _firstFrame = false;
    if (mounted && !_gone) setState(() {});
    unawaited(v.dispose());
    // the next card waiting for a player gets this one's place
    while (_waiting.isNotEmpty && _playing.length < _limit) {
      final next = _waiting.removeAt(0);
      if (next.mounted && !next._gone && next._wants) next._start();
    }
  }

  bool _gone = false;

  @override
  void dispose() {
    _gone = true;
    _waiting.remove(this);
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final v = _video;
    return VisibilityDetector(
      key: ValueKey('feed-video-${widget.item.media_id}'),
      onVisibilityChanged: (info) {
        final visible = info.visibleFraction >= 0.5;
        if (visible == _visible || !mounted) return;
        _visible = visible;
        _update();
      },
      child: Stack(fit: StackFit.expand, children: [
        if (v != null) VideoSurface(controller: v.surfaceController, controls: NoVideoControls, fill: Colors.transparent),
        if (v == null || !_firstFrame)
          _poster == null ? const SizedBox.expand() : Image.file(File(_poster!), fit: BoxFit.contain, gaplessPlayback: true),
        if (v == null) const Center(child: Icon(Icons.play_circle_outline, color: Colors.white70, size: 56)),
      ]),
    );
  }
}

/// A tag as the native cards show it: tinted by who added it (an AI's with a sparkle).
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, this.marks = const []});
  final TagView tag;
  final List<String> marks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ai = tag.origin & 2 != 0, user = tag.origin & 1 != 0;
    final color = ai && !user ? scheme.tertiary : scheme.primary;
    return Container(
      height: 28,
      decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (ai) Padding(padding: const EdgeInsets.only(right: 4), child: Icon(user ? Icons.verified : Icons.auto_awesome, size: 12, color: color)),
          Text.rich(markedSpan(tag.label, marks, TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w500), scheme)),
        ]),
      ),
    );
  }
}

/// [text] with the searched [terms] marked (case, width and accents folded, as the native apps).
TextSpan markedSpan(String text, List<String> terms, TextStyle? style, ColorScheme scheme) {
  final ranges = terms.isEmpty ? const <HighlightRange>[] : highlightRanges(terms, text);
  if (ranges.isEmpty) return TextSpan(text: text, style: style);
  final mark = (style ?? const TextStyle()).copyWith(backgroundColor: scheme.tertiaryContainer, color: scheme.onTertiaryContainer);
  final spans = <TextSpan>[];
  var at = 0;
  for (final r in ranges) {
    if (r.start > at) spans.add(TextSpan(text: text.substring(at, r.start)));
    spans.add(TextSpan(text: text.substring(r.start, r.end), style: mark));
    at = r.end;
  }
  if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: style, children: spans);
}

/// A button of the search row: a round plate, filled while on. The symbol stays the same in both
/// states and is never a filled or circled one: inside a round plate those read as a circle in a
/// circle.
/// The viewer's list for [cards] as they are on screen, and where [item] is in it.
(List<FeedItem>, int) viewerList(List<List<FeedItem>> cards, FeedItem item) {
  final items = [for (final card in cards) ...card];
  return (items, math.max(0, items.indexWhere((i) => i.media_id == item.media_id)));
}

/// A button that shrinks and fades out of its row, and grows back; the row closes up around it.
class CollapsingButton extends StatelessWidget {
  const CollapsingButton({super.key, required this.shown, required this.child});
  final bool shown;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(end: shown ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 260),
        curve: Curves.easeInOutCubic,
        child: IgnorePointer(ignoring: !shown, child: ExcludeSemantics(excluding: !shown, child: child)),
        builder: (context, t, child) => ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: t,
            child: Opacity(opacity: t, child: Transform.scale(scale: 0.6 + 0.4 * t, child: child)),
          ),
        ),
      );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.tooltip, required this.icon, required this.dense, required this.onPressed, this.selected = false});
  final String tooltip;
  final IconData icon;
  final bool dense, selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: IconButton(
        tooltip: tooltip,
        isSelected: selected,
        iconSize: 20,
        visualDensity: dense ? VisualDensity.compact : VisualDensity.standard,
        icon: Icon(icon),
        onPressed: onPressed,
        style: IconButton.styleFrom(
          // Material 3 Expressive: what is on changes shape as well as colour
          shape: selected ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)) : const CircleBorder(),
          animationDuration: const Duration(milliseconds: 220),
          backgroundColor: scheme.surfaceContainerHighest,
          foregroundColor: scheme.onSurface,
          hoverColor: scheme.onSurface.withValues(alpha: 0.08),
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : dense ? Colors.transparent : scheme.surfaceContainerHighest),
          foregroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        ),
      ),
    );
  }
}
