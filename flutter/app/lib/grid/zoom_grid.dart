import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:tl_core/tl_core.dart';

import 'thumb_store.dart';
import '../widgets/wheel_pager.dart';

/// The zoomable photo grid: the shared engine (core/src/grid.rs) decides where every tile is in
/// every frame — resting rows, the pinch's layers, the settle — and this draws them.
///
/// * Scrolling is a real [Scrollable] over the content height, so each platform keeps its own
///   scrolling (touch, wheel, trackpad, keyboard, scrollbar); the engine is told the offset.
/// * Zooming: two fingers (raw pointers, alongside scrolling), a trackpad pinch, or Ctrl/⌘ +
///   wheel. While a zoom runs the scroll position is not used; when it ends the scroll view is
///   moved to where the engine came to rest.
/// * Frame sync: one [Ticker] callback per frame advances the zoom, asks the store for every
///   visible tile's image and repaints once; images arriving later repaint the next frame.
class ZoomGrid extends StatefulWidget {
  const ZoomGrid({
    super.key,
    required this.items,
    required this.store,
    this.onOpen,
    this.onLongPress,
    this.initialLevel = 1,
    this.padding = EdgeInsets.zero,
    this.selected,
    this.onZoomLimits,
  });

  final List<FeedItem> items;
  final ThumbStore store;
  final void Function(int index)? onOpen;
  final void Function(int index, Offset globalPosition)? onLongPress;
  final int initialLevel;
  /// Room kept free at the top and bottom (bars over the grid); the grid scrolls under it.
  final EdgeInsets padding;
  /// Selection mode: the indices chosen (drawn with a check), or null when not selecting.
  final Set<int>? selected;
  /// Whether another step in and out is possible, whenever that changes (the page's buttons).
  final void Function(bool canZoomIn, bool canZoomOut)? onZoomLimits;

  @override
  State<ZoomGrid> createState() => ZoomGridState();
}

class ZoomGridState extends State<ZoomGrid> with SingleTickerProviderStateMixin {
  GridEngine? _engine;
  final _scroll = ScrollController();
  late final Ticker _ticker = createTicker(_onTick);
  final _repaint = ValueNotifier<int>(0);
  Size _size = Size.zero;
  double _scale = 1;
  bool _zooming = false;
  bool _settling = false;
  bool _syncingScroll = false;
  /// Moves on with every pinch or reconfiguration: a scroll sync scheduled before it is stale.
  int _syncGeneration = 0;

  // two-finger pinch from raw pointers
  final Map<int, Offset> _pointers = {};
  double _pinchStartDistance = 0;
  double _lastScale = 1;
  double _lastScaleTime = 0;
  double _scaleVelocity = 0;

  /// The resting layout (tests read the zoom level from it).
  @visibleForTesting
  GridRest? get rest => _engine?.rest;

  /// The item under a point of the resting grid (tests follow one through a zoom).
  @visibleForTesting
  int? indexAt(Offset p) => _indexAt(p);

  double get _now => SchedulerBinding.instance.currentSystemFrameTimeStamp.inMicroseconds / 1e6;

