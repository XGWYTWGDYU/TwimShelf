// The photo grid in the web build: the same interface as the native engine (grid.dart), but
// plain — a few fixed column counts, a pinch (or ctrl + wheel) steps from one to the next when it
// ends, no animated zoom between layouts and no cross-fades. A web page is mostly used with a
// mouse; the full Photos-like zoom stays in the apps.

/// One tile of a grid frame, in logical pixels.
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
  })  : _width = width,
        _height = height,
        _insetTop = insetTop,
        _insetBottom = insetBottom,
        _count = count,
        _phase = phase,
        _offset = offset {
    _level = level.clamp(0, levels - 1);
    _clampOffset();
  }

  static const _gap = 2.0;
  double _width, _height, _insetTop, _insetBottom;
  int _count, _level = 1, _phase;
  double _offset;
  int? _hidden;
  double _pinchScale = 1;
  double _anchorX = 0, _anchorY = 0;
  bool _changed = false;

  void dispose() {}

  /// Column counts, densest first, for the current width.
  List<int> get _columns {
    final w = _width <= 0 ? 400.0 : _width;
    final out = <int>[];
    for (final tile in const [64.0, 104.0, 168.0, 280.0]) {
      final c = (w / tile).floor().clamp(1, 40);
      if (out.isEmpty || c < out.last) out.add(c);
    }
    if (out.length == 1 && out.first > 1) out.add(out.first ~/ 2);
    return out;
  }

  int get levels => _columns.length;
  int get _cols => _columns[_level.clamp(0, levels - 1)];
  double sideOf(int level) {
    final c = _columns[level.clamp(0, levels - 1)];
    return (_width - _gap * (c - 1)) / c;
  }

  double get _side => sideOf(_level);
  double get _stride => _side + _gap;
  int get _rows => ((_count + _phase) / _cols).ceil();

  double get maxOffset {
    final content = _insetTop + _rows * _stride - _gap + _insetBottom;
    return content > _height ? content - _height : 0;
  }

  void _clampOffset() => _offset = _offset.clamp(0.0, maxOffset);

  set offset(double v) {
    _offset = v;
    _clampOffset();
  }

  void configure({required double width, required double height, required double scale, double insetTop = 0, double insetBottom = 0, required int count}) {
    _width = width;
    _height = height;
    _insetTop = insetTop;
    _insetBottom = insetBottom;
    _count = count;
    _level = _level.clamp(0, levels - 1);
    _clampOffset();
  }

  GridRest get rest => GridRest(_level, _phase, _offset);

  void beginPinch(double x, double y, double seconds) {
    _pinchScale = 1;
    _anchorX = x;
    _anchorY = y;
  }

  void pinchChanged(double scale, double x, double y) => _pinchScale = scale;

  /// The pinch ended: one level in its direction, keeping the item under the fingers in place.
  void release(double velocity, double scale) {
    final s = scale == 1 ? _pinchScale : scale;
    final next = s > 1.12 ? _level + 1 : s < 0.89 ? _level - 1 : _level;
    if (next < 0 || next >= levels || next == _level) return;
    final anchor = indexAt(_anchorX, _anchorY);
    _level = next;
    if (anchor != null) {
      final row = (anchor + _phase) ~/ _cols;
      _offset = _insetTop + row * _stride - _anchorY + _side / 2;
    }
    _clampOffset();
    _changed = true;
  }

  /// null when nothing is zooming, true when a zoom came to rest in this frame.
  bool? tick(double seconds) {
    if (!_changed) return null;
    _changed = false;
    return true;
  }

  bool finishNow() => false;

  bool realignTop(double rows) {
    if (_phase == 0 || _offset > rows * _stride) return false;
    _phase = 0;
    _clampOffset();
    return true;
  }

  (double side, double level, int target, int columns) get info => (_side, _level.toDouble(), _level, _cols);

  int tiles(void Function(GridTile t) visit) {
    if (_count == 0 || _width <= 0) return 0;
    final cols = _cols, side = _side, stride = _stride;
    final firstRow = ((_offset - _insetTop) / stride).floor().clamp(0, 1 << 30);
    final lastRow = ((_offset - _insetTop + _height) / stride).ceil();
    var n = 0;
    for (var row = firstRow; row <= lastRow; row++) {
      for (var col = 0; col < cols; col++) {
        final i = row * cols + col - _phase;
        if (i < 0 || i >= _count || i == _hidden) continue;
        visit(GridTile(col * stride, _insetTop + row * stride - _offset, side, 1, i, 0, 0, 0, 0));
        n++;
      }
    }
    return n;
  }

  int? indexAt(double x, double y) {
    final stride = _stride;
    final col = (x / stride).floor();
    final row = ((y + _offset - _insetTop) / stride).floor();
    if (col < 0 || col >= _cols || row < 0) return null;
    final i = row * _cols + col - _phase;
    return i >= 0 && i < _count ? i : null;
  }

  (double x, double y, double side) frame(int index) {
    final p = index + _phase;
    return ((p % _cols) * _stride, _insetTop + (p ~/ _cols) * _stride - _offset, _side);
  }

  set hidden(int? index) => _hidden = index;
}
