import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import '../actions/share_media.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import '../app/library.dart';
import '../app/prefs.dart';
import '../l10n/l10n.dart';
import '../platform/video.dart';
import 'video_page.dart';
import '../widgets/media_image.dart';
import '../widgets/text_menu.dart';
import '../app/activity.dart';

/// The full-screen viewer over a list (a grid's, 浏览's), as the native one:
///  * opens with a smooth zoom transition from the tapped card or grid tile, and shrinks back
///    into the current item's card or tile on close
///  * swipe sideways in the middle of the screen through every photo and video of the list (a
///    video whose drags are on keeps the sideways swipe for seeking: its arrows turn the page);
///    ← → on a keyboard
///  * as native, the media follows the finger out: a swipe in from either side edge, or a swipe
///    down (a photo, or a video whose drags are off), shrinks it and clears the background; let
///    go far or fast enough and it zooms back into its card, otherwise it springs back
///  * a photo zooms with a pinch or a double tap; a tap closes it
///  * the post's caption over the bottom (cut to three lines, a tap opens all of it), under one
///    shade with the bar: counter, share, close
///  * keys: Esc closes, Space plays or pauses, ↑ ↓ the volume
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.library,
    required this.items,
    required this.index,
    this.sourceRect,
    this.sourceBorderRadius = const BorderRadius.all(Radius.circular(12)),
    this.cropSource = false,
    this.previewCacheWidth,
    this.routeAnimation,
  });

  final LibraryModel library;
  final List<FeedItem> items;
  final int index;
  /// Where [item] currently sits on the underlying page (浏览 or 照片网格), in global screen
  /// coordinates, for the zoom-in and zoom-out transition.
  final Rect? Function(FeedItem item)? sourceRect;
  final BorderRadius sourceBorderRadius;
  /// True when the source crops the media to fill its rect (a square grid tile).
  final bool cropSource;
  /// Optional cacheWidth used by the source card, so the already-decoded image shows on frame 0.
  final int? Function(String mediaId)? previewCacheWidth;
  final Animation<double>? routeAnimation;

  /// The `media_id` currently shown in the open viewer (so the underlying card or grid tile hides
  /// its own copy while the viewer zooms out of or back into it).
  static final activeMediaId = ValueNotifier<String?>(null);

  /// The viewer that set [activeMediaId]: one opened while the last is still zooming out owns it,
  /// and the closing one must not clear it under the new one (its tile would show twice).
  static Object? _activeOwner;

  /// Pushes [ViewerPage] with a zoom transition from and back to [sourceRect].
  static Future<void> push(
    BuildContext context, {
    required LibraryModel library,
    required List<FeedItem> items,
    required int index,
    Rect? Function(FeedItem item)? sourceRect,
    BorderRadius sourceBorderRadius = const BorderRadius.all(Radius.circular(12)),
    bool cropSource = false,
    int? Function(String mediaId)? previewCacheWidth,
  }) {
    final safeIndex = index.clamp(0, math.max<int>(0, items.length - 1));
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.transparent,
        // quick, as Photos: a tap on the grid while it zooms out is answered (the closing route
        // takes no taps), and opens the next viewer
        transitionDuration: const Duration(milliseconds: 140),
        reverseTransitionDuration: const Duration(milliseconds: 125),
        pageBuilder: (context, animation, secondaryAnimation) => ViewerPage(
          library: library,
          items: items,
          index: safeIndex,
          sourceRect: sourceRect,
          sourceBorderRadius: sourceBorderRadius,
          cropSource: cropSource,
          previewCacheWidth: previewCacheWidth,
          routeAnimation: animation,
        ),
      ),
    );
  }

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

/// What an interactive dismiss drag currently does to the viewer's media.
@immutable
class _Dismiss {
  const _Dismiss(this.offset, this.scale, this.progress);
  static const none = _Dismiss(Offset.zero, 1, 0);
  final Offset offset;
  final double scale;
  /// 0 (untouched) .. 1 (far enough that the background has gone).
  final double progress;
}