  @override
  void initState() {
    super.initState();
    widget.store.onLoaded = _requestFrame;
    _scroll.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(ZoomGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.store.onLoaded = _requestFrame;
    if (oldWidget.items.length != widget.items.length) _configure();
    _requestFrame();
  }

  @override
  void dispose() {
    if (widget.store.onLoaded == _requestFrame) widget.store.onLoaded = null;
    _repaint.dispose();
    _ticker.dispose();
    _scroll.dispose();
    _engine?.dispose();
    super.dispose();
  }

  void _configure() {
    if (_size.isEmpty) return;
    final e = _engine;
    if (e == null) {
      _engine = GridEngine(
        width: _size.width,
        height: _size.height,
        scale: _scale,
        insetTop: widget.padding.top,
        insetBottom: widget.padding.bottom,
        count: widget.items.length,
        level: widget.initialLevel,
      );
    } else {
      e.configure(width: _size.width, height: _size.height, scale: _scale, insetTop: widget.padding.top, insetBottom: widget.padding.bottom, count: widget.items.length);
      _zooming = false;
      _settling = false;
    }
    _syncScrollToEngine();
  }

  /// Hands the resting layout to the scroll view (after a zoom, a resize). The engine owns the
  /// offset throughout: the new content height is laid out first (a rebuild), and only then is
  /// the scroll view moved — clamped to its new extent, never the old one — and the engine told
  /// where it really is. Scroll notifications meanwhile are not the user's and are ignored.
  void _syncScrollToEngine() {
    final e = _engine;
    if (e == null) return;
    // a zoom that ends near the top drops its phase: the first row is never partly empty
    e.realignTop(1);
    final target = e.rest.offset;
    final generation = ++_syncGeneration;
    // from a layout (a resize) the build is already under way: no rebuild needed or allowed
    void change() {
      _zooming = false;
      _settling = false;
      _syncingScroll = true;
    }
    SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks ? change() : setState(change);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _syncGeneration || _zooming) return;
      if (_scroll.hasClients) {
        _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
        e.offset = _scroll.offset;
      }
      setState(() => _syncingScroll = false);
      _requestFrame();
      _reportLimits();
    });
  }

  (bool, bool)? _limits;
  void _reportLimits() {
    final e = _engine;
    if (e == null) return;
    final limits = (e.rest.level < e.levels - 1, e.rest.level > 0);
    if (limits == _limits) return;
    _limits = limits;
    widget.onZoomLimits?.call(limits.$1, limits.$2);
  }

  void _scrolled() {
    final e = _engine;
    // Ignore notifications from the old layout until the handover completes.
    // A new pointer interrupts settling before its drag reaches this listener.
    if (e == null || _syncingScroll || _zooming) return;
    e.offset = _scroll.offset;
    // scrolling up to within three rows of the top drops a leftover phase (content changes)
    if (e.realignTop(3)) {
      setState(() {});
      return _syncScrollToEngine();
    }
    _requestFrame();
  }

  void _requestFrame() {
    if (mounted && !_ticker.isActive) _ticker.start();
  }

  void _onTick(Duration _) {
    final e = _engine;
    if (e == null) return _ticker.stop();
    _advanceStep(e);
    if (_zooming && e.tick(_now) == true) _syncScrollToEngine();
    _repaint.value++;
    // keep ticking while something moves; stop otherwise (an image arriving restarts it)
    if (!_zooming) _ticker.stop();
  }

  // ---------- zoom input ----------

  void _beginPinch(Offset focal) {
    final e = _engine;
    if (e == null || widget.items.isEmpty) return;
    // The scroll view only has the engine's offset at rest. While a zoom still runs (a settle
    // taken over) and between a zoom's end and its handover (the scroll view is moved a frame
    // later) it is still where the last zoom began, in that zoom's layout: reading it then would
    // throw the grid back there — after a zoom in, most of the way to the top.
    final scrollIsCurrent = !_zooming && !_syncingScroll;
    // the engine takes the offset: any fling or bounce stops where it is, a pending handover is
    // void, and the scroll view holds still (its physics) until the zoom has been handed back
    _syncGeneration++;
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.offset.clamp(0.0, _scroll.position.maxScrollExtent));
      if (scrollIsCurrent) e.offset = _scroll.offset;
    }
    e.beginPinch(focal.dx, focal.dy, _now);
    setState(() {
      _zooming = true;
      _settling = false;
      _syncingScroll = false;
    });
    _lastScale = 1;
    _scaleVelocity = 0;
    _lastScaleTime = _now;
    _requestFrame();
  }

  void _pinch(double scale, Offset focal) {
    final e = _engine;
    if (e == null || !_zooming) return;
    final t = _now;
    final dt = t - _lastScaleTime;
    if (dt > 0) _scaleVelocity = 0.7 * _scaleVelocity + 0.3 * (scale - _lastScale) / dt;
    _lastScale = scale;
    _lastScaleTime = t;
    e.pinchChanged(scale, focal.dx, focal.dy);
    _requestFrame();
  }

  void _endPinch() {
    _engine?.release(_scaleVelocity, _lastScale);
    setState(() => _settling = true);
    _requestFrame();
  }

  void _interruptSettle() {
    if (!_settling) return;
    _engine?.finishNow();
    _syncScrollToEngine();
  }

  void _pointerDown(PointerDownEvent ev) {
    _endStepNow();
    // A finger of the pinch stayed down and the other is back: the pinch goes on from where the
    // settle is (the engine keeps the picture still). Any other touch ends the settle, to scroll.
    if (!(_settling && _pointers.length == 1)) _interruptSettle();
    _pointers[ev.pointer] = ev.localPosition;
    if (_pointers.length == 2) {
      final p = _pointers.values.toList();
      _pinchStartDistance = (p[0] - p[1]).distance;
      _beginPinch((p[0] + p[1]) / 2);
    }
  }

  void _pointerMove(PointerMoveEvent ev) {
    if (!_pointers.containsKey(ev.pointer)) return;
    _pointers[ev.pointer] = ev.localPosition;
    if (_pointers.length >= 2 && _pinchStartDistance > 0) {
      final p = _pointers.values.take(2).toList();
      _pinch((p[0] - p[1]).distance / _pinchStartDistance, (p[0] + p[1]) / 2);
    }
  }

  void _pointerUp(PointerEvent ev) {
    final wasPinching = _pointers.length >= 2;
    _pointers.remove(ev.pointer);
    if (wasPinching && _pointers.length < 2) {
      _pinchStartDistance = 0;
      _endPinch();
    }
  }

  // trackpad pinch (macOS, Windows precision touchpads, Linux)
  void _panZoomStart(PointerPanZoomStartEvent ev) {
    if (wheelPages) return; // a trackpad only scrolls there
    _endStepNow();
    _interruptSettle();
  }

  void _panZoomUpdate(PointerPanZoomUpdateEvent ev) {
    if (wheelPages) return; // a trackpad only scrolls there
    if (!_zooming && (ev.scale - 1).abs() > 0.02) _beginPinch(ev.localPosition);
    if (_zooming) _pinch(ev.scale, ev.localPosition);
  }

  void _panZoomEnd(PointerPanZoomEndEvent ev) {
    if (wheelPages) return; // a trackpad only scrolls there
    if (_zooming && _pinchStartDistance == 0) _endPinch();
  }

  /// One zoom step (the page's buttons, ⌘+ / ⌘−, Ctrl + wheel): -1 fewer columns. As a short
  /// pinch that lands exactly on the next level's side, because the engine moves to another level
  /// only when a pinch's frames carry it across the threshold: jumping there inside one frame
  /// and letting go would spring straight back.
  bool _overCell = false;

  void step(int d, {Offset? focal}) {
    final e = _engine;
    final box = context.findRenderObject() as RenderBox?;
    if (e == null || box == null || _zooming) return;
    final from = e.rest.level;
    final to = from - d;
    if (to < 0 || to >= e.levels) return;
    final mid = focal ?? box.size.center(Offset.zero);
    _beginPinch(mid);
    _stepZoom = (ratio: e.sideOf(to) / e.sideOf(from), start: _now, focal: mid);
  }

  ({double ratio, double start, Offset focal})? _stepZoom;
  static const _stepSeconds = 0.3;

  void _advanceStep(GridEngine e) {
    final s = _stepZoom;
    if (s == null) return;
    final t = ((_now - s.start) / _stepSeconds).clamp(0.0, 1.0);
    final eased = 1 - math.pow(1 - t, 3).toDouble();
    final scale = math.pow(s.ratio, eased).toDouble();
    e.pinchChanged(scale, s.focal.dx, s.focal.dy);
    if (t >= 1) {
      // a slow machine may jump here in one frame: this tick is what takes the threshold
      e.tick(_now);
      _stepZoom = null;
      _lastScale = scale;
      _scaleVelocity = 0;
      _endPinch();
    }
  }

  /// A finger arrives during a step: it goes where it was heading, at once.
  void _endStepNow() {
    final e = _engine, s = _stepZoom;
    if (e == null || s == null) return;
    _stepZoom = null;
    e.pinchChanged(s.ratio, s.focal.dx, s.focal.dy);
    e.tick(_now);
    _lastScale = s.ratio;
    _scaleVelocity = 0;
    _endPinch();
  }

  // Ctrl/⌘ + wheel: one step per notch run (a new step once the last one has come to rest)
  void _signal(PointerSignalEvent ev) {
    if (ev is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    // Windows and Linux: the wheel only scrolls; the size changes by Ctrl + − = and the buttons
    if (wheelPages || !(keys.isControlPressed || keys.isMetaPressed)) {
      _interruptSettle();
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(ev, (_) {
      if (ev.scrollDelta.dy != 0) step(ev.scrollDelta.dy < 0 ? -1 : 1, focal: ev.localPosition);
    });
  }

  // ---------- taps ----------

  int? _indexAt(Offset p) => _zooming ? null : _engine?.indexAt(p.dx, p.dy);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      if (size != _size || dpr != _scale) {
        _size = size;
        _scale = dpr;
        widget.store.setScale(dpr);
        _configure();
      }
      final e = _engine;
      final contentHeight = e == null ? 0.0 : e.maxOffset + size.height;
      return Listener(
        onPointerDown: _pointerDown,
        onPointerMove: _pointerMove,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerUp,
        onPointerPanZoomStart: _panZoomStart,
        onPointerPanZoomUpdate: _panZoomUpdate,
        onPointerPanZoomEnd: _panZoomEnd,
        onPointerSignal: _signal,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final i = _indexAt(d.localPosition);
            if (i != null) widget.onOpen?.call(i);
          },
          onLongPressStart: (d) {
            final i = _indexAt(d.localPosition);
            if (i != null) widget.onLongPress?.call(i, d.globalPosition);
          },
          // a mouse's way to the same menu
          onSecondaryTapUp: (d) {
            final i = _indexAt(d.localPosition);
            if (i != null) widget.onLongPress?.call(i, d.globalPosition);
          },
          child: MouseRegion(
            cursor: _overCell ? SystemMouseCursors.click : MouseCursor.defer,
            onHover: (e) {
              final over = _indexAt(e.localPosition) != null;
              if (over != _overCell) setState(() => _overCell = over);
            },
            onExit: (_) {
              if (_overCell) setState(() => _overCell = false);
            },
            child: Stack(children: [
            Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _GridPainter(this, scheme.surfaceContainerHighest, scheme.onSurfaceVariant, dpr, scheme.primary),
                ),
              ),
            ),
            // the scrollable only scrolls; the painter draws
            Positioned.fill(
              child: Scrollbar(
                controller: _scroll,
                child: SingleChildScrollView(
                  controller: _scroll,
                  physics: _zooming && !_settling ? const NeverScrollableScrollPhysics() : null,
                  child: SizedBox(height: contentHeight, width: size.width),
                ),
              ),
            ),
          ]),
          ),
        ),
      );
    });
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.state, this.placeholder, this.badge, this.dpr, this.accent) : super(repaint: state._repaint);
  final Color accent;
  static final _check = TextPainter(
    text: TextSpan(text: String.fromCharCode(Icons.check.codePoint),
        style: TextStyle(fontFamily: Icons.check.fontFamily, package: Icons.check.fontPackage, fontSize: 14, color: Colors.white, fontWeight: FontWeight.w700)),
    textDirection: TextDirection.ltr,
  )..layout();
  final ZoomGridState state;
  final Color placeholder;
  final Color badge;
  final double dpr;

  static final _play = TextPainter(
    text: TextSpan(text: String.fromCharCode(Icons.play_circle_fill.codePoint),
        style: TextStyle(fontFamily: Icons.play_circle_fill.fontFamily, package: Icons.play_circle_fill.fontPackage, fontSize: 18, color: Colors.white)),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    final e = state._engine;
    if (e == null) return;
    final store = state.widget.store;
    final items = state.widget.items;
    store.beginFrame();
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final empty = Paint();
    canvas.clipRect(Offset.zero & size);
    var first = items.length, last = -1;
    e.tiles((t) {
      if (t.index >= items.length) return;
      first = math.min(first, t.index);
      last = math.max(last, t.index);
      final item = items[t.index];
      final rect = Rect.fromLTWH(t.x, t.y, t.side, t.side);
      final rrect = RRect.fromRectAndCorners(rect,
          topLeft: Radius.circular(t.r0), topRight: Radius.circular(t.r1),
          bottomRight: Radius.circular(t.r2), bottomLeft: Radius.circular(t.r3));
      final img = store.image(item.media_id, t.side * dpr, item: item);
      if (img == null) {
        empty.color = placeholder.withValues(alpha: placeholder.a * t.alpha);
        canvas.drawRRect(rrect, empty);
      } else {
        paint.color = Color.fromRGBO(255, 255, 255, t.alpha);
        canvas.save();
        canvas.clipRRect(rrect);
        canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()), rect, paint);
        canvas.restore();
      }
      if (item.kind == MediaKind.video && t.side >= 40 && t.alpha > 0.5) {
        _play.paint(canvas, Offset(rect.right - 22, rect.bottom - 22));
      }
      final selected = state.widget.selected;
      if (selected != null && t.alpha > 0.5) {
        final on = selected.contains(t.index);
        if (on) canvas.drawRRect(rrect, Paint()..color = const Color(0x55FFFFFF));
        final c = Offset(rect.right - 14, rect.bottom - 14);
        canvas.drawCircle(c, 10, Paint()..color = on ? accent : const Color(0x66000000));
        canvas.drawCircle(c, 10, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.5..color = const Color(0xFFFFFFFF));
        if (on) _check.paint(canvas, c - Offset(_check.width / 2, _check.height / 2));
      }
    });
    // One viewport on either side: visible requests were queued first.
    if (last >= first) {
      final margin = last - first + 1;
      for (var i = math.max(0, first - margin); i <= math.min(items.length - 1, last + margin); i++) {
        if (i < first || i > last) store.prefetch(items[i]);
      }
    }
    store.endFrame();
  }

  @override
  bool shouldRepaint(_GridPainter old) => true;
}
