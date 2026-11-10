import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'native_io.dart' show openCoreLibrary;
import 'bindings.dart';

/// One tile of a grid frame, in logical pixels: where it is drawn, how opaque (the zoom
/// cross-fades layers), which item of the list it shows, and its corner radii (top-left,
/// top-right, bottom-right, bottom-left).
class GridTile {
  const GridTile(this.x, this.y, this.side, this.alpha, this.index, this.r0, this.r1, this.r2, this.r3);
  final double x, y, side, alpha;
  final int index;
  final double r0, r1, r2, r3;
}

/// Resting layout: zoom level (0 = most columns), phase (empty places before the first item) and
/// scroll offset.
class GridRest {
  const GridRest(this.level, this.phase, this.offset);
  final int level, phase;
  final double offset;
}

/// The photo grid's pinch zoom, shared with the native apps (core/src/grid.rs): the same
/// layout, anchoring, layer latching and settle as the Photos-measured engine. Driven once per
/// frame from the UI isolate; nothing here allocates per frame (one buffer is reused).
///
/// Not thread-safe; call [dispose] when the grid goes away.
class GridEngine {
  GridEngine({
    required double width,
    required double height,
    required double scale,
    double insetTop = 0,
    double insetBottom = 0,
    required int count,
    int level = 1,
    int phase = 0,
    double offset = 0,
  }) : _handle = _b.tl_grid_new(width, height, scale, insetTop, insetBottom, count, level, phase, offset) {
    if (_handle == nullptr) throw StateError('grid');
  }

  static final CoreBindings _b = CoreBindings(openCoreLibrary());
  final Pointer<TlGrid> _handle;
  Pointer<Double> _buffer = malloc<Double>(9 * 512);
  int _capacity = 512;
  final Pointer<Double> _small = malloc<Double>(4);
  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.tl_grid_free(_handle);
    malloc.free(_buffer);
    malloc.free(_small);
  }

  /// New view size, insets or item count (a zoom in progress ends first; the level stays).
  void configure({required double width, required double height, required double scale, double insetTop = 0, double insetBottom = 0, required int count}) =>
      _b.tl_grid_configure(_handle, width, height, scale, insetTop, insetBottom, count);

  GridRest get rest {
    _b.tl_grid_rest(_handle, _small);
    return GridRest(_small[0].toInt(), _small[1].toInt(), _small[2]);
  }

  /// Zoom levels at this width (0 is the densest), and a tile's side at one of them.
  int get levels => _b.tl_grid_levels(_handle);
  double sideOf(int level) => _b.tl_grid_side(_handle, level);

  double get maxOffset => _b.tl_grid_max_offset(_handle);
  set offset(double v) => _b.tl_grid_set_offset(_handle, v);

  void beginPinch(double x, double y, double seconds) => _b.tl_grid_begin_pinch(_handle, x, y, seconds);
  void pinchChanged(double scale, double x, double y) => _b.tl_grid_pinch_changed(_handle, scale, x, y);

  /// [velocity] in scale per second.
  void release(double velocity, double scale) => _b.tl_grid_release(_handle, velocity, scale);

  /// Advances a zoom: null when nothing is zooming, false while zooming, true when it came to
  /// rest in this frame.
  bool? tick(double seconds) {
    final r = _b.tl_grid_tick(_handle, seconds);
    return r < 0 ? null : r == 1;
  }

  bool finishNow() => _b.tl_grid_finish_now(_handle);

  /// Drops a leftover phase near the top (first row within [rows] rows); true when it changed.
  bool realignTop(double rows) => _b.tl_grid_realign_top(_handle, rows);

  /// Side of the tiles, cross-fade level, latched level, column count of this frame.
  (double side, double level, int target, int columns) get info {
    _b.tl_grid_info(_handle, _small);
    return (_small[0], _small[1], _small[2].toInt(), _small[3].toInt());
  }

  /// Tiles of the current frame, back to front. [visit] is called for each.
  int tiles(void Function(GridTile t) visit) {
    var n = _b.tl_grid_tiles(_handle, _buffer, _capacity);
    if (n > _capacity) {
      malloc.free(_buffer);
      _capacity = n + 256;
      _buffer = malloc<Double>(9 * _capacity);
      n = _b.tl_grid_tiles(_handle, _buffer, _capacity);
    }
    final b = _buffer;
    for (var i = 0; i < n; i++) {
      final o = i * 9;
      visit(GridTile(b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4].toInt(), b[o + 5], b[o + 6], b[o + 7], b[o + 8]));
    }
    return n;
  }

  /// The item under a point at rest, or null.
  int? indexAt(double x, double y) {
    final i = _b.tl_grid_index_at(_handle, x, y);
    return i < 0 ? null : i;
  }

  /// An item's resting frame: x, y, side.
  (double x, double y, double side) frame(int index) {
    _b.tl_grid_frame(_handle, index, _small);
    return (_small[0], _small[1], _small[2]);
  }

  set hidden(int? index) => _b.tl_grid_set_hidden(_handle, index ?? -1);
}
