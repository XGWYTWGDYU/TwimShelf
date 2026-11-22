// Pure geometry and spring physics for the unified media viewer (modeled after Apple WWDC24 10145
// fluid zoom transitions, MacPhotoView strip paging, and Flutter interactive drag-to-dismiss):
//  * Velocity-preserving 2D + scale + morph spring flight for zoom open, zoom close, mid-flight
//    reversals, and interactive drag-release launches straight into the source tile or card.
//  * Grab-point-anchored interactive drag-to-dismiss with smooth rubber-band scaling and dynamic
//    rounded corners over the revealed underlying Grid/Browse page.
//  * Horizontal 3-page strip swipe physics, velocity-matched settle, cross-post caption fade,
//    and cursor-anchored photo zoom/pan clamping.
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
    double ChromeOpacity,
    bool UseClip);

public readonly record struct DismissState(
    double CenterX,
    double CenterY,
    double Scale,
    double CornerRadius,
    double Progress)
{
    public static readonly DismissState None = new(0, 0, 1.0, 0.0, 0.0);
    public bool IsActive => Progress > 1e-4 || Math.Abs(Scale - 1.0) > 1e-4;
}

public readonly record struct PhotoView(double Scale, double X, double Y)
{
    public static readonly PhotoView Identity = new(1.0, 0.0, 0.0);
    public bool IsZoomed => Scale > 1.001;
}

/// Substepped analytical damped harmonic oscillator (h <= 1/480s) for silky, interruptible
/// velocity-preserving UI springs (matching Apple UIKit/SwiftUI zoom transition springs).
public struct Spring1D
{
    public double Value;
    public double Velocity;
    public double Target;

    public Spring1D(double value, double target, double velocity = 0)
    {
        Value = value;
        Target = target;
        Velocity = velocity;
    }

    public void Step(double dt, double omega, double dampingRatio)
    {
        dt = Math.Clamp(dt, 0.0, 1.0 / 30.0);
        var rem = dt;
        var twoZetaOmega = 2.0 * dampingRatio * omega;
        var omegaSq = omega * omega;
        while (rem > 1e-6)
        {
            var h = Math.Min(rem, 1.0 / 480.0);
            var a = -omegaSq * (Value - Target) - twoZetaOmega * Velocity;
            Velocity += a * h;
            Value += Velocity * h;
            rem -= h;
        }
    }

    public bool IsSettled(double posEps, double velEps) =>
        Math.Abs(Value - Target) <= posEps && Math.Abs(Velocity) <= velEps;
}

/// Live spring state driving a fluid zoom open/close flight (with velocity inheritance on
/// drag-release and seamless C1 mid-flight reversal).
public sealed class ZoomFlight
{
    public const double OpenOmega = 14.5;
    public const double OpenDamping = 0.94;
    public const double CloseOmega = 16.0;
    public const double CloseDamping = 0.98;

    public Spring1D CenterX;
    public Spring1D CenterY;
    public Spring1D Scale;
    /// 0 = exact source rect (cropped + sourceCornerRadius), 1 = full media rect (un-cropped + fullCornerRadius).
    public Spring1D Morph;

    public Rect Bounds;
    public Rect Media;
    public Rect? Source;
    public bool CropSource;
    public double SourceCornerRadius;
    public double FullCornerRadius;
    public double StartBackdropOpacity = 1.0;
    public double StartChromeOpacity = 1.0;
    public bool Closing;

    public double Scale0 { get; private set; } = 1.0;

    public static ZoomFlight StartOpen(Rect bounds, Rect media, Rect? source, bool cropSource, double sourceCornerRadius)
    {
        var f = new ZoomFlight
        {
            Bounds = bounds,
            Media = media,
            Source = source,
            CropSource = cropSource,
            SourceCornerRadius = Math.Max(0, sourceCornerRadius),
            FullCornerRadius = 0,
            Closing = false,
        };
        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;

        if (source is { Width: > 0.5, Height: > 0.5 } src && media.Width > 0.5 && media.Height > 0.5)
        {
            f.Scale0 = ComputeSourceScale(media, src, cropSource);
            f.CenterX = new Spring1D(src.X + src.Width * 0.5, mediaCx);
            f.CenterY = new Spring1D(src.Y + src.Height * 0.5, mediaCy);
            f.Scale = new Spring1D(f.Scale0, 1.0);
            f.Morph = new Spring1D(0.0, 1.0);
        }
        else
        {
            f.Scale0 = 0.90;
            f.CenterX = new Spring1D(mediaCx, mediaCx);
            f.CenterY = new Spring1D(mediaCy, mediaCy);
            f.Scale = new Spring1D(0.90, 1.0);
            f.Morph = new Spring1D(0.0, 1.0);
        }
        return f;
    }

