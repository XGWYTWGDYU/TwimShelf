import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Windows and Linux: a sideways `PageView` turns by the wheel, one whole page per scroll. A
/// trackpad is treated as a wheel: there it neither drags nor scrolls the pages part of the way.
bool get wheelPages => !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);

/// The `PageView`'s `scrollBehavior`: only fingers drag its pages.
ScrollBehavior? pageBehavior(BuildContext context) => wheelPages
    ? ScrollConfiguration.of(context).copyWith(scrollbars: false, dragDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus, PointerDeviceKind.invertedStylus, PointerDeviceKind.unknown})
    : null;

/// `InteractiveViewer.scaleFactor` for a photo: it zooms by every wheel event it is given, without
/// asking anyone. On these platforms the wheel turns pages, so it zooms only with Ctrl held or on a
/// photo already zoomed; otherwise a factor so large that the wheel changes nothing. (Not infinite:
/// a finger's pinch divides by it.)
double photoScaleFactor({required bool zoomed, required bool ctrl}) => !wheelPages || zoomed || ctrl ? kDefaultMouseScrollToScaleFactor : 1e12;

/// A scroll is over when its events stop for this long (a stall inside one reaches 150 ms).
const _quiet = Duration(milliseconds: 170);
/// A mouse's next notch after this long is a next scroll (its clusters are shorter apart inside).
const _tickGap = Duration(milliseconds: 120);
/// A trackpad's small first movements add up to this before they count.
const _startDistance = 12.0;
const _speedWindow = Duration(milliseconds: 40);
/// An event after a gap this long says nothing of the speed yet.
const _hiccup = Duration(milliseconds: 50);
const _slowedDown = 0.7;
const _speedingUp = 1.6;
const _newSwipeSpeed = 1.5;
const _minBetweenTurns = Duration(milliseconds: 200);

/// When the last wheel event anywhere in the app was: a scroll of the list that reaches a card
/// under the mouse goes on being a scroll of the list.
class _Wheel {
  static Duration? lastAt;
  static int _users = 0;

  static void _route(PointerEvent e) {
    if (e is PointerScrollEvent) lastAt = e.timeStamp;
  }

  static void use() {
    if (_users++ == 0) GestureBinding.instance.pointerRouter.addGlobalRoute(_route);
  }

  static void release() {
    if (--_users == 0) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route);
      lastAt = null;
    }
  }
}

/// Inside each page: what [WheelPager] takes, the `PageView` (which would move the page by some
/// pixels) and whatever else is around never gets.
class WheelGuard extends StatelessWidget {
  const WheelGuard({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!wheelPages) return child;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: (e) {
        if (e is PointerScrollEvent && (context.findAncestorStateOfType<_WheelPagerState>()?._take(e) ?? false)) {
          GestureBinding.instance.pointerSignalResolver.register(e, (_) {});
        }
      },
      child: child,
    );
  }
}

/// Around the `PageView`: one scroll, one page, whichever way (down and right go forward). A
/// trackpad's inertia turns nothing more, while a next swipe into it does. Ctrl + wheel is
/// left alone, as is everything when not [enabled] (a zoomed photo, a card with one picture).
/// [canStep]: false where there is no page that way: the scroll then goes to what is around.
class WheelPager extends StatefulWidget {
  const WheelPager({super.key, required this.onStep, required this.child, this.enabled = true, this.canStep});

  final ValueChanged<int> onStep;
  final Widget child;
  final bool enabled;
  final bool Function(int by)? canStep;

  @override
  State<WheelPager> createState() => _WheelPagerState();
}

class _WheelPagerState extends State<WheelPager> {
  var _turned = false;
  Duration? _lastAt;
  PointerScrollEvent? _seen;
  var _seenTaken = false;

  var _sum = 0.0;
  final _recent = <(Duration, double)>[];
  Duration _turnedAt = Duration.zero;
  var _peak = 0.0;
  double? _trough;
  var _rising = 0;

  @override
  void initState() {
    super.initState();
    _Wheel.use();
  }

  @override
  void dispose() {
    _Wheel.release();
    super.dispose();
  }