/// A drag that only starts where [allowStart] says (the screen's side edges, or anywhere) and
/// only claims the gesture once its movement satisfies [accepts] — with a slop smaller than the
/// pager's and the video page's own drags, so it wins against them in its direction while every
/// other direction is left to them.
class _DismissDrag extends PanGestureRecognizer {
  _DismissDrag({required this.allowStart, required this.accepts})
      : super(supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus}) {
    dragStartBehavior = DragStartBehavior.down;
    minFlingDistance = 4.0;
    minFlingVelocity = 50.0;
  }

  bool Function(Offset globalStart) allowStart;
  bool Function(Offset globalStart, Offset moved) accepts;
  int? _pointer;
  bool _accepted = false;
  Offset _start = Offset.zero;
  Offset _moved = Offset.zero;

  @override
  bool isPointerAllowed(PointerEvent event) {
    if (_pointer != null) {
      return false;
    }
    return super.isPointerAllowed(event) && allowStart(event.position);
  }

  @override
  void handleNonAllowedPointer(PointerDownEvent event) {
    // Yield to a two-finger pinch before dismiss engages; ignore extra fingers once active.
    if (!_accepted) super.handleNonAllowedPointer(event);
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _pointer = event.pointer;
    _accepted = false;
    _start = event.position;
    _moved = Offset.zero;
    super.addAllowedPointer(event);
  }

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    super.acceptGesture(pointer);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && event.pointer == _pointer) {
      _moved = event.position - _start;
    }
    super.handleEvent(event);
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      !_accepted && accepts(_start, _moved);

  @override
  void didStopTrackingLastPointer(int pointer) {
    _pointer = null;
    _accepted = false;
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  String get debugDescription => 'viewer dismiss drag';
}

/// The same drag from a side edge (its own type: one recognizer per type in a detector).
class _EdgeDismissDrag extends _DismissDrag {
  _EdgeDismissDrag({required super.allowStart, required super.accepts});

  @override
  String get debugDescription => 'viewer edge dismiss drag';
}

class _ViewerPageState extends State<ViewerPage> with SingleTickerProviderStateMixin {
  late final PageController _pages = PageController(initialPage: widget.index);

  /// The interactive dismiss (a swipe down, or a swipe in from a side edge): the media follows
  /// the finger and shrinks, the background clears; let go far or fast enough and the viewer
  /// zooms back into the card from where the finger left it, otherwise it springs back.
  final _dismiss = ValueNotifier<_Dismiss>(_Dismiss.none);
  final _dismissProgress = ValueNotifier<double>(0);
  late final AnimationController _springBack = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  Offset _rawOffset = Offset.zero;
  Offset _springFrom = Offset.zero;
  bool _dragFromEdge = false;
  int _edgeDir = 1;
  BuildContext? _expandedCaption;

  static double _edgeWidthFor(double screenWidth) => (screenWidth * 0.10).clamp(32.0, 48.0);
  late int _index = widget.index;
  final _videos = <String, GlobalKey<VideoPageState>>{};
  bool _zoomed = false;
  final _shareAnchor = GlobalKey();

  FeedItem get _item => widget.items[_index];
  bool get _isVideo => _item.kind == MediaKind.video;

  VideoPageState? get _video => _isVideo ? _videoKey(_item).currentState : null;

  GlobalKey<VideoPageState> _videoKey(FeedItem i) => _videos.putIfAbsent(i.media_id, GlobalKey<VideoPageState>.new);

  /// A video on screen turned on its own (its rotate button, auto-landscape): no paging while it
  /// is (a swipe would cross the turned picture). The app's orientation is never changed.
  bool _turned = false;

