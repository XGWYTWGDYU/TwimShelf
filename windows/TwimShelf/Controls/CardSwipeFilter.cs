// Pure, UI-free wheel & trackpad gesture engine replicating Electron/Web's proven WheelStream,
// PostCard, and Viewer parameters verbatim (with split-axis tracking for WinUI 3's separate
// WM_MOUSEWHEEL / WM_MOUSEHWHEEL messages and RDP-safe mouse vs touchpad handling):
//  * Browse PostCard: exact Electron PostCard.tsx + WheelStream parameters (100/120 px scale,
//    hypot >= 10px, |sx| > |sy| * 2, single-page turn + momentum swallowing). Mouse vertical wheel
//    always scrolls the Browse page vertically; local physical mouse tilt-wheel and Shift+wheel
//    never flip cards.
//  * Viewer (photo & video): exact Electron Viewer.tsx + WheelStream parameters for horizontal
//    two-finger swipes (1:1 strip follow, immediate momentum settle, full-stride single-page lock,
//    90ms end timer with v*0.3) plus safe discrete vertical mouse-wheel stepping that never blasts
//    through multiple items on trackpad or RDP scroll bursts.
using System.Threading;

namespace TwimShelf.Controls;

/// Hardware-backed local Mouse vs Precision Touchpad input tracker (fed by InputSourceTracker).
public static class TouchpadInputState
{
    static long _lastTouchpadTick;
    static long _lastPhysicalMouseWheelTick;

    public static void RecordTouchpad(long tickMs) => Volatile.Write(ref _lastTouchpadTick, tickMs);
    public static void RecordPhysicalMouseWheel(long tickMs) => Volatile.Write(ref _lastPhysicalMouseWheelTick, tickMs);

    public static long LastTouchpadTick => Volatile.Read(ref _lastTouchpadTick);
    public static long LastPhysicalMouseWheelTick => Volatile.Read(ref _lastPhysicalMouseWheelTick);

    /// True only when a local hardware Precision Touchpad (HID 0x0D/0x05) is active or in inertia
    /// and no newer physical mouse wheel fired.
    public static bool IsLocalPrecisionTouchpadActive(long nowMs, long lastTouchpadTick, long lastPhysicalMouseWheelTick)
    {
        var padRecent = lastTouchpadTick > 0 && (nowMs - lastTouchpadTick) is >= 0 and <= 1500;
        if (!padRecent) return false;
        var mouseRecent = lastPhysicalMouseWheelTick > 0 && (nowMs - lastPhysicalMouseWheelTick) is >= 0 and <= 150;
        return !mouseRecent || lastTouchpadTick > lastPhysicalMouseWheelTick;
    }

    public static bool IsLocalPrecisionTouchpadActive(long nowMs) =>
        IsLocalPrecisionTouchpadActive(nowMs, LastTouchpadTick, LastPhysicalMouseWheelTick);

    /// True only on a LOCAL (non-RDP) session when a real physical mouse hardware wheel just fired
    /// without an active Precision Touchpad. Over RDP, trackpads arrive via the virtual mouse
    /// driver so this always returns false.
    public static bool IsLocalPhysicalMouseWheel(bool isRemoteSession, long nowMs, long lastTouchpadTick, long lastPhysicalMouseWheelTick)
    {
        if (isRemoteSession) return false;
        var mouseRecent = lastPhysicalMouseWheelTick > 0 && (nowMs - lastPhysicalMouseWheelTick) is >= 0 and <= 150;
        if (!mouseRecent) return false;
        var padRecent = lastTouchpadTick > 0 && (nowMs - lastTouchpadTick) is >= 0 and <= 1500;
        return !padRecent || lastPhysicalMouseWheelTick >= lastTouchpadTick;
    }

    public static bool IsLocalPhysicalMouseWheel(bool isRemoteSession, long nowMs) =>
        IsLocalPhysicalMouseWheel(isRemoteSession, nowMs, LastTouchpadTick, LastPhysicalMouseWheelTick);
}

/// Direct C# port of web/app/src/lib/wheelGesture.ts (`WheelStream`) with exact constants
/// (gap > 400, gap > 90 && mag > lastMag + 1, decaying && mag > lastMag * 1.6 + 4,
/// mag < lastMag - 0.5), extended to track horizontal and vertical axis magnitudes independently
/// so WinUI 3's split WM_MOUSEWHEEL / WM_MOUSEHWHEEL messages never falsely trigger decay.
public sealed class ElectronWheelStream
{
    /// Chromium/Electron on Windows converts 120 wheel units to 100 CSS pixels (3 lines).
    public const double PxPerWheelDelta = 100.0 / 120.0;

