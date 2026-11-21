// The Photos pinch-zoom state machine (same engine as Apple/Shared/Grid/ZoomEngine.swift).
using Windows.Foundation;

namespace TwimShelf.Controls.ZoomGrid;

public sealed class ZoomEngine
{
    public GridConfig Cfg;
    public RestState Rest;
    public ZoomState? Zoom { get; private set; }
    int[] _items = [];
    public int[] Items
    {
        get => _items;
        set { _items = value; Cfg.Count = value.Length; }
    }
    public int? HiddenPhoto;
    public bool IsZooming => Zoom != null;

    public sealed class ZoomState
    {
        public int Anchor;
        public Point Rel;
        public int[] Cols = [];
        public int[] Anchors = [];
        public int[] Phases = [];
        public Point Finger;
        public Point FingerOffset;
        public double LnBase;
        public double LnRaw;
        public double LnVel;
        public double Level;
        public int Target;
        public bool Pinching = true;
        public double PrevLnRaw;
        public double PrevLnSide;
        public double SideRate;
        public double LastTime;
    }

    public ZoomEngine(GridConfig cfg, RestState rest)
    {
        Cfg = cfg;
        Rest = rest;
        _items = new int[cfg.Count];
        for (var i = 0; i < cfg.Count; i++) _items[i] = i;
    }

    // ---- Gesture ----

    public void BeginPinch(Point finger, double time)
    {
        if (Zoom is { } z)
        {
            z.FingerOffset = new Point(z.Finger.X - finger.X, z.Finger.Y - finger.Y);
            z.LnBase = z.LnRaw;
            z.LnVel = 0;
            z.Pinching = true;
            z.LastTime = time;
            return;
        }
        var lv = Rest.Level;
        var n = Cfg.Columns[lv];
        var side = Cfg.Side(lv);
        var pitch = Cfg.Pitch(lv);
        var cy = finger.Y - Cfg.InsetTop + Rest.Offset;
        var col = Math.Clamp((int)Math.Floor(finger.X / pitch), 0, n - 1);
        var row = Math.Max(0, (int)Math.Floor(cy / pitch));
        var index = Math.Clamp(row * n + col - Rest.Phase, 0, Math.Max(Cfg.Count - 1, 0));
        var (ccol, crow) = Cfg.Cell(index, lv, Rest.Phase);
        var rel = new Point((finger.X - ccol * pitch) / side, (cy - crow * pitch) / side);

        var cols = new int[Cfg.Levels];
        var phases = new int[Cfg.Levels];
        var anchors = new int[Cfg.Levels];
        Array.Fill(anchors, index);
        for (var l = 0; l < Cfg.Levels; l++)
        {
            if (l == lv) continue;
            (cols[l], phases[l], anchors[l]) = ChooseColumn(l, index, rel, finger);
        }
        cols[lv] = ccol;
        phases[lv] = Rest.Phase;
        var ln0 = Math.Log(side);
        Zoom = new ZoomState
        {
            Anchor = index,
            Rel = rel,
            Cols = cols,
            Anchors = anchors,
            Phases = phases,
            Finger = finger,
            FingerOffset = new Point(0, 0),
            LnBase = ln0,
            LnRaw = ln0,
            Level = lv,
            Target = lv,
            Pinching = true,
            PrevLnRaw = ln0,
            PrevLnSide = ln0,
            LastTime = time,
        };
    }

    public void PinchChanged(double scale, Point finger)
    {
        if (Zoom is not { Pinching: true } z) return;
        z.Finger = new Point(finger.X + z.FingerOffset.X, finger.Y + z.FingerOffset.Y);
        z.LnRaw = z.LnBase + Math.Log(Math.Max(scale, 1e-3));
    }

    public void Release(double velocity, double scale)
    {
        if (Zoom is not { } z) return;
        var v = GridMath.Clamp(velocity / Math.Max(scale, 1e-3), -8.0, 8.0);
        var projected = Cfg.DisplaySide(z.LnRaw + v * GridConfig.ReleaseProjection);
        z.Target = Latch(z.Target, projected, v);
        z.Pinching = false;
        z.LnVel = v;
    }

    // ---- Per frame ----

