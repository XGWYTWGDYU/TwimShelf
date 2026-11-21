import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// A masonry grid (each card goes to the shortest column) that knows where every card is without
/// building it: a card's height comes from [estimate] (worked out from its data, as native's
/// `CardLayout` does) until the card has been laid out once, then from that layout, remembered by
/// [keyOf]. Only the cards on screen (and in the cache area) are ever built, wherever the list is
/// scrolled to and whatever changes: a grid that measured every card above the one it shows could
/// stop for seconds deep in a long list.
class SliverKnownMasonry extends SliverMultiBoxAdaptorWidget {
  const SliverKnownMasonry({
    super.key,
    required super.delegate,
    required this.columns,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
    required this.keyOf,
    required this.estimate,
    required this.items,
    this.estimateKey,
  });

  final int columns;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  /// What a card shows, the same for the same card in another order (its measured height is kept by it).
  final Object Function(int index) keyOf;

  /// A card's height at a column width, before it has been laid out.
  final double Function(int index, double width) estimate;

  /// The list the cards come from: another list (not the same object) places every card again.
  final Object items;

  /// What the estimates depend on besides the width (text size, fonts): when it changes they are worked out again.
  final Object? estimateKey;

  @override
  RenderSliverKnownMasonry createRenderObject(BuildContext context) => RenderSliverKnownMasonry(
        childManager: context as SliverMultiBoxAdaptorElement,
        columns: columns,
        mainAxisSpacing: mainAxisSpacing,
        crossAxisSpacing: crossAxisSpacing,
        keyOf: keyOf,
        estimate: estimate,
        items: items,
        estimateKey: estimateKey,
      );

  @override
  void updateRenderObject(BuildContext context, RenderSliverKnownMasonry renderObject) {
    renderObject
      ..columns = columns
      ..mainAxisSpacing = mainAxisSpacing
      ..crossAxisSpacing = crossAxisSpacing
      ..keyOf = keyOf
      ..estimate = estimate
      ..items = items
      ..estimateKey = estimateKey;
  }
}

const _tolerance = 1e-6;

class RenderSliverKnownMasonry extends RenderSliverMultiBoxAdaptor {
  RenderSliverKnownMasonry({
    required super.childManager,
    required int columns,
    required this._mainAxisSpacing,
    required this._crossAxisSpacing,
    required this.keyOf,
    required this.estimate,
    required this._items,
    this._estimateKey,
  }) : _columns = math.max(1, columns);

  Object Function(int index) keyOf;
  double Function(int index, double width) estimate;

  int get columns => _columns;
  int _columns;
  set columns(int v) {
    v = math.max(1, v);
    if (v == _columns) return;
    _captureGeometryTransition();
    _columns = v;
    _forgetPlaces();
    markNeedsLayout();
  }

  double get mainAxisSpacing => _mainAxisSpacing;
  double _mainAxisSpacing;
  set mainAxisSpacing(double v) {
    if (v == _mainAxisSpacing) return;
    _mainAxisSpacing = v;
    _forgetPlaces();
    markNeedsLayout();
  }

  double get crossAxisSpacing => _crossAxisSpacing;
  double _crossAxisSpacing;
  set crossAxisSpacing(double v) {
    if (v == _crossAxisSpacing) return;
    _crossAxisSpacing = v;
    markNeedsLayout();
  }

  Object _items;
  set items(Object v) {
    if (identical(v, _items)) return;
    _items = v;
    _cancelTransition();
    _forgetPlaces();
    markNeedsLayout();
  }

  Object? _estimateKey;
  set estimateKey(Object? v) {
    if (v == _estimateKey) return;
    _estimateKey = v;
    _estimates.clear();
    _forgetPlaces();
    markNeedsLayout();
  }

  /// Heights of cards laid out at the current width, by [keyOf].
  final _measured = <Object, double>{};
  final _estimates = <Object, double>{};
  double _width = -1;
  double _lastScrollOffset = 0;

  // Smooth FLIP transition when columns or width change (e.g. device rotation).
  static const _transitionDuration = Duration(milliseconds: 280);
  Map<Object, Rect>? _transitionFrom;
  int? _resizeAnchorIndex;
  double _resizeAnchorRatio = 0;
  Duration? _transitionStart;
  double _transitionProgress = 1.0;
  int? _frameCallbackId;