  @override
  void initState() {
    super.initState();
    _springBack.addListener(_onSpringBack);
    widget.routeAnimation?.addListener(_onRouteAnimation);
    // the progress panel steps aside (after this frame: listeners may not rebuild during a build)
    scheduleMicrotask(() {
      immersivePages.value++;
      // If pushed without a zoom route animation, hide the source immediately.
      // With a route animation, _onRouteAnimation hides it once Frame 0 has painted (anim.value > 0)
      // so the source remains visible beneath Frame 0 and never flashes a blank slot.
      if (widget.routeAnimation == null && widget.items.isNotEmpty) {
        _claim(_item.media_id);
      }
    });
  }

  void _claim(String mediaId) {
    ViewerPage._activeOwner = this;
    ViewerPage.activeMediaId.value = mediaId;
  }

  /// Clears [ViewerPage.activeMediaId] only if this viewer set it.
  void _release() {
    if (ViewerPage._activeOwner != this) return;
    ViewerPage._activeOwner = null;
    ViewerPage.activeMediaId.value = null;
  }

  void _onRouteAnimation() {
    final anim = widget.routeAnimation;
    if (anim == null) return;
    if (anim.status == AnimationStatus.forward || anim.status == AnimationStatus.completed) {
      if (anim.value > 0.0 && widget.items.isNotEmpty && ViewerPage.activeMediaId.value != _item.media_id) {
        _claim(_item.media_id);
      }
    } else if (anim.status == AnimationStatus.reverse) {
      if (!_closing) {
        _closing = true;
        VideoSession.willCloseViewer();
        _video?.leaveForCard();
      }
      // Unhide the underlying card or grid tile during the animation tick just as the flying
      // media lands on top of it (t = 4 * 0.12^3 = 0.007), BEFORE the flying layer dissolves
      // and BEFORE the route is removed from the Overlay, eliminating any 1-frame blank flash.
      if (anim.value <= 0.12 && ViewerPage.activeMediaId.value != null) {
        _release();
      }
    } else if (anim.status == AnimationStatus.dismissed) {
      if (ViewerPage.activeMediaId.value != null) {
        _release();
      }
    }
  }

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

  // ---- the interactive dismiss

  bool get _dismissBlocked => _closing || _zoomed || widget.items.isEmpty || (_video?.locked ?? false);

  void _setExpandedCaption(BuildContext? ctx, bool open) {
    if (open) {
      _expandedCaption = ctx;
    } else if (_expandedCaption == ctx) {
      _expandedCaption = null;
    }
  }

  bool _inExpandedCaption(Offset global) {
    final c = _expandedCaption;
    if (c == null || !c.mounted) return false;
    final box = c.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    return (box.localToGlobal(Offset.zero) & box.size).contains(global);
  }

  /// From a side edge: always (a photo, a video with or without its drags), unless zoomed in,
  /// the video is locked, or touching inside an expanded scrollable caption.
  /// In the middle a sideways swipe stays the pager's (or the video's seek).
  bool _edgeAllowed(Offset global) {
    if (_dismissBlocked) return false;
    final w = MediaQuery.sizeOf(context).width;
    if (w <= 0) return false;
    final edge = _edgeWidthFor(w);
    if (global.dx > edge && global.dx < w - edge) return false;
    return !_inExpandedCaption(global);
  }

  bool _edgeAccepts(Offset start, Offset moved) {
    final w = MediaQuery.sizeOf(context).width;
    final dir = start.dx <= w / 2 ? 1.0 : -1.0;
    final inward = moved.dx * dir;
    return inward > 6.0 && moved.dx.abs() > moved.dy.abs() * 0.9;
  }

  /// A swipe down: a photo (unzoomed) or a video whose drags are off; with its drags on, a
  /// vertical drag is the video's brightness or volume.
  bool _downAllowedAt(Offset global) {
    if (_dismissBlocked) return false;
    if (_isVideo && !Prefs.instance.playerGesturesOff) return false;
    return !_inExpandedCaption(global);
  }