    public static ZoomFlight StartClose(
        Rect bounds,
        Rect media,
        Rect? source,
        bool cropSource,
        double sourceCornerRadius,
        DismissState? fromDismiss = null,
        double velX = 0,
        double velY = 0)
    {
        var f = new ZoomFlight
        {
            Bounds = bounds,
            Media = media,
            Source = source,
            CropSource = cropSource,
            SourceCornerRadius = Math.Max(0, sourceCornerRadius),
            Closing = true,
        };
        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;

        var startCx = fromDismiss is { IsActive: true } d ? d.CenterX : mediaCx;
        var startCy = fromDismiss is { IsActive: true } d2 ? d2.CenterY : mediaCy;
        var startScale = fromDismiss is { IsActive: true } d3 ? d3.Scale : 1.0;
        f.FullCornerRadius = fromDismiss is { IsActive: true } d4 ? d4.CornerRadius : 0.0;
        f.StartBackdropOpacity = fromDismiss is { IsActive: true } d5
            ? Math.Pow(Math.Clamp(1.0 - d5.Progress, 0.0, 1.0), 1.35)
            : 1.0;
        f.StartChromeOpacity = fromDismiss is { IsActive: true } d6
            ? Math.Clamp(1.0 - d6.Progress * 4.5, 0.0, 1.0)
            : 1.0;

        // Clamp release velocity so extreme flings stay graceful while preserving direction/momentum.
        var clampedVx = Math.Clamp(velX, -2800.0, 2800.0);
        var clampedVy = Math.Clamp(velY, -2800.0, 2800.0);

        if (source is { Width: > 0.5, Height: > 0.5 } src && media.Width > 0.5 && media.Height > 0.5)
        {
            f.Scale0 = ComputeSourceScale(media, src, cropSource);
            f.CenterX = new Spring1D(startCx, src.X + src.Width * 0.5, clampedVx);
            f.CenterY = new Spring1D(startCy, src.Y + src.Height * 0.5, clampedVy);
            f.Scale = new Spring1D(startScale, f.Scale0);
            f.Morph = new Spring1D(1.0, 0.0);
        }
        else
        {
            f.Scale0 = 0.90;
            f.CenterX = new Spring1D(startCx, startCx + clampedVx * 0.06, clampedVx * 0.5);
            f.CenterY = new Spring1D(startCy, startCy + clampedVy * 0.06, clampedVy * 0.5);
            f.Scale = new Spring1D(startScale, startScale * 0.88);
            f.Morph = new Spring1D(1.0, 0.0);
        }
        return f;
    }

    /// Reverses an in-flight opening transition back to `source` with C1 position & velocity continuity.
    public void ReverseToClose(Rect? source)
    {
        Closing = true;
        Source = source;
        if (source is { Width: > 0.5, Height: > 0.5 } src && Media.Width > 0.5 && Media.Height > 0.5)
        {
            Scale0 = ComputeSourceScale(Media, src, CropSource);
            CenterX.Target = src.X + src.Width * 0.5;
            CenterY.Target = src.Y + src.Height * 0.5;
            Scale.Target = Scale0;
            Morph.Target = 0.0;
        }
        else
        {
            Scale.Target = 0.90;
            Morph.Target = 0.0;
        }
    }

    public static double ComputeSourceScale(Rect media, Rect src, bool cropSource)
    {
        if (media.Width <= 0.5 || media.Height <= 0.5) return 1.0;
        var s = cropSource
            ? Math.Max(src.Width / media.Width, src.Height / media.Height)
            : Math.Min(src.Width / media.Width, src.Height / media.Height);
        return Math.Max(s, 1e-4);
    }

    public bool Step(double dt)
    {
        var omega = Closing ? CloseOmega : OpenOmega;
        var damping = Closing ? CloseDamping : OpenDamping;
        CenterX.Step(dt, omega, damping);
        CenterY.Step(dt, omega, damping);
        Scale.Step(dt, omega, damping);
        Morph.Step(dt, omega, damping);

        return CenterX.IsSettled(0.35, 3.0)
            && CenterY.IsSettled(0.35, 3.0)
            && Scale.IsSettled(0.0006, 0.01)
            && Morph.IsSettled(0.0006, 0.01);
    }

    public double NormalizedMorph => Math.Clamp(Morph.Value, 0.0, 1.0);

