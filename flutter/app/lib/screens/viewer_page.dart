import '../actions/share_media.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';
import 'package:window_manager/window_manager.dart';

import '../app/library.dart';
import '../app/prefs.dart';
import '../l10n/l10n.dart';
import '../platform/desktop_window.dart';
import 'video_page.dart';
import '../widgets/media_image.dart';
import '../widgets/text_menu.dart';
import '../widgets/wheel_pager.dart';

/// The full-screen viewer over a list (a grid's, 浏览's), as the native one:
///  * swipe sideways through every photo and video of the list (a video whose drags are on keeps
///    the sideways swipe: its arrows turn the page); ← → on a keyboard, and the arrows on desktops
///  * a photo zooms with a pinch or a double tap; a tap or a swipe down closes it (a tap does not
///    close on a desktop, where it is easily a stray click)
///  * the post's caption over the bottom (cut to three lines, a tap opens all of it), under one
///    shade with the bar: counter, share, close
///  * Windows and Linux: one scroll of the wheel or trackpad, one page (Ctrl + wheel zooms a photo;
///    on a photo already zoomed the wheel goes on zooming)
///  * keys: Esc closes, Space plays or pauses, ↑ ↓ the volume, F full screen (desktops)
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key, required this.library, required this.items, required this.index});
  final LibraryModel library;
  final List<FeedItem> items;
  final int index;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _index = widget.index;
  final _videos = <String, GlobalKey<VideoPageState>>{};
  bool _zoomed = false;
  final _shareAnchor = GlobalKey();

  FeedItem get _item => widget.items[_index];
  bool get _isVideo => _item.kind == MediaKind.video;
  static bool get _desktop => DesktopWindow.isDesktop;

  VideoPageState? get _video => _isVideo ? _videoKey(_item).currentState : null;

  GlobalKey<VideoPageState> _videoKey(FeedItem i) => _videos.putIfAbsent(i.media_id, GlobalKey<VideoPageState>.new);

  /// A video on screen turned on its own (its rotate button, auto-landscape): no paging while it
  /// is (a swipe would cross the turned picture). The app's orientation is never changed.
  bool _turned = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _prepareNeighbours();
  }

  /// The photos beside this one are decoded before they are turned to: otherwise the page slides
  /// in black and the picture appears after it.
  void _prepareNeighbours() {
    final px = _PhotoPageState.pixels(context);
    for (final i in [_index - 1, _index + 1]) {
      if (i < 0 || i >= widget.items.length || widget.items[i].kind == MediaKind.video) continue;
      precacheImage(_PhotoPageState.image(widget.items[i], px), context, onError: (_, _) {});
    }
  }

  void _turn(bool turned) {
    if (turned != _turned && mounted) setState(() => _turned = turned);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  bool _closing = false;

  /// Where the page is heading while it moves: [_index] follows only halfway through a turn, and a
  /// step taken before that would aim at the same page again.
  int? _heading;

  void _step(int d) {
    final i = (_heading ?? _index) + d;
    if (i < 0 || i >= widget.items.length) return;
    _heading = i;
    _pages.animateToPage(i, duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic).whenComplete(() {
      if (_heading == i) _heading = null;
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    if (mounted) Navigator.of(context).pop();
  }

  /// [at]: where to open (a video's button, the mouse); otherwise at the photo bar's button.
  Future<void> _share([Rect? at]) async {
    final box = (_shareAnchor.currentContext?.findRenderObject() as RenderBox?);
    final origin = at ?? (box == null ? null : box.localToGlobal(Offset.zero) & box.size);
    await shareMedia(context, _item.path, anchor: origin);
  }

  /// A mouse: its back and forward buttons turn the page.
  void _pointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if (e.buttons & kBackMouseButton != 0) _step(-1);
    if (e.buttons & kForwardMouseButton != 0) _step(1);
  }

  Future<void> _fullScreen() async {
    if (!_desktop) return;
    try {
      await windowManager.setFullScreen(!await windowManager.isFullScreen());
    } catch (_) {}
  }

  /// A video page's drags hold the sideways swipe (its arrows turn the page instead).
  bool get _pagingLocked => _zoomed || (_isVideo && !Prefs.instance.playerGesturesOff);

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        // the player is looked up when the key comes (it is made after the first build)
        const SingleActivator(LogicalKeyboardKey.space): () => _video?.togglePlay(),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _video?.stepVolume(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _video?.stepVolume(-1),
        const SingleActivator(LogicalKeyboardKey.keyF): _fullScreen,
      },
      child: PopScope(
        canPop: true,
        child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: _pointerDown,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onSecondaryTapUp: (d) => _share(d.globalPosition & Size.zero),
                  child: WheelPager(
                enabled: !_zoomed,
                onStep: _step,
                child: PageView.builder(
                key: const ValueKey('viewerPages'),
                controller: _pages,
                scrollBehavior: pageBehavior(context),
                physics: _pagingLocked || _turned ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                itemCount: widget.items.length,
                onPageChanged: (i) {
                  setState(() {
                    _index = i;
                    _zoomed = false;
                    _turned = false;
                  });
                  _prepareNeighbours();
                },
                itemBuilder: (context, i) {
                  final item = widget.items[i];
                  if (item.kind == MediaKind.video) {
                    return WheelGuard(child: VideoPage(
                      key: _videoKey(item),
                      path: item.path,
                      active: i == _index,
                      caption: _hasCaption(item) ? _Caption(key: ValueKey('cap-${item.post_id}'), item: item) : null,
                      counter: '${i + 1} / ${widget.items.length}',
                      onClose: _close,
                      onStep: _step,
                      onShare: _share,
                      canPrevious: i > 0,
                      canNext: i < widget.items.length - 1,
                      onTurn: _turn,
                    ));
                  }
                  return _PhotoPage(
                    key: ValueKey('photo-${item.media_id}'),
                    item: item,
                    onZoomed: (z) {
                      if (i == _index && z != _zoomed) setState(() => _zoomed = z);
                    },
                    onClose: _close,
                    closeOnTap: !_desktop,
                  );
                },
              ),
                  ),
                ),
              ),
            ),
            if (_desktop && !_isVideo && !_zoomed) ...[
              if (_index > 0) _EdgeArrow(key: const ValueKey('viewerPrevious'), left: true, tooltip: L('viewer.previous.mac'), onTap: () => _step(-1)),
              if (_index < widget.items.length - 1) _EdgeArrow(key: const ValueKey('viewerNext'), left: false, tooltip: L('viewer.next.mac'), onTap: () => _step(1)),
            ],
            // a photo's caption and bar, under one shade to the bottom edge (a video has its own)
            if (!_isVideo)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _Shade(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16 + pad.left, 36, 16 + pad.right, 8 + pad.bottom),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (_hasCaption(_item)) _Caption(key: ValueKey('cap-${_item.post_id}'), item: _item),
                      Row(children: [
                        Text('${_index + 1} / ${widget.items.length}',
                            key: const ValueKey('photoCounter'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_desktop) ...[
                          IconButton(color: Colors.white, tooltip: L('viewer.previous.mac'), icon: const Icon(Icons.chevron_left), onPressed: _index > 0 ? () => _step(-1) : null),
                          IconButton(color: Colors.white, tooltip: L('viewer.next.mac'), icon: const Icon(Icons.chevron_right), onPressed: _index < widget.items.length - 1 ? () => _step(1) : null),
                        ],
                        IconButton(key: _shareAnchor, color: Colors.white, tooltip: L('viewer.share'), icon: const Icon(Icons.ios_share), onPressed: _share),
                        IconButton(key: const ValueKey('viewerClose'), color: Colors.white, tooltip: _desktop ? L('viewer.close.mac') : L('viewer.close'), icon: const Icon(Icons.close), onPressed: _close),
                      ]),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
      ),
      ),
    );
  }

  static bool _hasCaption(FeedItem i) =>
      !i.post_id.startsWith('loose:') && ((i.text ?? '').isNotEmpty || i.author_name != null || i.screen_name != null);
}