    public RestState? Tick(double time)
    {
        if (Zoom is not { } z) return null;
        var dt = GridMath.Clamp(time - z.LastTime, 0.0, 1.0 / 30.0);
        z.LastTime = time;

        if (!z.Pinching)
        {
            var goal = Math.Log(Cfg.Side(z.Target));
            const double w = GridConfig.SpringOmega;
            var t = dt;
            while (t > 1e-6)
            {
                var h = Math.Min(t, 1.0 / 480.0);
                var a = -w * w * (z.LnRaw - goal) - 2.0 * w * z.LnVel;
                z.LnVel += a * h;
                z.LnRaw += z.LnVel * h;
                t -= h;
            }
        }

        var s = Cfg.DisplaySide(z.LnRaw);
        var lnS = Math.Log(s);
        if (dt > 0)
        {
            var inst = Math.Abs(lnS - z.PrevLnSide) / dt;
            z.SideRate += (inst - z.SideRate) * Math.Min(1.0, dt * 30.0);
        }
        if (z.Pinching)
            z.Target = Latch(z.Target, s, z.LnRaw - z.PrevLnRaw);
        z.PrevLnRaw = z.LnRaw;
        z.PrevLnSide = lnS;

        var rate = GridConfig.FadeBase + GridConfig.FadeGain * z.SideRate;
        var diff = z.Target - z.Level;
        z.Level += (diff > 0 ? 1.0 : -1.0) * Math.Min(Math.Abs(diff), rate * dt);

        var remaining = Math.Abs(z.LnRaw - Math.Log(Cfg.Side(z.Target))) * Cfg.Side(z.Target);
        if (!z.Pinching && remaining < 0.33 / Cfg.Scale && Math.Abs(z.LnVel) < 0.02 && Math.Abs(z.Level - z.Target) < 0.02)
            return Finish();
        return null;
    }

    public RestState? FinishNow()
    {
        if (Zoom is not { Pinching: false } z) return null;
        z.LnRaw = Math.Log(Cfg.Side(z.Target));
        z.LnVel = 0;
        z.Level = z.Target;
        return Finish();
    }

    int Latch(int target, double s, double direction)
    {
        var t = target;
        if (direction > 0)
        {
            while (t < Cfg.Levels - 1 && s > Cfg.Up(t)) t++;
        }
        else if (direction < 0)
        {
            while (t > 0 && s < Cfg.Down(t - 1)) t--;
        }
        return t;
    }

    RestState? Finish()
    {
        if (Zoom is not { } z) return null;
        var l = z.Target;
        var r = RestAnchorPoint(l, z);
        var n = Cfg.Columns[l];
        var row = (z.Anchors[l] + z.Phases[l]) / n;
        var contentY = row * Cfg.Pitch(l) + z.Rel.Y * Cfg.Side(l);
        var offset = GridMath.Clamp(Cfg.InsetTop + contentY - r.Y, 0.0, Cfg.MaxOffset(l, z.Phases[l]));
        Rest = new RestState(l, z.Phases[l], offset);
        Zoom = null;
        return Rest;
    }

    // ---- Anchor geometry ----

    (int Col, int Phase, int Photo) ChooseColumn(int l, int anchor, Point rel, Point finger)
    {
        var n = Cfg.Columns[l];
        var side = Cfg.Side(l);
        var pitch = Cfg.Pitch(l);
        var col = Math.Clamp((int)Math.Round((finger.X - rel.X * side) / pitch, MidpointRounding.AwayFromZero), 0, n - 1);
        var phase = GridMath.PosMod(col - anchor, n);
        var row = (anchor + phase) / n;
        var o = GridMath.Clamp(Cfg.InsetTop + row * pitch + rel.Y * side - finger.Y, 0.0, Cfg.MaxOffset(l, phase));
        if (o < Cfg.InsetTop + side)
        {
            var photo = Math.Min((anchor / n) * n + col, Math.Max(Cfg.Count - 1, 0));
            return (photo % n, 0, photo);
        }
        return (col, phase, anchor);
    }

    Point RestAnchorPoint(int l, ZoomState z)
    {
        var n = Cfg.Columns[l];
        var side = Cfg.Side(l);
        var pitch = Cfg.Pitch(l);
        var row = (z.Anchors[l] + z.Phases[l]) / n;
        var x = z.Cols[l] * pitch + z.Rel.X * side;
        var contentY = row * pitch + z.Rel.Y * side;
        var o = GridMath.Clamp(Cfg.InsetTop + contentY - z.Finger.Y, 0.0, Cfg.MaxOffset(l, z.Phases[l]));
        return new Point(x, Cfg.InsetTop + contentY - o);
    }