    public TransitionFrame CurrentFrame()
    {
        var m = NormalizedMorph;
        var mediaCx = Media.X + Media.Width * 0.5;
        var mediaCy = Media.Y + Media.Height * 0.5;
        var s = Math.Max(Scale.Value, 1e-4);
        var offsetX = CenterX.Value - mediaCx * s;
        var offsetY = CenterY.Value - mediaCy * s;

        var backdrop = Closing
            ? StartBackdropOpacity * Math.Clamp(m * m, 0.0, 1.0)
            : Math.Clamp(ViewerMath.EaseOutCubic(m), 0.0, 1.0);
        var chrome = Closing
            ? StartChromeOpacity * Math.Clamp((m - 0.55) / 0.45, 0.0, 1.0)
            : ViewerMath.EaseInQuad(Math.Clamp((m - 0.30) / 0.70, 0.0, 1.0));

        if (Source is { Width: > 0.5, Height: > 0.5 } src && Media.Width > 0.5 && Media.Height > 0.5)
        {
            // Local-space clip rect morphs smoothly between the exact source rect (at m=0,
            // where screenSize == src.Size and screenCorner == SourceCornerRadius) and the full
            // fitted media rect (at m=1, where screenSize == Media.Size * s and corner == FullCornerRadius).
            var srcLocalW = src.Width / Scale0;
            var srcLocalH = src.Height / Scale0;
            var clipW = Math.Max(0, ViewerMath.Lerp(srcLocalW, Media.Width, m));
            var clipH = Math.Max(0, ViewerMath.Lerp(srcLocalH, Media.Height, m));
            var clipX = mediaCx - clipW * 0.5;
            var clipY = mediaCy - clipH * 0.5;
            var screenRadius = ViewerMath.Lerp(SourceCornerRadius, FullCornerRadius, m);
            var localRadius = Math.Max(0, screenRadius / s);

            var surfaceOpacity = 1.0;
            if (Closing && m < ViewerMath.ReverseDissolveTail)
                surfaceOpacity = Math.Clamp(m / ViewerMath.ReverseDissolveTail, 0.0, 1.0);

            return new TransitionFrame(s, offsetX, offsetY, clipX, clipY, clipW, clipH, localRadius, surfaceOpacity, backdrop, chrome, UseClip: true);
        }
        else
        {
            // Fallback when source is off-screen or reduced motion: fade + gentle scale around media.
            var clipW = Math.Max(0, Media.Width);
            var clipH = Math.Max(0, Media.Height);
            var clipX = mediaCx - clipW * 0.5;
            var clipY = mediaCy - clipH * 0.5;
            var localRadius = Math.Max(0, FullCornerRadius / s);
            return new TransitionFrame(s, offsetX, offsetY, clipX, clipY, clipW, clipH, localRadius, m, backdrop, chrome, UseClip: true);
        }
    }
}

public static class ViewerMath
{
    public const double PageGap = 40.0;
    public const double UnhideThreshold = 0.14;
    public const double ReverseDissolveTail = 0.10;
    public const double MaxDismissCornerRadius = 22.0;

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

    public static double EaseInQuad(double t)
    {
        t = Math.Clamp(t, 0.0, 1.0);
        return t * t;
    }

    public static double Lerp(double a, double b, double t) => a + (b - a) * t;

    /// Evaluates the visual frame while the viewer is at rest or being interactively dragged to dismiss.
    /// During drag, strictly clips to the current media rect with smoothly rounded corners so adjacent
    /// strip pages (p0 / p2) are NEVER visible and P1 detaches as a sleek floating rounded card.
    public static TransitionFrame EvaluateRestOrDismiss(Rect bounds, Rect media, DismissState dismiss)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
            return new TransitionFrame(1, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, UseClip: false);

        if (!dismiss.IsActive)
            return new TransitionFrame(1, 0, 0, 0, 0, bounds.Width, bounds.Height, 0, 1, 1, 1, UseClip: true);

        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;
        var s = Math.Max(dismiss.Scale, 1e-4);
        var offsetX = dismiss.CenterX - mediaCx * s;
        var offsetY = dismiss.CenterY - mediaCy * s;

        var backdrop = Math.Pow(Math.Clamp(1.0 - dismiss.Progress, 0.0, 1.0), 1.35);
        var chrome = Math.Clamp(1.0 - dismiss.Progress * 4.5, 0.0, 1.0);
        var localRadius = Math.Max(0, dismiss.CornerRadius / s);