  bool _downAccepts(Offset start, Offset moved) =>
      moved.dy > 7.0 && moved.dy > moved.dx.abs() * 1.15;

  void _setDismiss(_Dismiss value) {
    _dismiss.value = value;
    _dismissProgress.value = value.progress;
  }

  _Dismiss _dismissFor(Offset raw) {
    final size = MediaQuery.sizeOf(context);
    final Offset visual;
    final double distance;
    final double extent;
    if (_dragFromEdge) {
      final inward = raw.dx * _edgeDir;
      final dampedDx = inward < 0 ? raw.dx * 0.28 : raw.dx;
      visual = Offset(dampedDx, raw.dy);
      distance = math.max(0.0, inward);
      extent = math.min(size.width * 0.50, 240.0);
    } else {
      final dampedDy = raw.dy < 0 ? raw.dy * 0.28 : raw.dy;
      visual = Offset(raw.dx, dampedDy);
      distance = math.max(0.0, raw.dy);
      extent = math.min(size.height * 0.45, 320.0);
    }
    final progress = extent <= 0 ? 0.0 : (distance / extent).clamp(0.0, 1.0);
    return _Dismiss(visual, 1.0 - 0.34 * progress, progress);
  }

  void _dismissStart(bool fromEdge, DragStartDetails d) {
    _springBack.stop();
    _dragFromEdge = fromEdge;
    if (fromEdge) {
      final w = MediaQuery.sizeOf(context).width;
      _edgeDir = d.globalPosition.dx <= w / 2 ? 1 : -1;
    }
    _rawOffset = _dismiss.value.offset;
  }

  void _dismissUpdate(DragUpdateDetails d) {
    if (_closing) return;
    _rawOffset += d.delta;
    _setDismiss(_dismissFor(_rawOffset));
  }

  void _dismissEnd(DragEndDetails d) {
    if (_closing) return;
    final size = MediaQuery.sizeOf(context);
    final v = d.velocity.pixelsPerSecond;
    final bool close;
    if (_dragFromEdge) {
      final inward = _rawOffset.dx * _edgeDir;
      final vx = v.dx * _edgeDir;
      final distThreshold = math.min(size.width * 0.18, 96.0);
      close = vx >= -250 && (inward > distThreshold || (vx > 320 && inward > 8));
    } else {
      final distThreshold = math.min(size.height * 0.12, 84.0);
      close = v.dy >= -250 && (_rawOffset.dy > distThreshold || (v.dy > 280 && _rawOffset.dy > 8));
    }
    if (close) {
      _close();
    } else {
      _dismissCancel();
    }
  }

  void _dismissCancel() {
    if (_closing || (_rawOffset == Offset.zero && _dismiss.value.offset == Offset.zero)) return;
    _springFrom = _rawOffset;
    _springBack.forward(from: 0);
  }

  void _onSpringBack() {
    final t = Curves.easeOutCubic.transform(_springBack.value);
    _rawOffset = Offset.lerp(_springFrom, Offset.zero, t)!;
    _setDismiss(_dismissFor(_rawOffset));
  }