    Point AnchorPoint(double s, ZoomState z)
    {
        if (s <= Cfg.Side(0)) return RestAnchorPoint(0, z);
        for (var l = 0; l < Cfg.Levels - 1; l++)
        {
            if (s <= Cfg.Side(l + 1))
            {
                var a = RestAnchorPoint(l, z);
                var b = RestAnchorPoint(l + 1, z);
                var t = (s - Cfg.Side(l)) / (Cfg.Side(l + 1) - Cfg.Side(l));
                return new Point(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
            }
        }
        return RestAnchorPoint(Cfg.Levels - 1, z);
    }

    // ---- Frame ----

    public readonly record struct FrameInfo(double Side, double Level, int Target, int Columns);

    public FrameInfo Info()
    {
        if (Zoom is { } z)
            return new FrameInfo(Cfg.DisplaySide(z.LnRaw), z.Level, z.Target, Cfg.Columns[(int)Math.Round(z.Level, MidpointRounding.AwayFromZero)]);
        return new FrameInfo(Cfg.Side(Rest.Level), Rest.Level, Rest.Level, Cfg.Columns[Rest.Level]);
    }

    readonly double[] _alphaBuf = new double[8];

    public void ZoomTiles(List<GridTile> output)
    {
        if (Zoom is not { } z) return;
        var s = Cfg.DisplaySide(z.LnRaw);
        var p = s + Cfg.Gap;
        var anchorPt = AnchorPoint(s, z);
        var ax = anchorPt.X - z.Rel.X * s;
        var ay = anchorPt.Y - z.Rel.Y * s;

        var levels = Cfg.Levels;
        _alphaBuf[0] = 1.0;
        for (var j = 1; j < levels; j++)
        {
            var v = GridMath.Clamp(z.Level - (j - 1), 0.0, 1.0);
            _alphaBuf[j] = v * v;
        }
        var drMin = (int)Math.Floor(-ay / p);
        var drMax = (int)Math.Floor((Cfg.Height - ay) / p);
        var dcScreenMin = (int)Math.Floor(-ax / p);
        var dcScreenMax = (int)Math.Floor((Cfg.Width - ax) / p);

        for (var l = 0; l < levels; l++)
        {
            if (l > 0 && _alphaBuf[l] <= 0.001) continue;
            var n = Cfg.Columns[l];
            var c = z.Cols[l];
            var lo = Math.Max(-c, dcScreenMin);
            var hi = Math.Min(n - 1 - c, dcScreenMax);
            if (lo > hi) continue;

            // Precompute vertical bounds of the active opaque base layer below `l` so sparser
            // layers (including layer 2 fading out past layer 1) never poke ghost rows above
            // photo #0 or below the last row.
            var below = -1;
            if (l > 0)
            {
                below = 0;
                for (var m = 1; m < l; m++)
                    if (s >= Cfg.Side(m) && _alphaBuf[m] >= 0.999) below = m;
            }
            var cBelow = below >= 0 ? z.Cols[below] : 0;
            var nBelow = below >= 0 ? Cfg.Columns[below] : 0;
            var topBelow = below >= 0 ? -((z.Anchors[below] + z.Phases[below]) / nBelow) : int.MinValue;
            var botBelow = below >= 0 ? (Cfg.Rows(below, z.Phases[below]) - 1) - ((z.Anchors[below] + z.Phases[below]) / nBelow) : int.MaxValue;
            double outsideAlpha = _alphaBuf[l];
            if (below >= 0)
            {
                var s0 = Cfg.Side(below);
                var s1 = Cfg.Side(below + 1);
                var sideFrac = s1 > s0 ? GridMath.Clamp((s - s0) / (s1 - s0), 0.0, 1.0) : 1.0;
                var k = Math.Min(_alphaBuf[l], sideFrac);
                var edge = GridMath.Clamp((k - 0.80) / 0.20, 0.0, 1.0);
                outsideAlpha = edge * edge;
            }

            for (var dr = drMin; dr <= drMax; dr++)
            {
                for (var dc = lo; dc <= hi; dc++)
                {
                    var occluded = false;
                    for (var m = l + 1; m < levels; m++)
                    {
                        if (_alphaBuf[m] < 0.999) continue;
                        var cm = z.Cols[m];
                        var nm = Cfg.Columns[m];
                        var im = z.Anchors[m] + dr * nm + dc;
                        if (dc >= -cm && dc <= nm - 1 - cm && im >= 0 && im < Cfg.Count)
                        {
                            occluded = true;
                            break;
                        }
                    }
                    if (occluded) continue;
                    var idx = z.Anchors[l] + dr * n + dc;
                    if (idx < 0 || idx >= Cfg.Count) continue;
                    var photo = _items[idx];
                    if (photo == HiddenPhoto) continue;

                    var tileAlpha = _alphaBuf[l];
                    if (below >= 0)
                    {
                        var idxBelow = z.Anchors[below] + dr * nBelow + dc;
                        var outsideVertical = dr < topBelow || dr > botBelow ||
                            (dc >= -cBelow && dc <= nBelow - 1 - cBelow && (idxBelow < 0 || idxBelow >= Cfg.Count));
                        if (outsideVertical)
                        {
                            tileAlpha = outsideAlpha;
                            if (tileAlpha <= 0.001) continue;
                        }
                    }

                    var x = ax + dc * p;
                    var y = ay + dr * p;
                    var (r0, r1, r2, r3) = Radii(x, s, dc == -c, dc == n - 1 - c);
                    output.Add(new GridTile
                    {
                        X = x, Y = y, Side = s, Alpha = tileAlpha,
                        Index = idx, Photo = photo,
                        R0 = r0, R1 = r1, R2 = r2, R3 = r3,
                    });
                }
            }
        }
    }

    public void RestTiles(RestState r, List<GridTile> output, double alpha = 1.0)
    {
        var l = r.Level;
        var n = Cfg.Columns[l];
        var s = Cfg.Side(l);
        var p = Cfg.Pitch(l);
        var rowMin = Math.Max(0, (int)Math.Floor((r.Offset - Cfg.InsetTop) / p));
        var rowMax = (int)Math.Floor((r.Offset - Cfg.InsetTop + Cfg.Height) / p);
        if (rowMin > rowMax) return;
        for (var row = rowMin; row <= rowMax; row++)
        {
            for (var col = 0; col < n; col++)
            {
                var idx = row * n + col - r.Phase;
                if (idx < 0 || idx >= Cfg.Count) continue;
                var photo = _items[idx];
                if (photo == HiddenPhoto) continue;
                var x = col * p;
                var y = Cfg.InsetTop + row * p - r.Offset;
                var (r0, r1, r2, r3) = Radii(x, s, col == 0, col == n - 1);
                output.Add(new GridTile
                {
                    X = x, Y = y, Side = s, Alpha = alpha,
                    Index = idx, Photo = photo,
                    R0 = r0, R1 = r1, R2 = r2, R3 = r3,
                });
            }
        }
    }

    public Rect RestFrame(int index, RestState r)
    {
        var (col, row) = Cfg.Cell(index, r.Level, r.Phase);
        var p = Cfg.Pitch(r.Level);
        var s = Cfg.Side(r.Level);
        return new Rect(col * p, Cfg.InsetTop + row * p - r.Offset, s, s);
    }

    public int? RestIndex(Point pt)
    {
        var l = Rest.Level;
        var n = Cfg.Columns[l];
        var p = Cfg.Pitch(l);
        var side = Cfg.Side(l);
        var cy = pt.Y - Cfg.InsetTop + Rest.Offset;
        if (pt.X < 0 || cy < 0) return null;
        var col = (int)(pt.X / p);
        var row = (int)(cy / p);
        if (col >= n || pt.X - col * p > side || cy - row * p > side) return null;
        var i = row * n + col - Rest.Phase;
        return i >= 0 && i < Cfg.Count ? i : null;
    }

    public (float, float, float, float) Radii(double x, double side, bool leftEdge, bool rightEdge)
    {
        const double r = GridConfig.CornerRadius;
        var left = (float)(leftEdge ? r * GridMath.Clamp(x / r, 0.0, 1.0) : r);
        var right = (float)(rightEdge ? r * GridMath.Clamp((Cfg.Width - x - side) / r, 0.0, 1.0) : r);
        return (left, right, right, left);
    }
}