    long _lastMs;
    double _lastMagX;
    double _lastMagY;
    bool _decayingX;
    bool _decayingY;
    int _dirX;
    int _dirY;

    /// Momentum after fingers lifted on the active axis.
    public bool Momentum { get; private set; }

    public void Reset()
    {
        _lastMs = 0;
        _lastMagX = 0;
        _lastMagY = 0;
        _decayingX = false;
        _decayingY = false;
        _dirX = 0;
        _dirY = 0;
        Momentum = false;
    }

    /// Feeds one wheel event (in CSS pixel units: deltaX > 0 = scroll right, deltaY > 0 = scroll down).
    /// Returns true when this event begins a fresh gesture.
    public bool Next(double deltaX, double deltaY, long nowMs)
    {
        var ax = Math.Abs(deltaX);
        var ay = Math.Abs(deltaY);
        var horizontal = ax >= ay;
        var mag = horizontal ? ax : ay;
        var lastMag = horizontal ? _lastMagX : _lastMagY;
        var decaying = horizontal ? _decayingX : _decayingY;
        var dx = Math.Sign(deltaX);
        var dy = Math.Sign(deltaY);
        var gap = _lastMs == 0 ? long.MaxValue : nowMs - _lastMs;

        // Exact Electron WheelStream gesture boundary rules:
        var fresh = gap > 400 || (gap > 90 && mag > lastMag + 1.0);
        if (!fresh && mag > 2.0)
        {
            if (horizontal && dx != 0 && _dirX != 0 && dx != _dirX) fresh = true;
            else if (!horizontal && dy != 0 && _dirY != 0 && dy != _dirY) fresh = true;
            else if (decaying && mag > lastMag * 1.6 + 4.0) fresh = true;
        }

        if (fresh)
        {
            _decayingX = false;
            _decayingY = false;
            _lastMagX = 0;
            _lastMagY = 0;
            Momentum = false;
            _dirX = 0;
            _dirY = 0;
            decaying = false;
            lastMag = 0;
        }
        else if (lastMag > 0 && mag < lastMag - 0.5)
        {
            decaying = true;
        }

        var axisMomentum = decaying && mag <= lastMag;
        if (horizontal)
        {
            _decayingX = decaying;
            _lastMagX = mag;
            if (dx != 0 && ax > 1.0) _dirX = dx;
        }
        else
        {
            _decayingY = decaying;
            _lastMagY = mag;
            if (dy != 0 && ay > 1.0) _dirY = dy;
        }

        Momentum = axisMomentum;
        _lastMs = nowMs;
        return fresh;
    }
}

public enum CardWheelAction
{
    PassThrough,
    Swallow,
    TurnNext,
    TurnPrev,
}

/// Direct C# port of web/app/src/pages/browse/PostCard.tsx wheel paging (with Electron's exact
/// thresholds: hypot >= 10px, |sx| > |sy| * 2, vertical release |dy| > |dx| && |dy| > 2).
/// Works identically for local Precision Touchpads and Remote Desktop (RDP) forwarded trackpads,
/// while mouse vertical wheels (and local physical mouse horizontal tilt-wheels / Shift+wheel)
/// always pass through so the Browse feed scrolls vertically.
public sealed class CardSwipeFilter
{
    enum Mode { Undecided, Page, Scroll }

    readonly ElectronWheelStream _stream = new();
    Mode _mode = Mode.Undecided;
    double _sx;
    double _sy;
    int _eventsInGesture;

    public void Reset()
    {
        _stream.Reset();
        _mode = Mode.Undecided;
        _sx = 0;
        _sy = 0;
        _eventsInGesture = 0;
    }

