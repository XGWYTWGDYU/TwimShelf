// Pure, UI-free input classification and touchpad horizontal-swipe gesture state machine for
// Browse PostCard media paging:
//  * Physical mouse wheels (vertical, horizontal tilt/thumb wheel, high-res free-spin, Shift+wheel)
//    NEVER turn card pages — they always pass through so the Browse feed scrolls vertically.
//  * Precision Touchpad two-finger horizontal swipes flip exactly one page per deliberate sideways
//    gesture (axis-locked against vertical/diagonal scrolls, swallowing trailing inertia/momentum).
using System.Threading;

namespace TwimShelf.Controls;

/// Hardware-backed Mouse vs Precision Touchpad input tracker (fed by InputSourceTracker on Windows).
public static class TouchpadInputState
{
    static long _lastTouchpadTick;
    static long _lastPhysicalMouseWheelTick;

    public static void RecordTouchpad(long tickMs) => Volatile.Write(ref _lastTouchpadTick, tickMs);
    public static void RecordPhysicalMouseWheel(long tickMs) => Volatile.Write(ref _lastPhysicalMouseWheelTick, tickMs);

    public static long LastTouchpadTick => Volatile.Read(ref _lastTouchpadTick);
    public static long LastPhysicalMouseWheelTick => Volatile.Read(ref _lastPhysicalMouseWheelTick);

    /// Returns true only when an incoming wheel event originated from a touchpad two-finger
    /// gesture rather than a physical mouse wheel (vertical, tilt/thumb wheel, or Shift+wheel).
    public static bool IsTouchpadWheel(int delta, bool shiftDown, long nowMs) =>
        ClassifyTouchpadHorizontalWheel(delta, shiftDown, nowMs, LastTouchpadTick, LastPhysicalMouseWheelTick);

    /// Alias kept for horizontal-wheel call sites.
    public static bool IsTouchpadHorizontalWheel(int delta, bool shiftDown, long nowMs) =>
        IsTouchpadWheel(delta, shiftDown, nowMs);

    /// Pure classification helper (directly unit-testable without Win32 hooks).
    public static bool ClassifyTouchpadHorizontalWheel(
        int delta,
        bool shiftDown,
        long nowMs,
        long lastTouchpadTick,
        long lastPhysicalMouseWheelTick)
    {
        if (delta == 0 || shiftDown) return false;

        var mouseRecent = lastPhysicalMouseWheelTick > 0 && (nowMs - lastPhysicalMouseWheelTick) is >= 0 and <= 150;
        var padRecent = lastTouchpadTick > 0 && (nowMs - lastTouchpadTick) is >= 0 and <= 1500;

        // A real physical mouse wheel (including high-res free-spin mice that emit sub-120 deltas)
        // always takes precedence over stale touchpad activity.
        if (mouseRecent && (!padRecent || lastPhysicalMouseWheelTick >= lastTouchpadTick))
            return false;

        // Active Precision Touchpad contact or its immediate momentum tail.
        if (padRecent)
            return true;

        // Fallback when Raw Input hasn't seen either device (e.g. non-PTP legacy touchpad or
        // forwarded trackpad in a VM/remote session): discrete WHEEL_DELTA (120) steps are mouse
        // wheel notches; fractional deltas are precision trackpad events.
        return Math.Abs(delta) % 120 != 0;
    }
}

public enum CardWheelAction
{
    PassThrough,
    Swallow,
    TurnNext,
    TurnPrev,
}

/// Axis-locked, one-page-per-swipe touchpad gesture recognizer for a Browse PostCard's media area
/// (matching Apple SwipeMediaView and Web PostCard + WheelStream).
public sealed class CardSwipeFilter
{
    enum Mode { Undecided, Page, Scroll }

    const long NewGestureGapMs = 350;
    const long PauseGrowGapMs = 100;
    const double HorizontalThreshold = 36.0;
    const double VerticalCommitThreshold = 12.0;
    const double HorizontalDominanceRatio = 1.8;

    Mode _mode = Mode.Undecided;
    long _lastEventMs;
    int _lastMag;
    bool _decaying;
    bool _inMomentum;
    int _dirX;
    int _dirY;
    double _sumX;
    double _sumY;