  /// The guard and the listener see the same event: decided once.
  bool _take(PointerScrollEvent e) {
    // each listener gets its own transformed copy of the event
    final event = (e.original ?? e) as PointerScrollEvent;
    if (identical(event, _seen)) return _seenTaken;
    _seen = event;
    return _seenTaken = !HardwareKeyboard.instance.isControlPressed && _scrolled(e.scrollDelta, e.timeStamp, _Wheel.lastAt);
  }

  /// The speed over the last moment (pixels per ms), measured from the event before that moment:
  /// a hiccup in the events and the batch that makes up for it even out.
  double? _speed(Duration at, double amount) {
    _recent.add((at, amount.abs()));
    for (var k = _recent.length - 1; k >= 0; k--) {
      if (at - _recent[k].$1 >= _speedWindow) {
        final since = _recent[k].$1;
        var sum = 0.0;
        for (var n = k + 1; n < _recent.length; n++) {
          sum += _recent[n].$2;
        }
        _recent.removeRange(0, k);
        return sum / ((at - since).inMicroseconds / 1000);
      }
    }
    return null;
  }

  void _turn(int step, Duration at, double? speed) {
    _turned = true;
    _turnedAt = at;
    _peak = speed ?? 0;
    _trough = null;
    _rising = 0;
    widget.onStep(step);
  }

  /// Whether this scroll is this pager's. Three shapes, measured on real input through Remote
  /// Desktop (test/widgets/wheel_pager_test.dart replays them): a mouse sends clusters of ±100 with
  /// pauses between; a trackpad a stream of small amounts, rising and then decaying for a second
  /// or more after the fingers left, in which a next swipe shows only as the speed rising again;
  /// and either may stall for up to 150 ms and then send what it held back.
  bool _scrolled(Offset by, Duration at, Duration? lastAnywhere) {
    final last = _lastAt;
    _lastAt = at;
    final gap = last == null ? null : at - last;
    final amount = by.dy.abs() > by.dx.abs() ? by.dy : by.dx;
    final tick = amount != 0 && (amount % 100 == 0 || amount % 120 == 0);
    if (gap == null || gap >= _quiet || (tick && gap >= _tickGap)) {
      _turned = false;
      _sum = 0;
      _recent.clear();
    }
    if (!widget.enabled) return false;
    if (amount == 0) return _turned;
    final speed = _speed(at, amount);
    if (!_turned) {
      if (lastAnywhere != null && lastAnywhere != last && at - lastAnywhere < _quiet) return false; // began elsewhere
      _sum += amount;
      final step = _sum > 0 ? 1 : -1;
      if (widget.canStep?.call(step) == false) return false;
      if (_sum.abs() >= _startDistance || tick) _turn(step, at, speed);
      return true;
    }
    if (speed == null || (gap != null && gap >= _hiccup)) return true;
    final trough = _trough;
    if (trough == null) {
      // the swipe that turned still speeding up, until it clearly slows down
      if (speed > _peak) {
        _peak = speed;
      } else if (speed < _peak * _slowedDown) {
        _trough = speed;
      }
      return true;
    }
    if (speed < trough) _trough = speed;
    _rising = speed >= _trough! * _speedingUp && speed >= _newSwipeSpeed ? _rising + 1 : 0;
    if (_rising < 2 || at - _turnedAt < _minBetweenTurns) return true;
    final step = amount > 0 ? 1 : -1;
    if (widget.canStep?.call(step) == false) {
      _turned = false;
      _sum = 0;
      return false;
    }
    _turn(step, at, speed);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (!wheelPages) return widget.child;
    return Listener(
      onPointerPanZoomUpdate: (e) {
        // fingers to the left are a scroll to the right; the tiniest shake of two fingers is none
        if (e.panDelta.distance >= 4 && (e.scale - 1).abs() < 0.02) _scrolled(-e.panDelta, e.timeStamp, null);
      },
      onPointerSignal: (e) {
        if (e is PointerScrollEvent) _take(e);
      },
      child: widget.child,
    );
  }
}