    public CardWheelAction OnWheel(
        bool isHorizontal,
        int delta,
        bool ctrlDown,
        bool shiftDown,
        bool isLocalPhysicalMouseHWheel,
        bool canPage,
        long nowMs)
    {
        if (delta == 0 || ctrlDown || shiftDown)
            return CardWheelAction.PassThrough;

        // On a local (non-RDP) session, a physical mouse's tilt/thumb horizontal wheel never turns
        // Browse cards. Vertical mouse wheels always flow to Mode.Scroll -> PassThrough below.
        if (isHorizontal && isLocalPhysicalMouseHWheel)
        {
            Reset();
            return CardWheelAction.PassThrough;
        }

        // Convert WinUI MouseWheelDelta to Electron CSS pixel units:
        // WM_MOUSEHWHEEL (+ = right -> +deltaX); WM_MOUSEWHEEL (+ = up -> -deltaY).
        var deltaX = isHorizontal ? delta * ElectronWheelStream.PxPerWheelDelta : 0.0;
        var deltaY = isHorizontal ? 0.0 : -delta * ElectronWheelStream.PxPerWheelDelta;

        if (_stream.Next(deltaX, deltaY, nowMs))
        {
            _mode = _stream.Momentum ? Mode.Scroll : Mode.Undecided;
            _sx = 0;
            _sy = 0;
            _eventsInGesture = 0;
        }

        if (_mode == Mode.Scroll)
            return CardWheelAction.PassThrough;

        if (_mode == Mode.Page)
        {
            // A vertical movement now is a scroll the fingers started: let it through immediately.
            if (Math.Abs(deltaY) > Math.Abs(deltaX) && Math.Abs(deltaY) > 2.0)
            {
                _mode = Mode.Scroll;
                return CardWheelAction.PassThrough;
            }
            return CardWheelAction.Swallow;
        }

        _sx += deltaX;
        _sy += deltaY;
        _eventsInGesture++;

        // WinUI 3 delivers horizontal and vertical components of a diagonal gesture as separate
        // WM_MOUSEHWHEEL / WM_MOUSEWHEEL messages; wait one extra event for small horizontal deltas
        // so a paired vertical event can arrive before committing to horizontal paging.
        if (Math.Sqrt(_sx * _sx + _sy * _sy) < 10.0 ||
            (_eventsInGesture == 1 && isHorizontal && Math.Abs(_sx) < 28.0))
            return Math.Abs(deltaX) > Math.Abs(deltaY) ? CardWheelAction.Swallow : CardWheelAction.PassThrough;

        if (Math.Abs(_sx) > Math.Abs(_sy) * 2.0 && canPage)
        {
            _mode = Mode.Page;
            return _sx > 0 ? CardWheelAction.TurnNext : CardWheelAction.TurnPrev;
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
    SwipeBeginAndMove, // Cancel any running strip animation and move strip by SwipeDx
    SwipeMove,         // Continue moving strip by SwipeDx
    SwipeMomentumSettle, // Momentum started after finger lift: settle immediately with full velocity
    SwipeResetTimerOnly, // Gesture active (not yet committed to horizontal), keep 90ms idle timer alive
}

public readonly record struct ViewerWheelDecision(
    ViewerWheelKind Kind,
    double SwipeDx = 0,
    bool EndPreviousSwipeFirst = false);

/// Direct C# port of web/app/src/viewer/Viewer.tsx wheel paging + safe discrete mouse vertical
/// wheel stepping:
///  * Horizontal two-finger swipes (local Precision Touchpad OR Remote Desktop forwarded trackpad)
///    replicate Electron Viewer.tsx verbatim: |dx| > 4 && |dx| > |dy| * 1.2, immediate momentum
///    settle, full-stride single-page lock (`MarkSwipeDone`), 90ms idle timer with v*0.3.
///  * Discrete physical mouse vertical wheel clicks (±120) step 1 page cleanly on photos & videos,
///    while guarding against trackpad / RDP vertical scroll bursts (ignores fractional deltas,
///    ignores active Precision Touchpad vertical scroll, ignores during in-flight slide animation,
///    ignores decaying momentum, and enforces a 180ms same-direction cooldown).
public sealed class ViewerWheelRouter
{
    const long VerticalCooldownMs = 180;

    readonly ElectronWheelStream _stream = new();
    bool _hasSwipe;
    bool _swipeOn;
    bool _swipeDone;
    double _accDx;
    double _accDy;

    bool _seenFractionalVerticalInGesture;
    long _lastVerticalStepMs;
    int _lastVerticalStepDir;

    public bool IsSwipeActive => _hasSwipe && _swipeOn && !_swipeDone;

    public void Reset()
    {
        _stream.Reset();
        _hasSwipe = false;
        _swipeOn = false;
        _swipeDone = false;
        _accDx = 0;
        _accDy = 0;
        _seenFractionalVerticalInGesture = false;
        _lastVerticalStepMs = 0;
        _lastVerticalStepDir = 0;
    }

    /// Called when the strip reaches a full stride during a swipe (Electron line 242) so the
    /// remainder of the gesture and its momentum cannot flip a second page.
    public void MarkSwipeDone()
    {
        if (_hasSwipe) _swipeDone = true;
    }

    /// Called when the 90ms idle timer fires (Electron `endSwipe`).
    public void EndSwipe()
    {
        _hasSwipe = false;
        _swipeOn = false;
        _swipeDone = false;
        _accDx = 0;
        _accDy = 0;
    }

    public ViewerWheelDecision OnWheel(
        bool isHorizontal,
        int delta,
        bool isLocalPrecisionTouchpad,
        bool stripAnimating,
        long nowMs)
    {
        if (delta == 0) return new ViewerWheelDecision(ViewerWheelKind.Ignore);

        // Exact Electron pixel scaling: WM_MOUSEHWHEEL (+ = right -> +deltaX),
        // WM_MOUSEWHEEL (+ = up -> -deltaY).
        var deltaX = isHorizontal ? delta * ElectronWheelStream.PxPerWheelDelta : 0.0;
        var deltaY = isHorizontal ? 0.0 : -delta * ElectronWheelStream.PxPerWheelDelta;

        var fresh = _stream.Next(deltaX, deltaY, nowMs);
        var endPrev = false;
        if (fresh)
        {
            if (_hasSwipe && _swipeOn && !_swipeDone) endPrev = true;
            EndSwipe();
            _seenFractionalVerticalInGesture = false;
            // Momentum of a gesture that already finished moves nothing.
            if (_stream.Momentum)
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);
        }

        // ---- Vertical wheel (mouse vertical wheel steps prev/next; trackpad vertical ignored) ----
        if (!isHorizontal)
        {
            if (Math.Abs(delta) % 120 != 0)
            {
                _seenFractionalVerticalInGesture = true;
                // Keep vertical accumulator updated for horizontal-vs-vertical axis lock in Viewer.
                if (_hasSwipe && !_swipeOn && !_swipeDone) _accDy += -deltaY;
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);
            }

            // If a horizontal swipe is already active, ignore incidental vertical ticks.
            if (_hasSwipe && _swipeOn && !_swipeDone)
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);

            // Trackpad vertical scroll (local Precision Touchpad or fractional RDP stream) never flips.
            if (isLocalPrecisionTouchpad || _seenFractionalVerticalInGesture || _stream.Momentum)
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);