/// A photo's side, for a mouse: a click there turns the page; the arrow shows while the mouse is over it.
class _EdgeArrow extends StatefulWidget {
  const _EdgeArrow({super.key, required this.left, required this.tooltip, required this.onTap});
  final bool left;
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_EdgeArrow> createState() => _EdgeArrowState();
}

class _EdgeArrowState extends State<_EdgeArrow> {
  bool _over = false;

  @override
  Widget build(BuildContext context) => Positioned(
        left: widget.left ? 0 : null,
        right: widget.left ? null : 0,
        top: 0,
        bottom: 120,
        width: 96,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _over = true),
          onExit: (_) => setState(() => _over = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: Center(
              child: AnimatedOpacity(
                opacity: _over ? 1 : 0,
                duration: const Duration(milliseconds: 120),
                child: Tooltip(
                  message: widget.tooltip,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(color: Colors.black45, shape: BoxShape.circle),
                    child: Padding(padding: const EdgeInsets.all(10), child: Icon(widget.left ? Icons.chevron_left : Icons.chevron_right, color: Colors.white, size: 30)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
}

/// The shade under the caption and the controls: clear at its top, dark at the bottom edge,
/// one piece (it never ends in a line across the media).
class _Shade extends StatelessWidget {
  const _Shade({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00000000), Color(0x8C000000), Color(0xB3000000)],
            stops: [0, 0.35, 1],
          ),
        ),
        child: child,
      );
}

/// One photo: pinch or double-tap to zoom; unzoomed, a tap or a swipe down closes the viewer.
class _PhotoPage extends StatefulWidget {
  const _PhotoPage({super.key, required this.item, required this.onZoomed, required this.onClose, required this.closeOnTap});
  final FeedItem item;
  final ValueChanged<bool> onZoomed;
  final VoidCallback onClose;
  final bool closeOnTap;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomAnim;
  Offset _tapAt = Offset.zero;
  double _down = 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_keys);
    _transform.addListener(() {
      final zoomed = _zoomed;
      if (zoomed != _wasZoomed) {
        setState(() => _wasZoomed = zoomed);
        widget.onZoomed(zoomed);
      }
    });
    _anim.addListener(() {
      final a = _zoomAnim;
      if (a != null) _transform.value = a.value;
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keys);
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool _wasZoomed = false;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

  bool _ctrl = false;

  bool _keys(KeyEvent _) {
    final held = HardwareKeyboard.instance.isControlPressed;
    if (held != _ctrl && mounted) setState(() => _ctrl = held);
    return false;
  }

  static int pixels(BuildContext context) => (MediaQuery.sizeOf(context).longestSide * MediaQuery.devicePixelRatioOf(context)).ceil();
  static ImageProvider image(FeedItem item, int px) => mediaImage(item.path, cacheWidth: px.clamp(512, 4096), maxSide: 4096);

  void _doubleTap() {
    final end = _zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translateByDouble(-_tapAt.dx * 1.5, -_tapAt.dy * 1.5, 0, 1)
          ..scaleByDouble(2.5, 2.5, 1, 1));
    _zoomAnim = Matrix4Tween(begin: _transform.value, end: end).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
    _anim.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final px = pixels(context);
    return GestureDetector(
      onTap: widget.closeOnTap ? () => _zoomed ? null : widget.onClose() : null,
      onDoubleTapDown: (d) => _tapAt = d.localPosition,
      onDoubleTap: _doubleTap,
      // fingers only: a mouse's drag or a trackpad's swipe must not close the viewer
      child: GestureDetector(
        supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus},
        onVerticalDragUpdate: _zoomed ? null : (d) => _down += d.delta.dy,
        onVerticalDragStart: _zoomed ? null : (_) => _down = 0,
        onVerticalDragEnd: _zoomed ? null : (d) {
          if (!_zoomed && (_down > 120 || (d.primaryVelocity ?? 0) > 700)) widget.onClose();
        },
        child: MouseRegion(
          cursor: _zoomed ? SystemMouseCursors.grab : MouseCursor.defer,
          child: InteractiveViewer(
            transformationController: _transform,
            onInteractionStart: (_) => _anim.stop(),
            maxScale: 6,
            scaleFactor: photoScaleFactor(zoomed: _zoomed, ctrl: _ctrl),
            child: WheelGuard(
              child: Center(
                child: Image(
                  image: image(widget.item, px),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 56),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The post: the author, the text cut to three lines (a tap opens all of it and closes it again).
/// It draws no shade of its own: it sits in the viewer's or the player's.
class _Caption extends StatefulWidget {
  const _Caption({super.key, required this.item});
  final FeedItem item;

  @override
  State<_Caption> createState() => _CaptionState();
}

class _CaptionState extends State<_Caption> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final h = MediaQuery.sizeOf(context).height;
    final author = [if (i.author_name != null) i.author_name!, if (i.screen_name != null) '@${i.screen_name}'].join('  ');
    const textStyle = TextStyle(color: Colors.white, fontSize: 15, height: 1.35);
    return GestureDetector(
      key: const ValueKey('postCaption'),
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _open = !_open),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 680, maxHeight: _open ? h * 0.45 : double.infinity),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (author.isNotEmpty) Text(author, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            if ((i.text ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Flexible(
                child: _open
                    ? SingleChildScrollView(child: SelectableText(contextMenuBuilder: appTextMenu, i.text!, style: textStyle))
                    : Text(i.text!, maxLines: 3, overflow: TextOverflow.ellipsis, style: textStyle),
              ),
            ],
            if (_open) TextButton(onPressed: () => setState(() => _open = false), child: Text(L('caption.less'))),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    );
  }
}
