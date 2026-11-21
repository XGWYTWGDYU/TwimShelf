// Pure geometry and physics for the unified media viewer: zoom open/close transition (matching
// Apple MacFeed, Web transition.ts, and Flutter _ZoomFlight), horizontal strip paging & swipe
// settle (matching MacPhotoView & Web Viewer), interactive drag-to-dismiss (matching Flutter),
// and cursor-anchored photo zoom/pan clamping.
using Windows.Foundation;

namespace TwimShelf.Controls.ViewerEngine;

public readonly record struct TransitionFrame(
    double Scale,
    double OffsetX,
    double OffsetY,
    double ClipX,
    double ClipY,
    double ClipW,
    double ClipH,
    double ClipCornerRadius,
    double SurfaceOpacity,
    double BackdropOpacity,
    double ChromeOpacity);

public readonly record struct DismissState(double OffsetX, double OffsetY, double Scale, double Progress)
{
    public static readonly DismissState None = new(0, 0, 1.0, 0.0);
    public bool IsActive => Math.Abs(OffsetX) > 0.01 || Math.Abs(OffsetY) > 0.01 || Math.Abs(Scale - 1.0) > 0.001;
}

public readonly record struct PhotoView(double Scale, double X, double Y)
{
    public static readonly PhotoView Identity = new(1.0, 0.0, 0.0);
    public bool IsZoomed => Scale > 1.001;
}

public static class ViewerMath
{
    public const double PageGap = 40.0;
    public const double OpenDuration = 0.28;
    public const double CloseDuration = 0.25;
    public const double FadeFallbackDuration = 0.18;
    public const double SpringBackDuration = 0.24;
    public const double UnhideThreshold = 0.12;
    public const double ReverseDissolveTail = 0.10;