  @override
  void dispose() {
    widget.routeAnimation?.removeListener(_onRouteAnimation);
    scheduleMicrotask(() {
      immersivePages.value--;
      _release();
      VideoSession.endViewer();
    });
    _pages.dispose();
    _springBack.dispose();
    _dismiss.dispose();
    _dismissProgress.dispose();
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

  void _close() {
    if (_closing) return;
    _closing = true;
    _springBack.stop();
    VideoSession.willCloseViewer();
    _video?.leaveForCard();
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

  /// A video page's drags hold the sideways swipe (its arrows turn the page instead).
  bool get _pagingLocked => _zoomed || (_isVideo && !Prefs.instance.playerGesturesOff);

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    final routeAnim = widget.routeAnimation;
    final Animation<double> flightAnim = routeAnim ?? kAlwaysCompleteAnimation;

    final Widget pager = Listener(
      onPointerDown: _pointerDown,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: (d) => _share(d.globalPosition & Size.zero),
        child: PageView.builder(
          key: const ValueKey('viewerPages'),
          controller: _pages,
          physics: _pagingLocked || _turned ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
          itemCount: widget.items.length,
          onPageChanged: (i) {
            setState(() {
              _index = i;
              _zoomed = false;
              _turned = false;
            });
            _claim(widget.items[i].media_id);
            _prepareNeighbours();
          },
          itemBuilder: (context, i) {
            final item = widget.items[i];
            final thumb = widget.library.thumbsIfReady?.peek(item.media_id);
            final thumbWidget = thumb == null
                ? null
                : _ThumbPreview(
                    image: thumb,
                    item: item,
                    cropSquare: widget.cropSource,
                  );
            if (item.kind == MediaKind.video) {
              VideoSession.forItem(item, cacheDir: widget.library.thumbsIfReady?.cacheDir);
              return VideoPage(
                key: _videoKey(item),
                path: item.path,
                active: i == _index,
                caption: _hasCaption(item)
                    ? _Caption(key: ValueKey('cap-${item.post_id}'), item: item, onExpandedChanged: _setExpandedCaption)
                    : null,
                counter: '${i + 1} / ${widget.items.length}',
                onClose: _close,
                onStep: _step,
                onShare: _share,
                canPrevious: i > 0,
                canNext: i < widget.items.length - 1,
                onTurn: _turn,
                fallbackPreview: thumbWidget != null ? IgnorePointer(child: thumbWidget) : null,
                routeAnimation: routeAnim,
                dismissProgress: _dismissProgress,
              );
            }
            return _PhotoPage(
              key: ValueKey('photo-${item.media_id}'),
              item: item,
              previewCacheWidth: widget.previewCacheWidth?.call(item.media_id),
              thumbFallback: thumb,
              cropSource: widget.cropSource,
              onZoomed: (z) {
                if (i == _index && z != _zoomed) setState(() => _zoomed = z);
              },
              onClose: _close,
              closeOnTap: true,
            );
          },
        ),
      ),
    );

    final Widget photoBar = _Shade(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16 + pad.left, 36, 16 + pad.right, 8 + pad.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_hasCaption(_item)) _Caption(key: ValueKey('cap-${_item.post_id}'), item: _item, onExpandedChanged: _setExpandedCaption),
          Row(children: [
            Text('${_index + 1} / ${widget.items.length}',
                key: const ValueKey('photoCounter'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(key: _shareAnchor, color: Colors.white, tooltip: L('viewer.share'), icon: const Icon(Icons.ios_share), onPressed: _share),
            IconButton(key: const ValueKey('viewerClose'), color: Colors.white, tooltip: L('viewer.close'), icon: const Icon(Icons.close), onPressed: _close),
          ]),
        ]),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): _close,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.space): () => _video?.togglePlay(),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _video?.stepVolume(1),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _video?.stepVolume(-1),
      },
      child: PopScope(
        canPop: true,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _springBack.stop();
            VideoSession.willCloseViewer();
            _video?.leaveForCard();
            if (widget.routeAnimation == null) {
              _release();
            }
          }
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Stack(children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: Listenable.merge([flightAnim, _dismiss]),
                  builder: (context, _) => ColoredBox(
                    color: Colors.black.withValues(
                      alpha: Curves.easeOut.transform(flightAnim.value.clamp(0.0, 1.0)) * (1 - _dismiss.value.progress),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: _ZoomFlight(
                  animation: flightAnim,
                  dismiss: _dismiss,
                  item: _item,
                  sourceRect: routeAnim == null ? null : widget.sourceRect,
                  sourceBorderRadius: widget.sourceBorderRadius,
                  cropSource: widget.cropSource,
                  child: pager,
                ),
              ),
              if (!_isVideo)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AnimatedBuilder(
                    animation: Listenable.merge([flightAnim, _dismiss]),
                    child: photoBar,
                    builder: (context, child) => Opacity(
                      opacity: Curves.easeIn.transform(((flightAnim.value - 0.25) / 0.75).clamp(0.0, 1.0)) *
                          (1 - _dismiss.value.progress * 4).clamp(0.0, 1.0),
                      child: child,
                    ),
                  ),
                ),
              // Translucent dismiss overlay sits top-most so side-edge and downward swipes enter the
              // gesture arena ahead of PageView, InteractiveViewer, and VideoPage even on a fast
              // 1-frame flick, while taps, middle paging, pinch-zoom, and captions still hit underneath.
              Positioned.fill(
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  gestures: {
                    _EdgeDismissDrag: GestureRecognizerFactoryWithHandlers<_EdgeDismissDrag>(
                      () => _EdgeDismissDrag(allowStart: _edgeAllowed, accepts: _edgeAccepts),
                      (r) => r
                        ..allowStart = _edgeAllowed
                        ..accepts = _edgeAccepts
                        ..onStart = ((d) => _dismissStart(true, d))
                        ..onUpdate = _dismissUpdate
                        ..onEnd = _dismissEnd
                        ..onCancel = _dismissCancel,
                    ),
                    _DismissDrag: GestureRecognizerFactoryWithHandlers<_DismissDrag>(
                      () => _DismissDrag(allowStart: _downAllowedAt, accepts: _downAccepts),
                      (r) => r
                        ..allowStart = _downAllowedAt
                        ..accepts = _downAccepts
                        ..onStart = ((d) => _dismissStart(false, d))
                        ..onUpdate = _dismissUpdate
                        ..onEnd = _dismissEnd
                        ..onCancel = _dismissCancel,
                    ),
                  },
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

/// Smoothly zooms and un-crops the viewer's media from [sourceRect] on the underlying page
/// (a card in 浏览 or a square tile in 照片网格) into full screen on push, and back on pop.
class _ZoomFlight extends StatelessWidget {
  const _ZoomFlight({
    required this.animation,
    required this.dismiss,
    required this.item,
    required this.sourceRect,
    required this.sourceBorderRadius,
    required this.cropSource,
    required this.child,
  });

  final Animation<double> animation;
  /// Where an interactive dismiss drag holds the media: the flight back to the card starts there.
  final ValueListenable<_Dismiss> dismiss;
  final FeedItem item;
  final Rect? Function(FeedItem item)? sourceRect;
  final BorderRadius sourceBorderRadius;
  final bool cropSource;
  final Widget child;

  static Rect _fittedRect(Size bounds, double aspect) {
    if (bounds.isEmpty || aspect <= 0) return Offset.zero & bounds;
    final screenAspect = bounds.width / bounds.height;
    final double w, h;
    if (aspect > screenAspect) {
      w = bounds.width;
      h = w / aspect;
    } else {
      h = bounds.height;
      w = h * aspect;
    }
    return Rect.fromCenter(
      center: bounds.center(Offset.zero),
      width: w,
      height: h,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the widget tree depth (Opacity -> Transform -> ClipRRect -> child) strictly invariant
    // across raw = 0.0 .. 1.0 so PageView / _PhotoPage / VideoPage are NEVER unmounted or
    // remounted when the animation settles (raw >= 0.999), reverses, or finishes.
    return AnimatedBuilder(
      animation: Listenable.merge([animation, dismiss]),
      child: child,
      builder: (context, child) {
        final raw = animation.value.clamp(0.0, 1.0);
        final screen = MediaQuery.sizeOf(context);
        final fullRect = Offset.zero & screen;
        final drag = dismiss.value;

        double opacity = 1.0;
        // at rest (and while dragged): the media follows the finger and shrinks about its centre
        Matrix4 matrix = drag.offset == Offset.zero && drag.scale == 1
            ? Matrix4.identity()
            : (Matrix4.identity()
              ..translateByDouble(fullRect.center.dx + drag.offset.dx, fullRect.center.dy + drag.offset.dy, 0, 1)
              ..scaleByDouble(drag.scale, drag.scale, 1, 1)
              ..translateByDouble(-fullRect.center.dx, -fullRect.center.dy, 0, 1));
        Rect clipRect = fullRect;
        BorderRadius radius = BorderRadius.zero;
        Clip clipBehavior = Clip.none;

        if (raw < 0.999 && !screen.isEmpty) {
          final t = animation.status == AnimationStatus.reverse
              ? 1 - Curves.easeOutCubic.transform(1 - raw)
              : Curves.easeInOutCubic.transform(raw);
          final src = sourceRect?.call(item);
          if (src == null || src.isEmpty) {
            opacity = t;
            final s = (0.92 + 0.08 * t) * drag.scale;
            final c = fullRect.center;
            matrix = Matrix4.identity()
              ..translateByDouble(c.dx + drag.offset.dx, c.dy + drag.offset.dy, 0, 1)
              ..scaleByDouble(s, s, 1, 1)
              ..translateByDouble(-c.dx, -c.dy, 0, 1);
          } else {
            final sessionAspect = item.kind == MediaKind.video ? VideoSession.of(item.path).aspectRatio : null;
            final aspect = sessionAspect ??
                ((item.width > 0 && item.height > 0)
                    ? item.width / item.height
                    : item.cardAspectRatio);
            final dst = _fittedRect(screen, aspect);
            if (!dst.isEmpty) {
              // the full-screen end of the flight, moved and shrunk by a dismiss drag
              final endCenter = dst.center + drag.offset;
              final endScale = drag.scale;
              final scale0 = cropSource
                  ? math.max(src.width / dst.width, src.height / dst.height)
                  : math.min(src.width / dst.width, src.height / dst.height);
              final scale = ui.lerpDouble(scale0, endScale, t)!;
              final center = Offset.lerp(src.center, endCenter, t)!;

              final screenW = ui.lerpDouble(src.width, dst.width * endScale, t)!;
              final screenH = ui.lerpDouble(src.height, dst.height * endScale, t)!;
              clipRect = Rect.fromCenter(
                center: dst.center,
                width: screenW / scale,
                height: screenH / scale,
              );
              radius = BorderRadius.lerp(sourceBorderRadius, BorderRadius.zero, t)! / scale;
              clipBehavior = Clip.antiAlias;

              matrix = Matrix4.identity()
                ..translateByDouble(center.dx, center.dy, 0, 1)
                ..scaleByDouble(scale, scale, 1, 1)
                ..translateByDouble(-dst.center.dx, -dst.center.dy, 0, 1);
            }
          }
          if (animation.status == AnimationStatus.reverse && raw < 0.10) {
            opacity *= (raw / 0.10).clamp(0.0, 1.0);
          }
        }

        return Opacity(
          opacity: opacity,
          child: Transform(
            transform: matrix,
            child: ClipRRect(
              clipBehavior: clipBehavior,
              clipper: _RectClipper(clipRect, radius),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

/// Renders a square grid thumbnail at the exact inner square of [item]'s fitted destination rect
/// so Frame 0 of expanding from a cropped square tile matches the tile pixel-for-pixel.
class _ThumbPreview extends StatelessWidget {
  const _ThumbPreview({required this.image, required this.item, required this.cropSquare});
  final ui.Image image;
  final FeedItem item;
  final bool cropSquare;

  @override
  Widget build(BuildContext context) {
    if (!cropSquare) {
      return SizedBox.expand(child: RawImage(image: image, fit: BoxFit.contain));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      if (size.isEmpty) return const SizedBox.shrink();
      final aspect = (item.width > 0 && item.height > 0)
          ? item.width / item.height
          : item.cardAspectRatio;
      final dst = _ZoomFlight._fittedRect(size, aspect);
      final side = math.min(dst.width, dst.height);
      return Center(
        child: SizedBox.square(
          dimension: side,
          child: RawImage(image: image, fit: BoxFit.fill),
        ),
      );
    });
  }
}

class _RectClipper extends CustomClipper<RRect> {
  const _RectClipper(this.rect, this.radius);
  final Rect rect;
  final BorderRadius radius;

  @override
  RRect getClip(Size size) => radius.toRRect(rect);

  @override
  bool shouldReclip(_RectClipper old) => old.rect != rect || old.radius != radius;
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
  const _PhotoPage({
    super.key,
    required this.item,
    required this.onZoomed,
    required this.onClose,
    required this.closeOnTap,
    this.previewCacheWidth,
    this.thumbFallback,
    this.cropSource = false,
  });
  final FeedItem item;
  final ValueChanged<bool> onZoomed;
  final VoidCallback onClose;
  final bool closeOnTap;
  final int? previewCacheWidth;
  final ui.Image? thumbFallback;
  final bool cropSource;

  @override
  State<_PhotoPage> createState() => _PhotoPageState();
}

class _PhotoPageState extends State<_PhotoPage> with SingleTickerProviderStateMixin {
  final _transform = TransformationController();
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Matrix4>? _zoomAnim;
  Offset _tapAt = Offset.zero;

  @override
  void initState() {
    super.initState();
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
    _anim.dispose();
    _transform.dispose();
    super.dispose();
  }

  bool _wasZoomed = false;

  bool get _zoomed => _transform.value.getMaxScaleOnAxis() > 1.01;

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
      // a swipe down (and in from a side edge) is the viewer's interactive dismiss
      child: MouseRegion(
        cursor: _zoomed ? SystemMouseCursors.grab : MouseCursor.defer,
        child: InteractiveViewer(
            panEnabled: _zoomed,
            transformationController: _transform,
            onInteractionStart: (_) => _anim.stop(),
            maxScale: 6,
            child: SizedBox.expand(
              child: Image(
                image: image(widget.item, px),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                  if (wasSynchronouslyLoaded || frame != null) return child;
                  final cardPx = widget.previewCacheWidth;
                  if (cardPx != null) {
                    return SizedBox.expand(
                      child: Image(
                        image: mediaImage(widget.item.path, cacheWidth: cardPx, maxSide: 2048),
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                      ),
                    );
                  }
                  final thumb = widget.thumbFallback;
                  if (thumb != null) {
                    return _ThumbPreview(
                      image: thumb,
                      item: widget.item,
                      cropSquare: widget.cropSource,
                    );
                  }
                  return child;
                },
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, color: Colors.white54, size: 56),
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
  const _Caption({super.key, required this.item, this.onExpandedChanged});
  final FeedItem item;
  final void Function(BuildContext? context, bool open)? onExpandedChanged;

  @override
  State<_Caption> createState() => _CaptionState();
}

class _CaptionState extends State<_Caption> {
  bool _open = false;

  void _toggle([bool? next]) {
    final open = next ?? !_open;
    if (open == _open) return;
    setState(() => _open = open);
    widget.onExpandedChanged?.call(context, open);
  }

  @override
  void dispose() {
    if (_open) widget.onExpandedChanged?.call(context, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final h = MediaQuery.sizeOf(context).height;
    final author = [if (i.author_name != null) i.author_name!, if (i.screen_name != null) '@${i.screen_name}'].join('  ');
    const textStyle = TextStyle(color: Colors.white, fontSize: 15, height: 1.35);
    return GestureDetector(
      key: const ValueKey('postCaption'),
      behavior: HitTestBehavior.opaque,
      onTap: _toggle,
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
            if (_open) TextButton(onPressed: () => _toggle(false), child: Text(L('caption.less'))),
            const SizedBox(height: 4),
          ]),
        ),
      ),
    );
  }
}