    public void Reset()
    {
        _mode = Mode.Undecided;
        _lastEventMs = 0;
        _lastMag = 0;
        _decaying = false;
        _inMomentum = false;
        _dirX = 0;
        _dirY = 0;
        _sumX = 0;
        _sumY = 0;
    }

    /// Evaluates one wheel event over the card's media area.
    /// `isHorizontal`: PointerPointProperties.IsHorizontalMouseWheel.
    /// `delta`: PointerPointProperties.MouseWheelDelta (positive horizontal = right / next page).
    /// `isTouchpad`: true only when the event originated from a touchpad (never a physical mouse).
    /// `canPage`: true when the card has 2+ media items.
    public CardWheelAction OnWheel(bool isHorizontal, int delta, bool isTouchpad, bool canPage, long nowMs)
    {
        if (delta == 0) return CardWheelAction.PassThrough;

        // Physical mouse wheel (vertical, horizontal tilt/thumb wheel, or Shift+wheel) NEVER turns
        // card pages — always pass through so the Browse feed scrolls vertically.
        if (!isTouchpad)
        {
            Reset();
            return CardWheelAction.PassThrough;
        }

        if (!canPage)
            return CardWheelAction.PassThrough;

        var mag = Math.Abs(delta);
        var sign = Math.Sign(delta);
        var gap = _lastEventMs == 0 ? long.MaxValue : nowMs - _lastEventMs;

        // Detect a fresh two-finger gesture: pause, direction reversal on the same axis, or
        // magnitude rising sharply again after decaying (fingers placed back on the touchpad).
        var fresh = gap > NewGestureGapMs || (gap > PauseGrowGapMs && mag > _lastMag + 2);
        if (!fresh && mag > 2)
        {
            if (isHorizontal && _dirX != 0 && sign != _dirX) fresh = true;
            else if (!isHorizontal && _dirY != 0 && sign != _dirY) fresh = true;
            else if (_decaying && mag > _lastMag * 1.6 + 6) fresh = true;
        }

        if (fresh)
        {
            _decaying = false;
            _inMomentum = false;
            _mode = Mode.Undecided;
            _sumX = 0;
            _sumY = 0;
            _dirX = 0;
            _dirY = 0;
        }
        else if (mag < _lastMag - 1)
        {
            _decaying = true;
        }

        if (_decaying && mag <= _lastMag)
            _inMomentum = true;

        if (isHorizontal && mag > 1) _dirX = sign;
        if (!isHorizontal && mag > 1) _dirY = sign;
        _lastEventMs = nowMs;
        _lastMag = mag;

        if (_mode == Mode.Scroll)
            return CardWheelAction.PassThrough;

        if (_mode == Mode.Page)
        {
            // Once a page flip fired, swallow trailing horizontal swipe + inertia; if fingers
            // explicitly start scrolling vertically, release immediately back to the feed.
            if (!isHorizontal && mag > 4)
            {
                _mode = Mode.Scroll;
                return CardWheelAction.PassThrough;
            }
            return isHorizontal ? CardWheelAction.Swallow : CardWheelAction.PassThrough;
        }

        // Mode.Undecided
        if (_inMomentum)
        {
            _mode = Mode.Scroll;
            return CardWheelAction.PassThrough;
        }

        if (isHorizontal) _sumX += delta;
        else _sumY += delta;

        if (!isHorizontal)
        {
            if (Math.Abs(_sumY) >= VerticalCommitThreshold && Math.Abs(_sumY) >= Math.Abs(_sumX) * 0.6)
                _mode = Mode.Scroll;
            return CardWheelAction.PassThrough;
        }

        // Horizontal touchpad event while still deciding axis:
        if (Math.Abs(_sumY) > Math.Abs(_sumX))
        {
            _mode = Mode.Scroll;
            return CardWheelAction.PassThrough;
        }

        if (Math.Abs(_sumX) < HorizontalThreshold)
            return CardWheelAction.Swallow;

        if (Math.Abs(_sumX) > Math.Abs(_sumY) * HorizontalDominanceRatio)
        {
            _mode = Mode.Page;
            return _sumX > 0 ? CardWheelAction.TurnNext : CardWheelAction.TurnPrev;
        }

        _mode = Mode.Scroll;
        return CardWheelAction.PassThrough;
    }
}