    /// Aspect-fit rect of media (mediaW x mediaH) centered inside bounds.
    public static Rect FitMedia(Rect bounds, double mediaW, double mediaH)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0) return new Rect(bounds.X, bounds.Y, 0, 0);
        if (mediaW <= 0 || mediaH <= 0 || !double.IsFinite(mediaW) || !double.IsFinite(mediaH)) return bounds;
        var scale = Math.Min(bounds.Width / mediaW, bounds.Height / mediaH);
        var w = mediaW * scale;
        var h = mediaH * scale;
        return new Rect(bounds.X + (bounds.Width - w) * 0.5, bounds.Y + (bounds.Height - h) * 0.5, w, h);
    }

    /// Aspect-fit rect of media with a known aspect ratio (width / height) centered inside bounds.
    public static Rect FitAspect(Rect bounds, double aspect)
    {
        if (aspect <= 0 || !double.IsFinite(aspect)) return bounds;
        return FitMedia(bounds, aspect, 1.0);
    }

    /// Intersection of two rects; Width/Height are 0 when disjoint.
    public static Rect Intersect(Rect a, Rect b)
    {
        var left = Math.Max(a.X, b.X);
        var top = Math.Max(a.Y, b.Y);
        var right = Math.Min(a.X + a.Width, b.X + b.Width);
        var bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
        return new Rect(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
    }

    public static double EaseOutCubic(double t)
    {
        t = Math.Clamp(t, 0.0, 1.0);
        var u = 1.0 - t;
        return 1.0 - u * u * u;
    }

    public static double EaseInOutCubic(double t)
    {
        t = Math.Clamp(t, 0.0, 1.0);
        return t < 0.5 ? 4.0 * t * t * t : 1.0 - Math.Pow(-2.0 * t + 2.0, 3.0) * 0.5;
    }

    public static double EaseInQuad(double t)
    {
        t = Math.Clamp(t, 0.0, 1.0);
        return t * t;
    }

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;

    /// Computes exact GPU composition transform + local-space rounded-rect clip + layer opacities
    /// for a zoom transition at normalized raw progress `raw` (0 = source tile/card, 1 = full viewer).
    /// When `source` is null/empty, produces a smooth fade + subtle shrink fallback (0.92 <-> 1.0).
    public static TransitionFrame EvaluateTransition(
        Rect bounds,
        Rect media,
        Rect? source,
        bool cropSource,
        double sourceCornerRadius,
        double raw,
        bool closing,
        DismissState dismiss)
    {
        raw = Math.Clamp(raw, 0.0, 1.0);
        var t = closing ? 1.0 - EaseOutCubic(1.0 - raw) : EaseInOutCubic(raw);
        var backdrop = EaseOutCubic(raw) * (1.0 - dismiss.Progress);
        var chrome = EaseInQuad(Math.Clamp((raw - 0.25) / 0.75, 0.0, 1.0)) * Math.Clamp(1.0 - dismiss.Progress * 4.0, 0.0, 1.0);

        if (bounds.Width <= 0 || bounds.Height <= 0)
            return new TransitionFrame(1, 0, 0, 0, 0, 0, 0, 0, 1, backdrop, chrome);

        // At rest (fully open, not animating transition): only dismiss drag (if any) applies.
        if (raw >= 0.9999 && !closing)
        {
            if (!dismiss.IsActive)
                return new TransitionFrame(1, 0, 0, 0, 0, bounds.Width, bounds.Height, 0, 1, 1, 1);

            var cx = bounds.X + bounds.Width * 0.5;
            var cy = bounds.Y + bounds.Height * 0.5;
            var ox = (cx + dismiss.OffsetX) - cx * dismiss.Scale;
            var oy = (cy + dismiss.OffsetY) - cy * dismiss.Scale;
            return new TransitionFrame(dismiss.Scale, ox, oy, 0, 0, bounds.Width, bounds.Height, 0, 1, backdrop, chrome);
        }

        // Fallback when source rect is unavailable (e.g. scrolled off-screen or reduced motion):
        if (source is not { } src || src.Width <= 0.5 || src.Height <= 0.5 || media.Width <= 0.5 || media.Height <= 0.5)
        {
            var s = Lerp(0.92, 1.0, t) * dismiss.Scale;
            var cx = bounds.X + bounds.Width * 0.5;
            var cy = bounds.Y + bounds.Height * 0.5;
            var ox = (cx + dismiss.OffsetX * t) - cx * s;
            var oy = (cy + dismiss.OffsetY * t) - cy * s;
            return new TransitionFrame(s, ox, oy, 0, 0, bounds.Width, bounds.Height, 0, t, backdrop, chrome);
        }

        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;
        var srcCx = src.X + src.Width * 0.5;
        var srcCy = src.Y + src.Height * 0.5;
        var endCx = mediaCx + dismiss.OffsetX;
        var endCy = mediaCy + dismiss.OffsetY;
        var endScale = dismiss.Scale;

        // Uniform cover scale for cropped tiles (square grid); aspect-matched cover/fit for cards.
        var scale0 = cropSource
            ? Math.Max(src.Width / media.Width, src.Height / media.Height)
            : Math.Min(src.Width / media.Width, src.Height / media.Height);
        scale0 = Math.Max(scale0, 1e-4);

        var scale = Math.Max(Lerp(scale0, endScale, t), 1e-4);
        var centerX = Lerp(srcCx, endCx, t);
        var centerY = Lerp(srcCy, endCy, t);

        // Local-space clip rect around media center so the visible screen rect morphs seamlessly
        // from src (width, height, sourceCornerRadius) to media * endScale (cornerRadius = 0).
        var screenW = Lerp(src.Width, media.Width * endScale, t);
        var screenH = Lerp(src.Height, media.Height * endScale, t);
        var clipW = Math.Max(0, screenW / scale);
        var clipH = Math.Max(0, screenH / scale);
        var clipX = mediaCx - clipW * 0.5;
        var clipY = mediaCy - clipH * 0.5;
        var screenRadius = Lerp(Math.Max(0, sourceCornerRadius), 0.0, t);
        var localRadius = screenRadius / scale;

        // Top-left Visual origin: local point (mediaCx, mediaCy) maps to (centerX, centerY).
        var offsetX = centerX - mediaCx * scale;
        var offsetY = centerY - mediaCy * scale;

        var surfaceOpacity = 1.0;
        if (closing && raw < ReverseDissolveTail)
            surfaceOpacity = Math.Clamp(raw / ReverseDissolveTail, 0.0, 1.0);

        return new TransitionFrame(scale, offsetX, offsetY, clipX, clipY, clipW, clipH, localRadius, surfaceOpacity, backdrop, chrome);
    }

    // ---- Horizontal strip paging & swipe settle (matching MacPhotoView & Web Viewer) ----

    public static double Stride(double viewportWidth) => Math.Max(1.0, viewportWidth) + PageGap;

    /// Applies a horizontal drag/swipe delta `dx` to the current strip `offset` with 0.3× edge
    /// resistance past the first and last pages.
    public static double ApplyStripDelta(double offset, double dx, int index, int count, double stride)
    {
        if (count <= 1 || stride <= 0) return 0;
        var atEnd = (offset + dx > 0 && index <= 0) || (offset + dx < 0 && index >= count - 1);
        return Math.Clamp(offset + (atEnd ? dx * 0.3 : dx), -stride, stride);
    }

    /// Decides which page delta (-1, 0, +1) and settle duration (seconds) to animate to on release.
    public static (int Delta, double Duration) SettleStrip(double offset, double velocityPxPerSec, int index, int count, double stride)
    {
        if (count <= 1 || stride <= 0) return (0, 0.25);
        int d;
        if (Math.Abs(velocityPxPerSec) > 350.0 && ((velocityPxPerSec < 0) == (offset <= 0) || Math.Abs(offset) < stride * 0.1))
            d = velocityPxPerSec < 0 ? 1 : -1;
        else
            d = (int)Math.Round(-(offset + velocityPxPerSec * 0.1) / stride);

        d = Math.Clamp(d, -1, 1);
        if (index + d < 0 || index + d >= count) d = 0;

        var target = -d * stride;
        var distance = Math.Abs(target - offset);
        // Ease-out cubic starts at 3× its average speed: match the release velocity cleanly.
        var matched = Math.Abs(velocityPxPerSec) > 1.0 ? 3.0 * distance / Math.Abs(velocityPxPerSec) : 0.30;
        return (d, Math.Clamp(matched, 0.16, 0.38));
    }

    /// Caption opacity while swiping horizontally: stays 1.0 when paging within the same post,
    /// fades smoothly over the first 40% of stride when moving toward a different post.
    public static double CaptionFade(double offset, double stride, string? currentPostId, string? towardsPostId)
    {
        if (Math.Abs(offset) < 0.01 || stride <= 0 || towardsPostId == null) return 1.0;
        if (!string.IsNullOrEmpty(currentPostId) && currentPostId == towardsPostId) return 1.0;
        return Math.Clamp(1.0 - Math.Abs(offset) / Math.Max(1.0, stride * 0.4), 0.0, 1.0);
    }

    // ---- Interactive drag-to-dismiss (matching Flutter ViewerPage) ----

    public static double EdgeZoneWidth(double viewportWidth) => Math.Clamp(viewportWidth * 0.10, 32.0, 48.0);

    public static DismissState EvaluateDismiss(double rawDx, double rawDy, double viewportW, double viewportH, bool fromEdge, int edgeDir)
    {
        double visualX, visualY, distance, extent;
        if (fromEdge)
        {
            var inward = rawDx * edgeDir;
            visualX = inward < 0 ? rawDx * 0.28 : rawDx;
            visualY = rawDy;
            distance = Math.Max(0.0, inward);
            extent = Math.Min(viewportW * 0.50, 240.0);
        }
        else
        {
            visualX = rawDx;
            visualY = rawDy < 0 ? rawDy * 0.28 : rawDy;
            distance = Math.Max(0.0, rawDy);
            extent = Math.Min(viewportH * 0.45, 320.0);
        }
        var progress = extent <= 0 ? 0.0 : Math.Clamp(distance / extent, 0.0, 1.0);
        return new DismissState(visualX, visualY, 1.0 - 0.34 * progress, progress);
    }

    public static bool ShouldCommitDismiss(double rawDx, double rawDy, double vx, double vy, double viewportW, double viewportH, bool fromEdge, int edgeDir)
    {
        if (fromEdge)
        {
            var inward = rawDx * edgeDir;
            var vin = vx * edgeDir;
            var threshold = Math.Min(viewportW * 0.18, 96.0);
            return vin >= -250.0 && (inward > threshold || (vin > 320.0 && inward > 8.0));
        }
        else
        {
            var threshold = Math.Min(viewportH * 0.12, 84.0);
            return vy >= -250.0 && (rawDy > threshold || (vy > 280.0 && rawDy > 8.0));
        }
    }

    // ---- Photo zoom & pan clamping (matching Web PhotoPage.tsx) ----

    public const double MinPhotoZoom = 1.0;
    public const double MaxPhotoZoom = 8.0;
    public const double DoubleClickZoom = 2.5;

    /// Clamps pan offset so the photo stays centered when smaller than the viewport and its edges
    /// never pull inside the viewport when larger.
    public static PhotoView ClampPhotoView(PhotoView v, double baseW, double baseH, double viewW, double viewH)
    {
        var s = Math.Clamp(v.Scale, MinPhotoZoom, MaxPhotoZoom);
        if (s <= 1.0001) return PhotoView.Identity;
        var mx = Math.Max(0.0, (baseW * s - viewW) * 0.5);
        var my = Math.Max(0.0, (baseH * s - viewH) * 0.5);
        return new PhotoView(s, Math.Clamp(v.X, -mx, mx), Math.Clamp(v.Y, -my, my));
    }

    /// Zooms to `targetScale` keeping viewport point `(px, py)` stationary under the cursor/finger.
    public static PhotoView ZoomPhotoAt(PhotoView current, double targetScale, double px, double py, double baseW, double baseH, double viewW, double viewH)
    {
        var ns = Math.Clamp(targetScale, MinPhotoZoom, MaxPhotoZoom);
        var cx = px - viewW * 0.5;
        var cy = py - viewH * 0.5;
        var k = ns / Math.Max(current.Scale, 1e-4);
        return ClampPhotoView(new PhotoView(ns, cx - (cx - current.X) * k, cy - (cy - current.Y) * k), baseW, baseH, viewW, viewH);
    }

    /// Computes the visible rect of a fitted photo inside the viewport at the given `PhotoView`.
    public static Rect PhotoMediaFrame(double viewW, double viewH, double baseW, double baseH, PhotoView v)
    {
        var w = baseW * v.Scale;
        var h = baseH * v.Scale;
        var rect = new Rect((viewW - w) * 0.5 + v.X, (viewH - h) * 0.5 + v.Y, w, h);
        return Intersect(rect, new Rect(0, 0, viewW, viewH));
    }
}