            // Guard against quantized RDP bursts / free-spin wheels: never stack steps while a
            // page slide animation is already running, and enforce a 180ms same-direction cooldown.
            var dir = delta < 0 ? 1 : -1;
            if (stripAnimating)
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);
            if (_lastVerticalStepMs > 0 && dir == _lastVerticalStepDir && nowMs - _lastVerticalStepMs < VerticalCooldownMs)
                return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);

            _lastVerticalStepMs = nowMs;
            _lastVerticalStepDir = dir;
            return new ViewerWheelDecision(dir > 0 ? ViewerWheelKind.StepNext : ViewerWheelKind.StepPrev, 0, endPrev);
        }

        // ---- Horizontal wheel / touchpad sideways swipe (100% Electron Viewer.tsx parity) ----
        // Never start a fresh swipe from a late decaying momentum packet after the 90ms idle timer.
        if (!_hasSwipe && _stream.Momentum)
            return new ViewerWheelDecision(ViewerWheelKind.Ignore, 0, endPrev);

        if (!_hasSwipe)
        {
            _hasSwipe = true;
            _swipeOn = false;
            _swipeDone = false;
            _accDx = 0;
            _accDy = 0;
        }

        if (_swipeDone)
            return new ViewerWheelDecision(ViewerWheelKind.SwipeResetTimerOnly, 0, endPrev);

        // Events started shrinking: fingers lifted and this is the trackpad's momentum.
        // Settle immediately with the fingers' velocity and swallow all remaining momentum.
        if (_swipeOn && _stream.Momentum)
        {
            _swipeDone = true;
            return new ViewerWheelDecision(ViewerWheelKind.SwipeMomentumSettle, 0, endPrev);
        }

        var dx = -deltaX;
        var dy = -deltaY;
        if (!_swipeOn)
        {
            _accDx += dx;
            _accDy += dy;
            if (!(Math.Abs(_accDx) > 4.0 && Math.Abs(_accDx) > Math.Abs(_accDy) * 1.2))
                return new ViewerWheelDecision(ViewerWheelKind.SwipeResetTimerOnly, 0, endPrev);

            _swipeOn = true;
            return new ViewerWheelDecision(ViewerWheelKind.SwipeBeginAndMove, _accDx, endPrev);
        }

        return dx != 0
            ? new ViewerWheelDecision(ViewerWheelKind.SwipeMove, dx, endPrev)
            : new ViewerWheelDecision(ViewerWheelKind.SwipeResetTimerOnly, 0, endPrev);
    }
}