  void _captureGeometryTransition() {
    if (_width <= 0 || firstChild == null || _offset.isEmpty) return;
    // Already captured for this rotation frame (e.g. columns changed just before width changed).
    if (_transitionFrom != null && _transitionStart == null) return;
    final rects = <Object, Rect>{};
    int? anchor;
    double anchorTop = double.infinity;
    double anchorRatio = 0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final i = indexOf(child);
      if (i >= _offset.length || i >= _extent.length) continue;
      final pd = child.parentData! as SliverGridParentData;
      final x = pd.crossAxisOffset ?? 0.0;
      final top = _offset[i] - _lastScrollOffset;
      final h = _extent[i];
      rects[keyOf(i)] = Rect.fromLTWH(x, top, _width, h);
      if (_offset[i] + h > _lastScrollOffset && _offset[i] < anchorTop) {
        anchorTop = _offset[i];
        anchor = i;
        anchorRatio = h > 0 ? ((_lastScrollOffset - _offset[i]) / h).clamp(0.0, 1.0) : 0.0;
      }
    }
    if (rects.isEmpty) return;
    _transitionFrom = rects;
    _resizeAnchorIndex = anchor;
    _resizeAnchorRatio = anchorRatio;
    _transitionStart = null;
    _transitionProgress = 0.0;
  }

  void _startTransition() {
    if (_transitionFrom == null || _transitionStart != null) return;
    _transitionStart = SchedulerBinding.instance.currentFrameTimeStamp;
    _transitionProgress = 0.0;
    _scheduleTransitionFrame();
  }

  void _scheduleTransitionFrame() {
    if (_frameCallbackId != null || !attached) return;
    _frameCallbackId = SchedulerBinding.instance.scheduleFrameCallback(_onTransitionFrame);
  }

  void _onTransitionFrame(Duration timestamp) {
    _frameCallbackId = null;
    final start = _transitionStart;
    if (start == null || _transitionFrom == null) return;
    final elapsed = timestamp - start;
    final p = (elapsed.inMicroseconds / _transitionDuration.inMicroseconds).clamp(0.0, 1.0);
    _transitionProgress = p;
    markNeedsPaint();
    if (p < 1.0) {
      _scheduleTransitionFrame();
    } else {
      _transitionFrom = null;
      _transitionStart = null;
    }
  }

  void _cancelTransition() {
    if (_frameCallbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(_frameCallbackId!);
      _frameCallbackId = null;
    }
    _transitionFrom = null;
    _resizeAnchorIndex = null;
    _transitionStart = null;
    _transitionProgress = 1.0;
  }

  @override
  void detach() {
    _cancelTransition();
    super.detach();
  }

  // Where the first cards go (index → place); the cards after these are not placed yet.
  final _offset = <double>[];
  final _extent = <double>[];
  final _column = <int>[];
  /// Where the next card of each column would start.
  List<double> _bottoms = const [];
  /// The places were thrown away since the last layout (the list or the columns changed): the
  /// first card shown then is no anchor to keep still.
  bool _placesForgotten = true;

  void _forgetPlaces() {
    _offset.clear();
    _extent.clear();
    _column.clear();
    _bottoms = List.filled(_columns, 0.0);
    _placesForgotten = true;
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! SliverGridParentData) child.parentData = SliverGridParentData();
  }

  @override
  double childCrossAxisPosition(RenderBox child) => (child.parentData! as SliverGridParentData).crossAxisOffset!;

  double _heightOf(int i) {
    final k = keyOf(i);
    return _measured[k] ?? (_estimates[k] ??= estimate(i, _width));
  }

  /// Keeps the places of the first [n] cards only.
  void _truncate(int n) {
    if (n >= _offset.length) return;
    _offset.length = n;
    _extent.length = n;
    _column.length = n;
    _bottoms = List.filled(_columns, 0.0);
    final found = List.filled(_columns, false);
    var left = _columns;
    for (var i = n - 1; i >= 0 && left > 0; i--) {
      final c = _column[i];
      if (found[c]) continue;
      found[c] = true;
      left--;
      _bottoms[c] = _offset[i] + _extent[i] + _mainAxisSpacing;
    }
  }

  /// Places cards until no further card could start before [target].
  void _placeUntil(double target, int count) {
    while (_offset.length < count) {
      var c = 0;
      for (var j = 1; j < _columns; j++) {
        if (_bottoms[j] < _bottoms[c]) c = j;
      }
      if (_bottoms[c] > target && _offset.isNotEmpty) break;
      final e = _heightOf(_offset.length);
      _offset.add(_bottoms[c]);
      _extent.add(e);
      _column.add(c);
      _bottoms[c] += e + _mainAxisSpacing;
    }
  }

  /// The first card reaching below [y] (starts are in order; ends are not, across columns).
  int _firstReaching(double y) {
    var lo = 0, hi = _offset.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_offset[mid] < y) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    var first = math.min(lo, _offset.length - 1);
    final closed = List.filled(_columns, false);
    var left = _columns;
    for (var i = lo - 1; i >= 0 && left > 0; i--) {
      final c = _column[i];
      if (closed[c]) continue;
      if (_offset[i] + _extent[i] > y) {
        first = i;
      } else {
        closed[c] = true;
        left--;
      }
    }
    return first;
  }

  /// The last card starting before [y].
  int _lastStartingBefore(double y) {
    var lo = 0, hi = _offset.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_offset[mid] < y) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo - 1;
  }

  int get _childCount {
    var n = 0;
    for (var c = firstChild; c != null; c = childAfter(c)) {
      n++;
    }
    return n;
  }

  /// Exactly the cards [first]...[last] as children, laid out.
  void _keepOnly(int first, int last, BoxConstraints cc) {
    if (firstChild != null) {
      final a = indexOf(firstChild!), b = indexOf(lastChild!);
      if (b < first || a > last) {
        collectGarbage(_childCount, 0);
      } else {
        collectGarbage(math.max(0, first - a), math.max(0, b - last));
      }
    }
    if (firstChild == null) {
      if (!addInitialChild(index: first, layoutOffset: _offset[first])) return;
    }
    while (indexOf(firstChild!) > first) {
      if (insertAndLayoutLeadingChild(cc, parentUsesSize: true) == null) break;
    }
    var child = firstChild!;
    child.layout(cc, parentUsesSize: true);
    while (indexOf(child) < last) {
      // a card already built is only laid out (insertAndLayoutChild would build it again)
      var next = childAfter(child);
      if (next != null && indexOf(next) == indexOf(child) + 1) {
        next.layout(cc, parentUsesSize: true);
      } else {
        next = insertAndLayoutChild(cc, after: child, parentUsesSize: true);
        if (next == null) break;
      }
      child = next;
    }
  }

  @override
  void performLayout() {
    final sc = constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);
    final count = childManager.childCount;
    final stride = (sc.crossAxisExtent + _crossAxisSpacing) / _columns;
    final width = math.max(0.0, stride - _crossAxisSpacing);
    if (width != _width) {
      if (_width > 0) _captureGeometryTransition();
      _width = width;
      _measured.clear();
      _estimates.clear();
      _forgetPlaces();
    }
    if (_bottoms.length != _columns) _forgetPlaces();
    if (_offset.length > count) _truncate(count);
    if (count == 0) {
      if (firstChild != null) collectGarbage(_childCount, 0);
      geometry = SliverGeometry.zero;
      childManager.didFinishLayout();
      return;
    }
    // Keep the topmost visible card anchored across rotation / width changes so the viewport
    // does not jump to a different part of the list and destroy/recreate visible cards.
    if (_resizeAnchorIndex != null) {
      final anchorIdx = _resizeAnchorIndex!.clamp(0, count - 1);
      final ratio = _resizeAnchorRatio;
      _resizeAnchorIndex = null;
      while (_offset.length <= anchorIdx) {
        var c = 0;
        for (var j = 1; j < _columns; j++) {
          if (_bottoms[j] < _bottoms[c]) c = j;
        }
        final e = _heightOf(_offset.length);
        _offset.add(_bottoms[c]);
        _extent.add(e);
        _column.add(c);
        _bottoms[c] += e + _mainAxisSpacing;
      }
      final targetScroll = math.max(0.0, _offset[anchorIdx] + ratio * _extent[anchorIdx]);
      final shift = targetScroll - sc.scrollOffset;
      if (shift.abs() > 0.5 && sc.scrollOffset + shift >= 0) {
        geometry = SliverGeometry(scrollOffsetCorrection: shift);
        childManager.didFinishLayout();
        return;
      }
    }
    final cc = sc.asBoxConstraints(crossAxisExtent: width);
    final start = sc.scrollOffset + sc.cacheOrigin;
    final end = start + sc.remainingCacheExtent;

    // the first card shown before: it stays where it is when cards above it turn out taller or shorter
    final anchor = !_placesForgotten && firstChild != null ? indexOf(firstChild!) : null;
    final anchorWas = anchor != null && anchor < _offset.length ? _offset[anchor] : null;
    _placesForgotten = false;
    int? changedFrom;

    var first = 0, last = 0;
    for (var pass = 0; pass < 8; pass++) {
      _placeUntil(end, count);
      first = _firstReaching(start);
      last = math.max(first, _lastStartingBefore(end));
      _keepOnly(first, last, cc);
      if (firstChild == null) break;
      int? changed;
      for (var child = firstChild; child != null; child = childAfter(child)) {
        final i = indexOf(child);
        final e = paintExtentOf(child);
        if (i >= _extent.length) continue;
        _measured[keyOf(i)] = e;
        if ((e - _extent[i]).abs() > _tolerance) changed = math.min(changed ?? i, i);
      }
      if (changed == null) break;
      changedFrom = math.min(changedFrom ?? changed, changed);
      _truncate(changed);
    }

    // (after the last pass's corrections: the cards shown are placed again)
    _placeUntil(end, count);
    final reversed = axisDirectionIsReversed(sc.crossAxisDirection);
    var childEnd = 0.0;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final i = indexOf(child);
      if (i >= _offset.length) continue;
      final pd = child.parentData! as SliverGridParentData;
      final c = reversed ? _columns - 1 - _column[i] : _column[i];
      pd
        ..layoutOffset = _offset[i]
        ..crossAxisOffset = c * stride;
      childEnd = math.max(childEnd, _offset[i] + _extent[i]);
    }

    if (anchor != null && anchorWas != null && changedFrom != null && changedFrom < anchor && anchor < _offset.length) {
      final shift = _offset[anchor] - anchorWas;
      if (shift.abs() > _tolerance && sc.scrollOffset + shift >= 0) {
        geometry = SliverGeometry(scrollOffsetCorrection: shift);
        childManager.didFinishLayout();
        return;
      }
    }

    final placed = _offset.length;
    final tallest = math.max(0.0, _bottoms.reduce(math.max) - _mainAxisSpacing);
    // the cards not placed yet: as tall on average as the placed ones
    final extent = placed >= count ? tallest : math.max(childEnd, tallest * count / math.max(1, placed));
    final leading = firstChild == null ? 0.0 : _offset[indexOf(firstChild!)];
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: calculatePaintOffset(sc, from: leading, to: childEnd),
      cacheExtent: calculateCacheOffset(sc, from: leading, to: childEnd),
      maxPaintExtent: extent,
      hasVisualOverflow: childEnd > sc.scrollOffset + sc.remainingPaintExtent || sc.scrollOffset > 0,
    );
    if (lastChild != null && indexOf(lastChild!) == count - 1) childManager.setDidUnderflow(true);
    _lastScrollOffset = sc.scrollOffset;
    if (_transitionFrom != null && _transitionStart == null) _startTransition();
    childManager.didFinishLayout();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final from = _transitionFrom;
    if (from == null || _transitionProgress >= 1.0) {
      super.paint(context, offset);
      return;
    }
    final t = Curves.easeOutCubic.transform(_transitionProgress);
    final inv = 1.0 - t;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      final mainPos = childMainAxisPosition(child);
      final crossPos = childCrossAxisPosition(child);
      final paintOffset = offset + Offset(crossPos, mainPos);
      final i = indexOf(child);
      final oldRect = from[keyOf(i)];
      if (oldRect == null) {
        context.paintChild(child, paintOffset);
        continue;
      }
      final newW = math.max(1.0, child.size.width);
      final newH = math.max(1.0, child.size.height);
      final dx = (oldRect.left - crossPos) * inv;
      final dy = (oldRect.top - mainPos) * inv;
      final sx = 1.0 + (oldRect.width / newW - 1.0) * inv;
      final sy = 1.0 + (oldRect.height / newH - 1.0) * inv;
      if (dx.abs() < 0.25 && dy.abs() < 0.25 && (sx - 1.0).abs() < 0.002 && (sy - 1.0).abs() < 0.002) {
        context.paintChild(child, paintOffset);
        continue;
      }
      final m = Matrix4.identity()
        ..setEntry(0, 0, sx)
        ..setEntry(1, 1, sy)
        ..setEntry(0, 3, dx)
        ..setEntry(1, 3, dy);
      final currentChild = child;
      context.pushTransform(
        needsCompositing,
        paintOffset,
        m,
        (innerContext, innerOffset) => innerContext.paintChild(currentChild, innerOffset),
      );
    }
  }
}