        return new TransitionFrame(
            s, offsetX, offsetY,
            media.X, media.Y, Math.Max(0, media.Width), Math.Max(0, media.Height),
            localRadius,
            SurfaceOpacity: 1.0,
            BackdropOpacity: backdrop,
            ChromeOpacity: chrome,
            UseClip: true);
    }

    // ---- Interactive drag-to-dismiss (WWDC24 10145 grab-anchored floating card feel) ----

    public static double EdgeZoneWidth(double viewportWidth) => Math.Clamp(viewportWidth * 0.10, 32.0, 48.0);

    /// Evaluates interactive dismiss drag anchored around `grabPoint` so the spot on the photo
    /// under the pointer/finger stays attached while the photo shrinks into a rounded floating card.
    public static DismissState EvaluateDismiss(
        Rect media,
        Point grabPoint,
        double rawDx,
        double rawDy,
        double viewportW,
        double viewportH,
        bool fromEdge,
        int edgeDir)
    {
        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;

        double visualDx, visualDy, distance, extent;
        if (fromEdge)
        {
            var inward = rawDx * edgeDir;
            visualDx = inward < 0 ? rawDx * 0.28 : rawDx;
            visualDy = rawDy;
            distance = Math.Max(0.0, inward);
            extent = Math.Min(viewportW * 0.48, 240.0);
        }
        else
        {
            visualDx = rawDx;
            visualDy = rawDy < 0 ? rawDy * 0.28 : rawDy;
            distance = Math.Max(0.0, rawDy);
            extent = Math.Min(viewportH * 0.42, 300.0);
        }

        var progress = extent <= 0 ? 0.0 : Math.Clamp(distance / extent, 0.0, 1.0);
        // Smooth concave shrink curve: feels immediately responsive as soon as you pull down,
        // shrinking from 1.0 down to 0.56 without a harsh linear stop.
        var expNorm = (1.0 - Math.Exp(-2.2 * progress)) / (1.0 - Math.Exp(-2.2));
        var scale = 1.0 - 0.44 * expNorm;

        // Keep the grabbed point on the photo tracking under the pointer as scale decreases.
        var relX = Math.Clamp(grabPoint.X - mediaCx, -media.Width * 0.5, media.Width * 0.5);
        var relY = Math.Clamp(grabPoint.Y - mediaCy, -media.Height * 0.5, media.Height * 0.5);
        var centerX = mediaCx + visualDx + relX * (1.0 - scale);
        var centerY = mediaCy + visualDy + relY * (1.0 - scale);

        var cornerRadius = MaxDismissCornerRadius * EaseOutCubic(Math.Clamp(progress * 1.5, 0.0, 1.0));
        return new DismissState(centerX, centerY, scale, cornerRadius, progress);
    }

    public static bool ShouldCommitDismiss(double rawDx, double rawDy, double vx, double vy, double viewportW, double viewportH, bool fromEdge, int edgeDir)
    {
        if (fromEdge)
        {
            var inward = rawDx * edgeDir;
            var vin = vx * edgeDir;
            var threshold = Math.Min(viewportW * 0.16, 90.0);
            return vin >= -250.0 && (inward > threshold || (vin > 300.0 && inward > 8.0));
        }
        else
        {
            var threshold = Math.Min(viewportH * 0.12, 84.0);
            return vy >= -250.0 && (rawDy > threshold || (vy > 280.0 && rawDy > 8.0));
        }
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

    // ---- Photo zoom & pan clamping (matching Web PhotoPage.tsx) ----

    public const double MinPhotoZoom = 1.0;
    public const double MaxPhotoZoom = 8.0;
    public const double DoubleClickZoom = 2.5;

    public static PhotoView ClampPhotoView(PhotoView v, double baseW, double baseH, double viewW, double viewH)
    {
        var s = Math.Clamp(v.Scale, MinPhotoZoom, MaxPhotoZoom);
        if (s <= 1.0001) return PhotoView.Identity;
        var mx = Math.Max(0.0, (baseW * s - viewW) * 0.5);
        var my = Math.Max(0.0, (baseH * s - viewH) * 0.5);
        return new PhotoView(s, Math.Clamp(v.X, -mx, mx), Math.Clamp(v.Y, -my, my));
    }

    public static PhotoView ZoomPhotoAt(PhotoView current, double targetScale, double px, double py, double baseW, double baseH, double viewW, double viewH)
    {
        var ns = Math.Clamp(targetScale, MinPhotoZoom, MaxPhotoZoom);
        var cx = px - viewW * 0.5;
        var cy = py - viewH * 0.5;
        var k = ns / Math.Max(current.Scale, 1e-4);
        return ClampPhotoView(new PhotoView(ns, cx - (cx - current.X) * k, cy - (cy - current.Y) * k), baseW, baseH, viewW, viewH);
    }

    public static Rect PhotoMediaFrame(double viewW, double viewH, double baseW, double baseH, PhotoView v)
    {
        var w = baseW * v.Scale;
        var h = baseH * v.Scale;
        var rect = new Rect((viewW - w) * 0.5 + v.X, (viewH - h) * 0.5 + v.Y, w, h);
        return Intersect(rect, new Rect(0, 0, viewW, viewH));
    }
}
