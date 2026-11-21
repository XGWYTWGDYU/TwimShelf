// Geometry and the constants measured from Photos (same engine as Apple/Shared/Grid/GridConfig.swift
// and web/app/src/pages/grid/zoom.ts).
using TwimShelf.Core;

namespace TwimShelf.Controls.ZoomGrid;

public struct GridConfig
{
    public double Width;
    public double Height;
    public double Scale;
    public double InsetTop;
    public double InsetBottom;
    public int Count;
    public int[] Columns;
    /// Exact width share (1) or whole pixels (0). Always 1 on desktop so resizing keeps tiles flush.
    public double Exactness;

    public GridConfig(double width, double height, double scale, double insetTop, double insetBottom, int count = 0)
    {
        Width = width;
        Height = height;
        Scale = Math.Max(scale, 1.0);
        InsetTop = insetTop;
        InsetBottom = insetBottom;
        Count = count;
        Columns = [5, 3, 1];
        Exactness = 0.0;
    }

    // Measured Photos constants
    public const double GapPixelsAt3x = 5.0;
    public const double CornerRadius = 2.5;
    /// Direction-latched layer switch thresholds, as log-fractions between adjacent rest sides.
    public static readonly double[] UpFraction = [0.118, 0.423];
    public static readonly double[] DownFraction = [0.931, 0.893];
    /// Cross-fade progress rate: base + gain * |d ln(side)/dt| per second; layer alpha = progress^2.
    public const double FadeBase = 1.0;
    public const double FadeGain = 0.9;
    /// Rubber band below the densest level's side (log space).
    public const double RubberC = 0.467;
    public const double RubberDepth = 0.0566;
    /// Hard limit above the sparsest level's side.
    public const double MaxSideFactor = 1.2214;
    /// Critically damped settle spring on ln(raw side).
    public const double SpringOmega = 12.0;
    /// How far a release velocity is projected when deciding the final layer.
    public const double ReleaseProjection = 0.08;

    static double _cachedWindowWidth = double.NaN;
    static int[]? _cachedWindowColumns;

    /// Chosen once per window width so opening/closing the sidebar resizes tiles smoothly in place
    /// without moving photos to other rows or columns.
    public static int[] ColumnsForWidth(double w, double? windowWidth = null)
    {
        if (windowWidth is { } ww)
        {
            if (_cachedWindowColumns != null && Math.Abs(_cachedWindowWidth - ww) < 0.5)
                return _cachedWindowColumns;
            var cols = ColumnsForWidth(w);
            _cachedWindowWidth = ww;
            _cachedWindowColumns = cols;
            return cols;
        }
        return ColumnsForWidth(w);
    }

    public static int[] ColumnsForWidth(double w)
    {
        if (w <= 500) return [5, 3, 1];
        var one = Math.Max(1, (int)Math.Round(w / 402.0, MidpointRounding.AwayFromZero));
        var three = Math.Max(one + 1, (int)Math.Round(w / 134.0, MidpointRounding.AwayFromZero));
        var five = Math.Max(three + 1, (int)Math.Round(w / 80.4, MidpointRounding.AwayFromZero));
        return [five, three, one];
    }

    public readonly double Gap => Math.Max(1.0, Math.Round(GapPixelsAt3x * Scale / 3.0, MidpointRounding.AwayFromZero)) / Scale;
    public readonly int Levels => Columns.Length;

    public readonly double Side(int level)
    {
        var n = (double)Columns[level];
        var exact = (Width - Gap * (n - 1)) / n;
        var whole = Math.Floor(exact * Scale) / Scale;
        return Math.Max(whole + (exact - whole) * Exactness, 1.0);
    }

    public readonly double Pitch(int level) => Side(level) + Gap;

    public readonly double Up(int level) => Side(level) * Math.Pow(Side(level + 1) / Side(level), UpFraction[level]);
    public readonly double Down(int level) => Side(level) * Math.Pow(Side(level + 1) / Side(level), DownFraction[level]);

    public readonly double MinSide => Side(0);
    public readonly double MaxSide => Side(Levels - 1) * MaxSideFactor;

    public readonly int Rows(int level, int phase)
    {
        var n = Columns[level];
        return (Count + phase + n - 1) / n;
    }

    public readonly double ContentHeight(int level, int phase) =>
        Count == 0 ? 0.0 : Rows(level, phase) * Pitch(level) - Gap;

    public readonly double MaxOffset(int level, int phase) =>
        Math.Max(0.0, ContentHeight(level, phase) + InsetTop + InsetBottom - Height);

    public readonly int BottomPhase(int level)
    {
        var n = Columns[level];
        return (n - Count % n) % n;
    }

    public readonly (int Col, int Row) Cell(int index, int level, int phase)
    {
        var n = Columns[level];
        var k = index + phase;
        return (k % n, k / n);
    }

    public readonly double DisplaySide(double lnRaw)
    {
        var raw = Math.Exp(lnRaw);
        if (raw < MinSide)
        {
            var u = Math.Log(MinSide / raw);
            const double d = RubberDepth;
            return MinSide * Math.Exp(-d * (1.0 - 1.0 / (RubberC * u / d + 1.0)));
        }
        return Math.Min(raw, MaxSide);
    }

    public readonly bool GeometryEquals(in GridConfig other) =>
        Math.Abs(Width - other.Width) < 0.01 &&
        Math.Abs(Height - other.Height) < 0.01 &&
        Math.Abs(Scale - other.Scale) < 0.001 &&
        Math.Abs(InsetTop - other.InsetTop) < 0.01 &&
        Math.Abs(InsetBottom - other.InsetBottom) < 0.01 &&
        Math.Abs(Exactness - other.Exactness) < 0.001 &&
        SameColumns(Columns, other.Columns);

    public static bool SameColumns(int[] a, int[] b)
    {
        if (a.Length != b.Length) return false;
        for (var i = 0; i < a.Length; i++) if (a[i] != b[i]) return false;
        return true;
    }
}

public struct RestState(int level, int phase, double offset)
{
    public int Level = level;
    public int Phase = phase;
    public double Offset = offset;
}

public struct GridTile
{
    public double X;
    public double Y;
    public double Side;
    public double Alpha;
    public int Index;
    public int Photo;
    public float R0, R1, R2, R3; // tl, tr, br, bl
}

public sealed record ZoomGridTile(FeedItem Item, int Count);

internal static class GridMath
{
    public static int PosMod(int a, int n) => ((a % n) + n) % n;
    public static double Clamp(double x, double lo, double hi) => x < lo ? lo : x > hi ? hi : x;

    public static double CubicBezier(double x1, double y1, double x2, double y2, double t)
    {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        double lo = 0, hi = 1;
        for (var i = 0; i < 30; i++)
        {
            var mid = (lo + hi) * 0.5;
            var u = 1 - mid;
            var bx = 3 * u * u * mid * x1 + 3 * u * mid * mid * x2 + mid * mid * mid;
            if (bx < t) lo = mid; else hi = mid;
        }
        var s = (lo + hi) * 0.5;
        var v = 1 - s;
        return 3 * v * v * s * y1 + 3 * v * s * s * y2 + s * s * s;
    }
}