public enum ViewerWheelKind
{
    Ignore,
    StepNext,
    StepPrev,
    SwipeDelta,
    SwipeSettle,
}

public readonly record struct ViewerWheelDecision(ViewerWheelKind Kind, double SwipeDx = 0);

/// Routes wheel & touchpad input inside the unified Viewer (both photos and videos):
///  * Mouse scroll wheel (vertical or horizontal, standard 120-notch or high-res free-spin) steps
///    one item per 120-unit detent.
///  * Touchpad two-finger horizontal swipe drives the 3-page strip continuously and swallows
///    trailing decaying momentum once the swipe settles.
///  * Touchpad vertical scroll is ignored when unzoomed so it never blasts through multiple items.
public sealed class ViewerWheelRouter
{
    const long MouseIdleResetMs = 250;
    const long PadNewGestureGapMs = 320;
    const long PadPauseGrowGapMs = 90;

    int _mouseAccum;
    long _mouseLastMs;

    long _padLastMs;
    int _padLastMag;
    int _padDir;
    bool _padDecaying;
    bool _padActive;
    bool _padSwallowMomentum;

    public void Reset()
    {
        _mouseAccum = 0;
        _mouseLastMs = 0;
        _padLastMs = 0;
        _padLastMag = 0;
        _padDir = 0;
        _padDecaying = false;
        _padActive = false;
        _padSwallowMomentum = false;
    }

    public void NotifyTimerSettled()
    {
        _padActive = false;
        if (_padDecaying) _padSwallowMomentum = true;
    }

    public ViewerWheelDecision OnWheel(bool isHorizontal, int delta, bool isTouchpad, long nowMs)
    {
        if (delta == 0) return new ViewerWheelDecision(ViewerWheelKind.Ignore);

        if (!isTouchpad)
        {
            _padActive = false;
            _padSwallowMomentum = false;
            // Vertical mouse wheel down (<0) -> next; horizontal mouse wheel right (>0) -> next.
            var signed = isHorizontal ? delta : -delta;
            if (_mouseLastMs == 0 || nowMs - _mouseLastMs > MouseIdleResetMs ||
                (_mouseAccum != 0 && Math.Sign(signed) != Math.Sign(_mouseAccum)))
                _mouseAccum = 0;
            _mouseLastMs = nowMs;
            _mouseAccum += signed;

            if (Math.Abs(_mouseAccum) >= 120)
            {
                var next = _mouseAccum > 0;
                _mouseAccum -= Math.Sign(_mouseAccum) * 120;
                return new ViewerWheelDecision(next ? ViewerWheelKind.StepNext : ViewerWheelKind.StepPrev);
            }
            return new ViewerWheelDecision(ViewerWheelKind.Ignore);
        }

        // Touchpad vertical scroll while unzoomed: do not accidentally flip pages.
        if (!isHorizontal)
            return new ViewerWheelDecision(ViewerWheelKind.Ignore);

        var mag = Math.Abs(delta);
        var sign = Math.Sign(delta);
        var gap = _padLastMs == 0 ? long.MaxValue : nowMs - _padLastMs;
        var fresh = gap > PadNewGestureGapMs ||
                    (gap > PadPauseGrowGapMs && mag > _padLastMag + 2) ||
                    (_padDir != 0 && sign != _padDir && mag > 2) ||
                    (_padDecaying && mag > _padLastMag * 1.6 + 6);

        if (fresh)
        {
            _padDecaying = false;
            _padSwallowMomentum = false;
        }
        else if (mag < _padLastMag - 1)
        {
            _padDecaying = true;
        }

        _padLastMs = nowMs;
        _padLastMag = mag;
        if (mag > 1) _padDir = sign;

        if (_padSwallowMomentum)
            return new ViewerWheelDecision(ViewerWheelKind.Ignore);

        if (_padActive && _padDecaying && mag <= 3)
        {
            _padActive = false;
            _padSwallowMomentum = true;
            return new ViewerWheelDecision(ViewerWheelKind.SwipeSettle);
        }

        _padActive = true;
        return new ViewerWheelDecision(ViewerWheelKind.SwipeDelta, -delta * 0.85);
    }
}
