// Automated test suite for the Windows ZoomGrid engine (GridConfig, ZoomEngine, GridScene):
//  1. Replays all 9 Apple Photos ground-truth recordings (Apple/GridTests/Fixtures/*.json)
//  2. Enforces all FingerTests invariants (photo under finger, vertical anchor lock, round-trip,
//     full first row, repeated zooms near top, mid-settle regrab) on both phone and desktop sizes
//  3. Regression tests for ghost rows above top / below bottom during rapid zoom in-out,
//     surrounding neighbor lattice geometry, sidebar resize lock, and 5,000-photo CPU performance.
using System.Diagnostics;
using System.Text.Json;
using TwimShelf.Controls.ViewerEngine;
using TwimShelf.Controls.ZoomGrid;
using Windows.Foundation;

namespace TwimShelf.GridTests;

static class Program
{
    static int _passed, _failed;

    static int Main(string[] args)
    {
        var fixturesDir = args.Length > 0 ? args[0] : FindFixturesDir();
        Console.WriteLine($"TwimShelf Windows ZoomGrid Tests (fixtures: {fixturesDir ?? "not found"})");
        Console.WriteLine();

        // 1. Photos ground-truth replay tests (matching Apple/GridTests/PhotosReplayTests.swift)
        if (fixturesDir != null)
        {
            var names = new[]
            {
                "A_zoomout_slow", "B_mid_in_out", "D_steps", "F1_slow_up_release",
                "G1_from1_to300_release", "H_from3_up_down", "I_offcenter_x110",
                "J_x95_3to5", "TOP_photos",
            };
            foreach (var name in names)
                Run($"PhotosReplay.{name}", () => PhotosReplay.Check(fixturesDir, name));
        }
        else
        {
            Fail("PhotosReplay.FixturesPresent", "Apple/GridTests/Fixtures directory not found");
        }

        // 2. FingerTests invariants (matching Apple/GridTests/FingerTests.swift)
        Run("Finger.PhotoUnderFingerStaysWherePhotosKeepsIt", FingerTests.PhotoUnderFingerStaysWherePhotosKeepsIt);
        Run("Finger.ThreeAndOneColumnsAlwaysKeepThePhoto", FingerTests.ThreeAndOneColumnsAlwaysKeepThePhoto);
        Run("Finger.AnchorFollowsFingerVertically", FingerTests.AnchorFollowsFingerVertically);
        Run("Finger.RoundTripRestoresLayout", FingerTests.RoundTripRestoresLayout);
        Run("Finger.NoPartialFirstRowAfterAnyZoom", FingerTests.NoPartialFirstRowAfterAnyZoom);
        Run("Finger.RepeatedZoomsNearTop", FingerTests.RepeatedZoomsNearTop);
        Run("Finger.RegrabDuringSettle", FingerTests.RegrabDuringSettle);

        // 3. Windows desktop invariants, ghost-row regression, neighbor geometry, sidebar resize, perf
        Run("Windows.NoGhostRowAboveTopOrBelowBottom", WindowsGridTests.NoGhostRowAboveTopOrBelowBottom);
        Run("Windows.DesktopPhotoUnderFingerAndNeighbors", WindowsGridTests.DesktopPhotoUnderFingerAndNeighbors);
        Run("Windows.ChainedStepReversalNearTop", WindowsGridTests.ChainedStepReversalNearTop);
        Run("Windows.SidebarResizeKeepsColumnsAndRow", WindowsGridTests.SidebarResizeKeepsColumnsAndRow);
        Run("Windows.Performance5000Tiles", WindowsGridTests.Performance5000Tiles);

        // 4. Unified Viewer zoom transition, horizontal strip paging, dismiss drag, photo zoom & hidden-tile sync
        Run("Viewer.ZoomTransitionPixelExactBounds", ViewerTests.ZoomTransitionPixelExactBounds);
        Run("Viewer.DismissDragAndCloseFlightContinuity", ViewerTests.DismissDragAndCloseFlightContinuity);
        Run("Viewer.StripPagingSwipeSettleAndCaptionFade", ViewerTests.StripPagingSwipeSettleAndCaptionFade);
        Run("Viewer.PhotoCursorAnchoredZoomAndClamp", ViewerTests.PhotoCursorAnchoredZoomAndClamp);
        Run("Viewer.GridHiddenPhotoAndSourceFrameSync", ViewerTests.GridHiddenPhotoAndSourceFrameSync);

        Console.WriteLine();
        Console.WriteLine($"Result: {_passed} passed, {_failed} failed.");
        return _failed == 0 ? 0 : 1;
    }

    static string? FindFixturesDir()
    {
        var dir = AppContext.BaseDirectory;
        for (var i = 0; i < 8 && dir != null; i++)
        {
            var candidate = Path.Combine(dir, "Apple", "GridTests", "Fixtures");
            if (Directory.Exists(candidate)) return candidate;
            dir = Path.GetDirectoryName(dir.TrimEnd(Path.DirectorySeparatorChar));
        }
        return null;
    }

    static void Run(string name, Action test)
    {
        var sw = Stopwatch.StartNew();
        try
        {
            test();
            _passed++;
            Console.WriteLine($"  [PASS] {name} ({sw.ElapsedMilliseconds} ms)");
        }
        catch (Exception ex)
        {
            Fail(name, ex.Message);
        }
    }

    static void Fail(string name, string message)
    {
        _failed++;
        Console.Error.WriteLine($"  [FAIL] {name}: {message}");
    }
}

static class Assert
{
    public static void True(bool cond, string msg) { if (!cond) throw new Exception(msg); }
    public static void Equal<T>(T actual, T expected, string msg = "") where T : IEquatable<T>
    {
        if (!actual.Equals(expected))
            throw new Exception($"{msg} (expected {expected}, got {actual})");
    }
    public static void Close(double actual, double expected, double eps, string msg = "")
    {
        if (Math.Abs(actual - expected) > eps)
            throw new Exception($"{msg} (expected {expected:F3} ± {eps:F3}, got {actual:F3})");
    }
}

// ---- Photos ground-truth replay (port of Apple/GridTests/ReplayHarness.swift + PhotosReplayTests.swift) ----

static class PhotosReplay
{
    const double MedianLimit = 0.6;
    const double P95Limit = 2.0;
    const double P99Limit = 3.0;
    const double UnmatchedLimit = 0.03;
    const double GrossLimit = 0.002;

    sealed class FixtureData
    {
        public string Name { get; set; } = "";
        public int[] Items { get; set; } = [];
        public double[] Finger { get; set; } = [];
        public StartData Start { get; set; } = new();
        public List<FrameData> Frames { get; set; } = [];
    }
    sealed class StartData { public int Level { get; set; } public int Phase { get; set; } public double Offset { get; set; } }
    sealed class FrameData { public double T { get; set; } public double S { get; set; } public List<double[]> Tiles { get; set; } = []; }

    static GridConfig PhotosConfig(int count) => new(402, 874, 3, 136, 93, count);

    static double LnRaw(double displayedS, GridConfig cfg)
    {
        var m = cfg.MinSide;
        if (displayedS >= m) return Math.Log(displayedS);
        const double d = GridConfig.RubberDepth, c = GridConfig.RubberC;
        var q = Math.Min(-Math.Log(displayedS / m) / d, 0.999);
        return Math.Log(m) - d / c * (1.0 / (1.0 - q) - 1.0);
    }

    public static void Check(string dir, string name)
    {
        var path = Path.Combine(dir, name + ".json");
        Assert.True(File.Exists(path), $"missing fixture {path}");
        var f = JsonSerializer.Deserialize<FixtureData>(File.ReadAllText(path),
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })!;

        var cfg = PhotosConfig(f.Items.Length);
        var engine = new ZoomEngine(cfg, new RestState(f.Start.Level, f.Start.Phase, f.Start.Offset)) { Items = f.Items };
        var finger = new Point(f.Finger[0], f.Finger[1]);
        var tiles = new List<GridTile>();
        var errors = new List<double>();
        var unmatched = 0;
        double? restSince = null;
        var side0 = cfg.Side(f.Start.Level);

        bool IsRestSide(double s)
        {
            for (var l = 0; l < cfg.Levels; l++) if (Math.Abs(cfg.Side(l) - s) < 0.4) return true;
            return false;
        }

        foreach (var fr in f.Frames)
        {
            var atRestSide = IsRestSide(fr.S);
            if (engine.IsZooming)
            {
                if (atRestSide) restSince ??= fr.T; else restSince = null;
                if (restSince is { } r0 && fr.T - r0 >= 0.35 && engine.Zoom is { } z &&
                    Math.Abs(z.Level - z.Target) < 0.02 && Math.Abs(fr.S - cfg.Side(z.Target)) < 0.4)
                {
                    engine.Release(0, 1);
                    engine.FinishNow();
                    restSince = null;
                }
            }
            if (!engine.IsZooming)
            {
                if (Math.Abs(fr.S - cfg.Side(engine.Rest.Level)) < 0.4)
                {
                    tiles.Clear();
                    engine.RestTiles(engine.Rest, tiles);
                    Compare(fr, tiles, errors, ref unmatched);
                    continue;
                }
                engine.BeginPinch(finger, fr.T);
                side0 = cfg.Side(engine.Rest.Level);
            }
            engine.PinchChanged(Math.Exp(LnRaw(fr.S, cfg) - Math.Log(side0)), finger);
            engine.Tick(fr.T);
            tiles.Clear();
            engine.ZoomTiles(tiles);
            Compare(fr, tiles, errors, ref unmatched);
        }

        errors.Sort();
        double Pct(double p) => errors.Count == 0 ? 0 : errors[Math.Min(errors.Count - 1, (int)((errors.Count - 1) * p))];
        var unmatchedFrac = (double)unmatched / Math.Max(1, unmatched + errors.Count);
        var gross = (double)errors.Count(e => e > 10.0) / Math.Max(1, errors.Count);
        var summary = $"{name}: {errors.Count} tiles ({unmatched} unmatched), med={Pct(0.5):F2} p95={Pct(0.95):F2} p99={Pct(0.99):F2} max={(errors.Count > 0 ? errors[^1] : 0):F2}";
        Assert.True(errors.Count > 200, "too few tiles: " + summary);
        Assert.True(Pct(0.5) <= MedianLimit, "median exceeded: " + summary);
        Assert.True(Pct(0.95) <= P95Limit, "p95 exceeded: " + summary);
        Assert.True(Pct(0.99) <= P99Limit, "p99 exceeded: " + summary);
        Assert.True(unmatchedFrac <= UnmatchedLimit, $"unmatched {unmatchedFrac:P2}: " + summary);
        Assert.True(gross <= GrossLimit, $"gross {gross:P2}: " + summary);
    }

    static bool IsBlend(double[] o, List<GridTile> tiles)
    {
        var count = 0;
        var hasSemi = false;
        foreach (var t in tiles)
        {
            if (Math.Abs(t.X - o[1]) < 3 && Math.Abs(t.Y - o[2]) < 3)
            {
                count++;
                if (t.Alpha > 0.005 && t.Alpha < 0.995) hasSemi = true;
            }
        }
        return count >= 2 && hasSemi;
    }

    static void Compare(FrameData fr, List<GridTile> tiles, List<double> errors, ref int unmatched)
    {
        var byPhoto = new Dictionary<int, List<GridTile>>();
        foreach (var t in tiles)
        {
            if (t.Alpha <= 0.02) continue;
            if (!byPhoto.TryGetValue(t.Photo, out var list)) byPhoto[t.Photo] = list = [];
            list.Add(t);
        }
        foreach (var o in fr.Tiles)
        {
            var g = (int)o[0];
            if (!byPhoto.TryGetValue(g, out var cands)) { unmatched++; continue; }
            var bestErr = double.MaxValue;
            foreach (var c in cands)
            {
                var d = double.Hypot(c.X - o[1], c.Y - o[2]);
                if (d < bestErr) bestErr = d;
            }
            if (bestErr > 10 && IsBlend(o, tiles)) { unmatched++; continue; }
            errors.Add(bestErr);
        }
    }
}

// ---- FingerTests (port of Apple/GridTests/FingerTests.swift) ----

static class FingerTests
{
    public sealed record Script(string Name, (double Dur, double Target)[] Steps, double ReleaseVelocity = 0, Point Drift = default);
    public readonly record struct Frame(double Time, double Side, Point Finger, List<GridTile> Tiles);

    public static readonly Script[] Scripts =
    [
        new("in small", [(0.4, 1.3)]),
        new("in one step", [(0.5, 1.9)]),
        new("in two steps", [(0.8, 6.0)]),
        new("in to cap", [(0.8, 9.0)]),
        new("out small", [(0.4, 0.8)]),
        new("out one step", [(0.5, 0.55)]),
        new("out two steps", [(0.8, 0.18)]),
        new("out into rubber", [(0.8, 0.06)]),
        new("in-out", [(0.4, 2.2), (0.4, 1.0)]),
        new("out-in", [(0.4, 0.45), (0.4, 1.0)]),
        new("in-out-in", [(0.3, 2.5), (0.3, 0.6), (0.3, 1.8)]),
        new("hold then in", [(0.3, 1.0), (0.5, 2.4)]),
        new("fling in", [(0.15, 1.25)], ReleaseVelocity: 6),
        new("fling out", [(0.15, 0.85)], ReleaseVelocity: -6),
        new("slow in", [(2.5, 3.0)]),
        new("in with pan", [(0.6, 2.2)], Drift: new Point(0, 60)),
    ];

    public static RestState RunGesture(ZoomEngine engine, Point f0, Script script, Action<Frame> check, double start = 0)
    {
        const double dt = 1.0 / 120.0;
        var t = start;
        var finger = f0;
        engine.BeginPinch(finger, t);
        var tiles = new List<GridTile>();
        void Emit()
        {
            tiles.Clear();
            engine.ZoomTiles(tiles);
            check(new Frame(t, engine.Info().Side, finger, tiles));
        }

        var scale = 1.0;
        foreach (var (dur, target) in script.Steps)
        {
            var s0 = scale;
            var n = Math.Max(1, (int)(dur / dt));
            for (var k = 1; k <= n; k++)
            {
                t += dt;
                scale = s0 * Math.Pow(target / s0, (double)k / n);
                finger = new Point(finger.X + script.Drift.X * dt, finger.Y + script.Drift.Y * dt);
                engine.PinchChanged(scale, finger);
                if (engine.Tick(t) is { } r) return r;
                Emit();
            }
        }
        engine.Release(script.ReleaseVelocity, scale);
        for (var i = 0; i < 1200; i++)
        {
            t += dt;
            if (engine.Tick(t) is { } r) return r;
            Emit();
        }
        throw new Exception($"{script.Name}: zoom did not come to rest");
    }

    public static int? PhotoUnder(Point p, List<GridTile> tiles)
    {
        int? photo = null;
        foreach (var t in tiles)
            if (t.Alpha >= 0.5 && p.X >= t.X && p.X < t.X + t.Side && p.Y >= t.Y && p.Y < t.Y + t.Side)
                photo = t.Photo;
        return photo;
    }

    const int DefaultCount = 206;
    static GridConfig PhoneConfig(int count) => new(402, 874, 3, 136, 93, count);

    static ZoomEngine MakeEngine(int level, double offset, int count = DefaultCount)
    {
        var cfg = PhoneConfig(count);
        var phase = cfg.BottomPhase(level);
        var o = Math.Min(offset, cfg.MaxOffset(level, phase));
        if (o < cfg.InsetTop + cfg.Side(level)) { phase = 0; o = Math.Min(offset, cfg.MaxOffset(level, 0)); }
        var e = new ZoomEngine(cfg, new RestState(level, phase, Math.Max(0, o)));
        e.Items = Enumerable.Range(0, count).ToArray();
        return e;
    }

    static double[] Offsets(int level)
    {
        var cfg = PhoneConfig(DefaultCount);
        var m = cfg.MaxOffset(level, 0);
        return [0, 40, cfg.InsetTop + cfg.Side(level) + 1, 300, m * 0.5, m - 300, m - 30, m];
    }

    static readonly Point[] Fingers = BuildFingers();
    static Point[] BuildFingers()
    {
        var list = new List<Point>();
        for (double x = 8; x <= 394; x += 29)
            for (double y = 150; y <= 770; y += 88)
                list.Add(new Point(x, y));
        return [.. list];
    }

    public static RestState AppRealign(RestState r, GridConfig cfg) =>
        r.Phase != 0 && r.Offset < cfg.InsetTop + cfg.Side(r.Level)
            ? new RestState(r.Level, 0, Math.Min(r.Offset, cfg.MaxOffset(r.Level, 0)))
            : r;

    public static bool AnchorStays(ZoomEngine e, ZoomEngine.ZoomState z, int l, double margin)
    {
        var cfg = e.Cfg;
        if (z.Anchors[l] != z.Anchor) return false;
        var n = cfg.Columns[l];
        var side = cfg.Side(l);
        var pitch = cfg.Pitch(l);
        var row = (z.Anchor + z.Phases[l]) / n;
        var o = cfg.InsetTop + row * pitch + z.Rel.Y * side - z.Finger.Y;
        if (o < 0 || o > cfg.MaxOffset(l, z.Phases[l])) return false;
        var x0 = z.Cols[l] * pitch;
        var inY = z.Rel.Y * side >= 0.01 && z.Rel.Y * side <= side - 0.01;
        return inY && z.Finger.X >= x0 + margin && z.Finger.X <= x0 + side - margin;
    }

    public static (int Lo, int Hi) Bracket(double s, GridConfig cfg)
    {
        if (s <= cfg.Side(0)) return (0, 0);
        for (var l = 0; l < cfg.Levels - 1; l++) if (s <= cfg.Side(l + 1)) return (l, l + 1);
        return (cfg.Levels - 1, cfg.Levels - 1);
    }

    public static void AssertFullFirstRow(RestState r, GridConfig cfg, string what)
    {
        Assert.True(r.Offset >= -0.001 && r.Offset <= cfg.MaxOffset(r.Level, r.Phase) + 0.001, $"offset out of range {r.Offset}: {what}");
        if (r.Offset < cfg.InsetTop + cfg.Side(r.Level))
            Assert.Equal(r.Phase, 0, $"partial first row on screen: {what}");
    }

    public static void PhotoUnderFingerStaysWherePhotosKeepsIt()
    {
        var checkedFrames = 0;
        var failures = new List<string>();
        for (var level = 0; level < 3; level++)
        foreach (var offset in Offsets(level))
        foreach (var finger in Fingers)
        foreach (var script in Scripts.Where(s => s.Drift.X == 0 && s.Drift.Y == 0))
        {
            var e = MakeEngine(level, offset);
            if (e.RestIndex(finger) is not { } start) continue;
            bool[]? keep = null;
            RunGesture(e, finger, script, f =>
            {
                if (e.Zoom is not { } z) return;
                keep ??= Enumerable.Range(0, e.Cfg.Levels).Select(l => AnchorStays(e, z, l, l == 0 ? 4.5 : 0.01)).ToArray();
                var (lo, hi) = Bracket(f.Side, e.Cfg);
                if (!keep[lo] || !keep[hi]) return;
                checkedFrames++;
                var under = PhotoUnder(f.Finger, f.Tiles);
                if (under != start && failures.Count < 10)
                    failures.Add($"lv={level} off={offset:F0} f=({finger.X:F0},{finger.Y:F0}) {script.Name} s={f.Side:F1}: under={under} anchor={start}");
            });
        }
        Assert.True(checkedFrames > 100_000, $"only checked {checkedFrames} frames");
        Assert.True(failures.Count == 0, string.Join("\n", failures));
    }

    public static void ThreeAndOneColumnsAlwaysKeepThePhoto()
    {
        var cfg = PhoneConfig(DefaultCount);
        var checkedFrames = 0;
        var names = new HashSet<string> { "in one step", "in-out", "fling in", "in to cap", "slow in" };
        foreach (var offset in new[] { 1500.0, 3000.0, 5000.0 })
        foreach (var finger in Fingers)
        foreach (var script in Scripts.Where(s => names.Contains(s.Name)))
        {
            var e = MakeEngine(1, offset);
            if (e.RestIndex(finger) is not { } start) continue;
            RunGesture(e, finger, script, f =>
            {
                if (f.Side < cfg.Side(1)) return;
                checkedFrames++;
                var under = PhotoUnder(f.Finger, f.Tiles);
                Assert.True(under == start, $"under={under} != anchor={start} ({script.Name})");
            });
        }
        Assert.True(checkedFrames > 10_000, $"only checked {checkedFrames}");
    }

    public static void AnchorFollowsFingerVertically()
    {
        var checkedFrames = 0;
        for (var level = 0; level < 3; level++)
        foreach (var offset in Offsets(level))
        foreach (var finger in Fingers.Where(f => ((int)f.X) % 3 == 0))
        foreach (var script in Scripts)
        {
            var e = MakeEngine(level, offset);
            if (e.RestIndex(finger) == null) continue;
            RunGesture(e, finger, script, f =>
            {
                if (e.Zoom is not { } z) return;
                var (lo, hi) = Bracket(f.Side, e.Cfg);
                bool Free(int l)
                {
                    var n = e.Cfg.Columns[l];
                    var row = (z.Anchors[l] + z.Phases[l]) / n;
                    var o = e.Cfg.InsetTop + row * e.Cfg.Pitch(l) + z.Rel.Y * e.Cfg.Side(l) - z.Finger.Y;
                    return o >= 0 && o <= e.Cfg.MaxOffset(l, z.Phases[l]);
                }
                if (!Free(lo) || !Free(hi) || z.Anchors[lo] != z.Anchor || z.Anchors[hi] != z.Anchor) return;
                var found = false;
                foreach (var t in f.Tiles)
                {
                    if (t.Index == z.Anchor && Math.Abs(t.Y + z.Rel.Y * t.Side - z.Finger.Y) < 200)
                    {
                        checkedFrames++;
                        Assert.Close(t.Y + z.Rel.Y * t.Side, z.Finger.Y, 0.01, $"{script.Name}");
                        found = true;
                        break;
                    }
                }
                Assert.True(found, $"anchor tile missing in {script.Name}");
            });
        }
        Assert.True(checkedFrames > 50_000, $"only checked {checkedFrames}");
    }

    public static void RoundTripRestoresLayout()
    {
        var names = new HashSet<string> { "in-out", "out-in", "in small", "out small" };
        for (var level = 0; level < 3; level++)
        foreach (var offset in Offsets(level))
        foreach (var finger in Fingers)
        foreach (var script in Scripts.Where(s => names.Contains(s.Name)))
        {
            var e = MakeEngine(level, offset);
            if (e.RestIndex(finger) == null) continue;
            var before = e.Rest;
            var after = RunGesture(e, finger, script, _ => { });
            if (after.Level != before.Level) continue;
            Assert.Equal(after.Phase, before.Phase, $"{script.Name} lv={level}");
            Assert.Close(after.Offset, before.Offset, 0.01, $"{script.Name} lv={level} off={offset}");
        }
    }

    public static void NoPartialFirstRowAfterAnyZoom()
    {
        for (var level = 0; level < 3; level++)
        foreach (var offset in Offsets(level))
        foreach (var finger in Fingers)
        foreach (var script in Scripts)
        {
            var e = MakeEngine(level, offset);
            var r = RunGesture(e, finger, script, _ => { });
            if (script.Drift.X != 0 || script.Drift.Y != 0) r = AppRealign(r, e.Cfg);
            AssertFullFirstRow(r, e.Cfg, $"lv={level} off={offset} {script.Name}");
        }
    }

    public static void RepeatedZoomsNearTop()
    {
        var rng = new Random(0x5EED);
        foreach (var count in new[] { 206, 7, 13, 26, 40, 61, 500 })
        {
            var e = MakeEngine(1, 0, count);
            var t = 0.0;
            for (var k = 0; k < 1500; k++)
            {
                var finger = new Point(2 + rng.NextDouble() * 398, 140 + rng.NextDouble() * 640);
                var script = Scripts[rng.Next(Scripts.Length)];
                var r = RunGesture(e, finger, script, _ => { }, start: t);
                if (script.Drift.X != 0 || script.Drift.Y != 0) { r = AppRealign(r, e.Cfg); e.Rest = r; }
                t += 10;
                AssertFullFirstRow(r, e.Cfg, $"count={count} k={k} {script.Name}");
                if (k % 7 == 3)
                {
                    var cfg = e.Cfg;
                    var s = e.Rest;
                    s.Offset = GridMath.Clamp(rng.NextDouble() * 900, 0, cfg.MaxOffset(s.Level, s.Phase));
                    if (s.Offset < cfg.InsetTop + 3 * cfg.Pitch(s.Level) && s.Phase != 0)
                    {
                        s.Offset = Math.Min(s.Offset, cfg.MaxOffset(s.Level, 0));
                        s.Phase = 0;
                    }
                    e.Rest = s;
                }
            }
        }
    }

    public static void RegrabDuringSettle()
    {
        foreach (var finger in Fingers.Where(f => ((int)f.Y) % 2 == 0))
        {
            var e = MakeEngine(0, 2000);
            if (e.RestIndex(finger) == null) continue;
            var t = 0.0;
            for (var k = 0; k < 3; k++)
            {
                e.BeginPinch(finger, t);
                for (var i = 1; i <= 20; i++)
                {
                    t += 1.0 / 120.0;
                    e.PinchChanged(Math.Pow(k % 2 == 0 ? 1.6 : 0.7, i / 20.0), finger);
                    e.Tick(t);
                }
                e.Release(0, 1);
                for (var i = 0; i < 6; i++) { t += 1.0 / 120.0; e.Tick(t); }
                Assert.True(e.IsZooming, "expected zooming during settle");
            }
            RestState? settled = null;
            for (var i = 0; i < 1200 && settled == null; i++) { t += 1.0 / 120.0; settled = e.Tick(t); }
            Assert.True(settled != null, "regrab did not settle");
            AssertFullFirstRow(settled!.Value, e.Cfg, "regrab");
        }
    }
}

// ---- Windows desktop regression, geometry, sidebar resize, and performance tests ----

static class WindowsGridTests
{
    static GridConfig DesktopConfig(double w, double h, int count, double scale = 1.25) =>
        new(w, h, scale, insetTop: 60, insetBottom: 52, count: count)
        {
            Columns = GridConfig.ColumnsForWidth(w),
            Exactness = 1.0,
        };

    static ZoomEngine DesktopEngine(double w, double h, int level, double offset, int count = 500)
    {
        var cfg = DesktopConfig(w, h, count);
        var e = new ZoomEngine(cfg, new RestState(level, 0, Math.Clamp(offset, 0, cfg.MaxOffset(level, 0))));
        e.Items = Enumerable.Range(0, count).ToArray();
        return e;
    }

    /// Reproduces the exact reported bug: rapid zoom in -> out at the top of a desktop grid
    /// (e.g. 1000x700 -> 12/8/3 cols, InsetTop = 60), asserting ZERO ghost rows above row 0
    /// or below the last row on every single frame.
    public static void NoGhostRowAboveTopOrBelowBottom()
    {
        var sizes = new[] { (1000.0, 700.0), (1280.0, 820.0), (720.0, 500.0) };
        var scripts = new[]
        {
            new FingerTests.Script("fast in-out", [(0.25, 2.0), (0.25, 1.0)]),
            new FingerTests.Script("fast in2-out", [(0.3, 4.2), (0.3, 1.0)]),
            new FingerTests.Script("out2 from lv2", [(0.25, 0.24)], ReleaseVelocity: -4),
            new FingerTests.Script("fling out from lv1", [(0.12, 0.60)], ReleaseVelocity: -7),
            new FingerTests.Script("in-out-in-out", [(0.2, 2.4), (0.2, 0.9), (0.2, 3.0), (0.2, 1.0)]),
        };

        var framesChecked = 0;
        foreach (var (w, h) in sizes)
        foreach (var count in new[] { 500, 37, 15 })
        foreach (var startLv in new[] { 0, 1, 2 })
        foreach (var offset in new[] { 0.0, 20.0, DesktopConfig(w, h, count).MaxOffset(startLv, 0) })
        foreach (var finger in new[] { new Point(w * 0.35, h * 0.48), new Point(w * 0.5, h * 0.5), new Point(90, 220) })
        foreach (var script in scripts)
        {
            var e = DesktopEngine(w, h, startLv, offset, count);
            FingerTests.RunGesture(e, finger, script, f =>
            {
                framesChecked++;
                if (e.Zoom is not { } z) return;
                var s = f.Side;
                var p = s + e.Cfg.Gap;
                // Find Layer 0's exact top and bottom row bounds on screen.
                var n0 = e.Cfg.Columns[0];
                var row0Anchor = (z.Anchors[0] + z.Phases[0]) / n0;
                var layer0MinY = double.PositiveInfinity;
                var layer0MaxBottom = double.NegativeInfinity;
                foreach (var t in f.Tiles)
                {
                    if (t.Alpha >= 0.999)
                    {
                        if (t.Y < layer0MinY) layer0MinY = t.Y;
                        if (t.Y + t.Side > layer0MaxBottom) layer0MaxBottom = t.Y + t.Side;
                    }
                }
                // Whenever Layer 0 is visible and photo #0 is on screen (at or below y = 0),
                // once shrunk past the initial 20% fade-out margin from level 1 (sideFrac <= 0.80),
                // NO semi-transparent tile from a sparser layer may float above photo #0's top edge.
                var s0 = e.Cfg.Side(0);
                var s1 = e.Cfg.Side(1);
                var pastFadeMargin = s <= s0 + 0.80 * (s1 - s0);
                var hasPhoto0InL0 = f.Tiles.Any(t => t.Alpha >= 0.999 && t.Index == 0 && t.Y >= 0);
                if (hasPhoto0InL0 && pastFadeMargin)
                {
                    var photo0Y = f.Tiles.First(t => t.Alpha >= 0.999 && t.Index == 0).Y;
                    foreach (var t in f.Tiles)
                    {
                        if (t.Alpha < 0.999 && t.Y + t.Side <= photo0Y + 1.0)
                            throw new Exception($"Ghost tile above photo #0! w={w} lv={startLv} {script.Name} s={s:F1} tileY={t.Y:F1} alpha={t.Alpha:F2} photo0Y={photo0Y:F1}");
                    }
                }
                // Similarly at the bottom: if the last photo (count - 1) is on screen in Layer 0,
                // NO semi-transparent ghost tile may float below it.
                var hasLastInL0 = f.Tiles.Any(t => t.Alpha >= 0.999 && t.Index == count - 1 && t.Y + t.Side <= h);
                if (hasLastInL0 && pastFadeMargin)
                {
                    var lastBot = f.Tiles.First(t => t.Alpha >= 0.999 && t.Index == count - 1).Y + s;
                    foreach (var t in f.Tiles)
                    {
                        if (t.Alpha < 0.999 && t.Y >= lastBot - 1.0)
                            throw new Exception($"Ghost tile below last photo! w={w} lv={startLv} {script.Name} s={s:F1} tileY={t.Y:F1} alpha={t.Alpha:F2} lastBot={lastBot:F1}");
                    }
                }
            });
        }
        Assert.True(framesChecked > 20_000, $"only checked {framesChecked} frames");
    }

    /// Simulates the exact chained ZoomGridView.Step() animation (0 -> 1 -> 2 -> 1 -> 0) near top
    /// and verifies zero ghost rows and clean settle to level 0, phase 0.
    public static void ChainedStepReversalNearTop()
    {
        var e = DesktopEngine(1000, 700, level: 0, offset: 0, count: 500);
        var cfg = e.Cfg;
        var anchor = new Point(370, 340);
        var t = 0.0;
        const double dt = 1.0 / 120.0;
        e.BeginPinch(anchor, t);
        var tiles = new List<GridTile>();

        // 0 -> 2 over 0.25s, then immediately reverse 2 -> 0 over 0.25s, then release.
        var to2 = cfg.Side(2) / cfg.Side(0);
        for (var i = 1; i <= 30; i++)
        {
            t += dt;
            var k = i / 30.0;
            var ease = 1.0 - Math.Pow(1.0 - k, 3.0);
            e.PinchChanged(Math.Pow(to2, ease), anchor);
            e.Tick(t);
        }
        for (var i = 1; i <= 30; i++)
        {
            t += dt;
            var k = i / 30.0;
            var ease = 1.0 - Math.Pow(1.0 - k, 3.0);
            e.PinchChanged(Math.Pow(to2, 1.0 - ease), anchor);
            e.Tick(t);
            tiles.Clear();
            e.ZoomTiles(tiles);
            CheckNoTopGhost(tiles, cfg);
        }
        e.Release(0, 1.0);
        RestState? settled = null;
        for (var i = 0; i < 600 && settled == null; i++)
        {
            t += dt;
            settled = e.Tick(t);
            if (settled == null)
            {
                tiles.Clear();
                e.ZoomTiles(tiles);
                CheckNoTopGhost(tiles, cfg);
            }
        }
        Assert.True(settled != null, "chained reversal did not settle");
        Assert.Equal(settled!.Value.Level, 0, "should settle back at level 0");
        Assert.Equal(settled.Value.Phase, 0, "should have full first row");
        Assert.Close(settled.Value.Offset, 0.0, 0.05, "should restore offset 0");
    }

    static void CheckNoTopGhost(List<GridTile> tiles, GridConfig cfg)
    {
        var hasP0 = false;
        var p0Y = 0.0;
        foreach (var tile in tiles)
        {
            if (tile.Alpha >= 0.999 && tile.Index == 0) { hasP0 = true; p0Y = tile.Y; break; }
        }
        if (!hasP0 || p0Y < 0) return;
        foreach (var tile in tiles)
        {
            if (tile.Alpha < 0.999 && tile.Y + tile.Side <= p0Y + 1.0)
                throw new Exception($"Ghost tile at y={tile.Y:F1} (alpha={tile.Alpha:F2}) above photo #0 at y={p0Y:F1}");
        }
    }

    /// Checks on Windows desktop resolutions that (a) the photo under the cursor stays locked
    /// during zoom and (b) every surrounding tile lies on the exact lattice (pitch = side + gap)
    /// with no overlap inside any layer.
    public static void DesktopPhotoUnderFingerAndNeighbors()
    {
        var cfg = DesktopConfig(1280, 820, 500);
        var e = DesktopEngine(1280, 820, level: 1, offset: 1200, count: 500);
        var cursor = new Point(620, 410);
        var startPhoto = e.RestIndex(cursor)!.Value;
        var checkedFrames = 0;

        foreach (var script in new[]
        {
            new FingerTests.Script("in", [(0.4, 2.8)]),
            new FingerTests.Script("out", [(0.4, 0.55)]),
            new FingerTests.Script("in-out", [(0.3, 2.5), (0.3, 1.0)]),
        })
        {
            e = DesktopEngine(1280, 820, level: 1, offset: 1200, count: 500);
            FingerTests.RunGesture(e, cursor, script, f =>
            {
                if (e.Zoom is not { } z) return;
                checkedFrames++;
                // Photo under cursor stays identical wherever Photos' keep-region applies.
                var (lo, hi) = FingerTests.Bracket(f.Side, e.Cfg);
                if (FingerTests.AnchorStays(e, z, lo, lo == 0 ? 4.5 : 0.01) &&
                    FingerTests.AnchorStays(e, z, hi, hi == 0 ? 4.5 : 0.01))
                {
                    var under = FingerTests.PhotoUnder(f.Finger, f.Tiles);
                    Assert.True(under == startPhoto, $"cursor photo drifted: under={under} != {startPhoto} ({script.Name})");
                }
                // Check lattice integrity: every tile sits on (ax + dc*pitch, ay + dr*pitch) with exact pitch.
                var p = f.Side + e.Cfg.Gap;
                Assert.True(f.Tiles.Count > 0, "empty frame");
                var refTile = f.Tiles[0];
                foreach (var t in f.Tiles)
                {
                    Assert.True(!double.IsNaN(t.X) && !double.IsNaN(t.Y) && t.Side > 0, "invalid tile geometry");
                    var dx = (t.X - refTile.X) / p;
                    var dy = (t.Y - refTile.Y) / p;
                    Assert.Close(dx, Math.Round(dx), 0.002, "tile X off lattice");
                    Assert.Close(dy, Math.Round(dy), 0.002, "tile Y off lattice");
                }
            });
        }
        Assert.True(checkedFrames > 200, "too few frames");
    }

    /// Opening/closing the NavigationView sidebar at constant window width keeps column counts fixed
    /// and keeps the middle row locked on screen.
    public static void SidebarResizeKeepsColumnsAndRow()
    {
        var cols1 = GridConfig.ColumnsForWidth(1280, windowWidth: 1280);
        var cols2 = GridConfig.ColumnsForWidth(1016, windowWidth: 1280);
        Assert.True(GridConfig.SameColumns(cols1, cols2), "columns changed during sidebar toggle");

        var cfg1 = new GridConfig(1280, 820, 1.25, 60, 52, 500) { Columns = cols1, Exactness = 1.0 };
        var scene = new GridScene(cfg1, level: 1);
        scene.SetTiles(Enumerable.Range(0, 500).Select(i => new ZoomGridTile(new TwimShelf.Core.FeedItem { MediaId = $"m{i}" }, 1)).ToList());
        scene.Engine.Rest.Offset = 900;

        var middleY = (cfg1.InsetTop + cfg1.Height) * 0.5;
        var rowBefore = Math.Floor((middleY - cfg1.InsetTop + scene.Engine.Rest.Offset) / cfg1.Pitch(1));
        var onScreenBefore = cfg1.InsetTop + (rowBefore + 0.5) * cfg1.Pitch(1) - scene.Engine.Rest.Offset;

        var cfg2 = new GridConfig(1016, 820, 1.25, 60, 52, 500) { Columns = cols2, Exactness = 1.0 };
        scene.SetConfig(cfg2);
        var onScreenAfter = cfg2.InsetTop + (rowBefore + 0.5) * cfg2.Pitch(1) - scene.Engine.Rest.Offset;
        Assert.Close(onScreenAfter, onScreenBefore, 0.01, "middle row jumped during sidebar resize");
    }

    /// Benchmarks 2,000 frames of 5,000-photo zoom + cross-fade + deletion + reflow.
    public static void Performance5000Tiles()
    {
        var cfg = DesktopConfig(1440, 900, 5000);
        var scene = new GridScene(cfg, level: 0);
        var items = Enumerable.Range(0, 5000).Select(i => new ZoomGridTile(new TwimShelf.Core.FeedItem { MediaId = $"p{i}" }, 1)).ToList();
        scene.SetTiles(items);
        var tiles = new List<GridTile>(512);
        var sw = Stopwatch.StartNew();
        var t = 0.0;
        const double dt = 1.0 / 120.0;

        scene.Engine.BeginPinch(new Point(720, 450), t);
        for (var i = 0; i < 2000; i++)
        {
            t += dt;
            if (i < 500) scene.Engine.PinchChanged(1.0 + 3.0 * (i / 500.0), new Point(720, 450));
            else if (i < 1000) scene.Engine.PinchChanged(4.0 - 3.0 * ((i - 500) / 500.0), new Point(720, 450));
            else if (i == 1000) scene.Engine.Release(0, 1.0);
            scene.Frame(t, tiles);
        }
        sw.Stop();
        var avgMs = sw.Elapsed.TotalMilliseconds / 2000.0;
        Console.Write($"[avg={avgMs:F3} ms/frame over 5000 items] ");
        Assert.True(avgMs < 0.5, $"frame time too slow: {avgMs:F3} ms");
    }
}

// ---- Unified Viewer geometry, transition, strip paging, dismiss drag, and hidden-tile sync tests ----

static class ViewerTests
{
    static Rect ScreenRectOfClip(TransitionFrame f) =>
        new(f.OffsetX + f.ClipX * f.Scale, f.OffsetY + f.ClipY * f.Scale, f.ClipW * f.Scale, f.ClipH * f.Scale);

    public static void ZoomTransitionPixelExactBounds()
    {
        var bounds = new Rect(0, 0, 1280, 820);
        var aspects = new[] { (1920.0, 1080.0), (1080.0, 1920.0), (1000.0, 1000.0), (2400.0, 600.0) };

        foreach (var (mw, mh) in aspects)
        {
            var media = ViewerMath.FitMedia(bounds, mw, mh);

            // Grid square tile (cropSource = true, cornerRadius = 2.5)
            var gridTile = new Rect(420, 260, 148, 148);
            var f0 = ViewerMath.EvaluateTransition(bounds, media, gridTile, cropSource: true, sourceCornerRadius: 2.5, raw: 0, closing: false, DismissState.None);
            var landed0 = ScreenRectOfClip(f0);
            Assert.Close(landed0.X, gridTile.X, 1e-6, $"grid f0 X ({mw}x{mh})");
            Assert.Close(landed0.Y, gridTile.Y, 1e-6, $"grid f0 Y ({mw}x{mh})");
            Assert.Close(landed0.Width, gridTile.Width, 1e-6, $"grid f0 W ({mw}x{mh})");
            Assert.Close(landed0.Height, gridTile.Height, 1e-6, $"grid f0 H ({mw}x{mh})");
            Assert.Close(f0.ClipCornerRadius * f0.Scale, 2.5, 1e-6, "grid f0 screen corner radius");
            Assert.True(f0.ClipW <= media.Width + 1e-6 && f0.ClipH <= media.Height + 1e-6, "grid f0 clip exceeds media");
            Assert.Close(f0.BackdropOpacity, 0, 1e-6, "grid f0 backdrop");
            Assert.Close(f0.ChromeOpacity, 0, 1e-6, "grid f0 chrome");

            // At rest (raw = 1)
            var f1 = ViewerMath.EvaluateTransition(bounds, media, gridTile, cropSource: true, sourceCornerRadius: 2.5, raw: 1, closing: false, DismissState.None);
            Assert.Close(f1.Scale, 1.0, 1e-6, "grid f1 scale");
            Assert.Close(f1.OffsetX, 0.0, 1e-6, "grid f1 offsetX");
            Assert.Close(f1.OffsetY, 0.0, 1e-6, "grid f1 offsetY");
            Assert.Close(f1.BackdropOpacity, 1.0, 1e-6, "grid f1 backdrop");
            Assert.Close(f1.ChromeOpacity, 1.0, 1e-6, "grid f1 chrome");

            // Browse card media (cropSource = false, cornerRadius = 8)
            var cardW = 360.0;
            var cardH = cardW / (mw / mh);
            var cardRect = new Rect(200, 140, cardW, Math.Clamp(cardH, cardW * 0.3, cardW * 1.8));
            var c0 = ViewerMath.EvaluateTransition(bounds, media, cardRect, cropSource: false, sourceCornerRadius: 8.0, raw: 0, closing: false, DismissState.None);
            var cardLanded0 = ScreenRectOfClip(c0);
            Assert.Close(cardLanded0.X, cardRect.X, 1e-6, $"card f0 X ({mw}x{mh})");
            Assert.Close(cardLanded0.Y, cardRect.Y, 1e-6, $"card f0 Y ({mw}x{mh})");
            Assert.Close(cardLanded0.Width, cardRect.Width, 1e-6, $"card f0 W ({mw}x{mh})");
            Assert.Close(cardLanded0.Height, cardRect.Height, 1e-6, $"card f0 H ({mw}x{mh})");
            Assert.Close(c0.ClipCornerRadius * c0.Scale, 8.0, 1e-6, "card f0 screen corner radius");

            // Reverse dissolve tail
            var tail = ViewerMath.EvaluateTransition(bounds, media, gridTile, cropSource: true, sourceCornerRadius: 2.5, raw: 0.05, closing: true, DismissState.None);
            Assert.Close(tail.SurfaceOpacity, 0.5, 1e-6, "reverse dissolve tail at raw=0.05");
        }
    }

    public static void DismissDragAndCloseFlightContinuity()
    {
        var bounds = new Rect(0, 0, 1280, 820);
        var media = ViewerMath.FitMedia(bounds, 1600, 1200);
        var src = new Rect(300, 200, 160, 160);

        // Downward drag shrinks toward 0.66 and upward drag is damped 0.28x.
        var up = ViewerMath.EvaluateDismiss(0, -100, 1280, 820, fromEdge: false, edgeDir: 1);
        Assert.Close(up.OffsetY, -28.0, 1e-6, "upward damping 0.28x");
        Assert.Close(up.Progress, 0.0, 1e-6, "upward progress 0");

        var drag = ViewerMath.EvaluateDismiss(45, 160, 1280, 820, fromEdge: false, edgeDir: 1);
        Assert.True(drag.Progress > 0.4 && drag.Progress < 0.6, "mid drag progress");
        Assert.Close(drag.Scale, 1.0 - 0.34 * drag.Progress, 1e-6, "drag scale formula");
        Assert.True(ViewerMath.ShouldCommitDismiss(45, 160, 0, 20, 1280, 820, false, 1), "past threshold should commit");
        Assert.True(!ViewerMath.ShouldCommitDismiss(5, 20, 0, 10, 1280, 820, false, 1), "tiny drag should cancel");

        // Continuity at release (raw = 1.0 closing) matches dragged center and scale with zero jump.
        var startClose = ViewerMath.EvaluateTransition(bounds, media, src, cropSource: true, sourceCornerRadius: 2.5, raw: 1.0, closing: true, drag);
        var mediaCx = media.X + media.Width * 0.5;
        var mediaCy = media.Y + media.Height * 0.5;
        Assert.Close(startClose.Scale, drag.Scale, 1e-6, "close start scale matches drag");
        Assert.Close(startClose.OffsetX + mediaCx * startClose.Scale, mediaCx + drag.OffsetX, 1e-6, "close start centerX matches drag");
        Assert.Close(startClose.OffsetY + mediaCy * startClose.Scale, mediaCy + drag.OffsetY, 1e-6, "close start centerY matches drag");

        // And lands pixel-exact on `src` at raw = 0.0.
        var endClose = ViewerMath.EvaluateTransition(bounds, media, src, cropSource: true, sourceCornerRadius: 2.5, raw: 0.0, closing: true, drag);
        var landed = ScreenRectOfClip(endClose);
        Assert.Close(landed.X, src.X, 1e-6, "close end X");
        Assert.Close(landed.Y, src.Y, 1e-6, "close end Y");
        Assert.Close(landed.Width, src.Width, 1e-6, "close end W");
        Assert.Close(landed.Height, src.Height, 1e-6, "close end H");
    }

    public static void StripPagingSwipeSettleAndCaptionFade()
    {
        var stride = ViewerMath.Stride(1280);
        Assert.Close(stride, 1320.0, 1e-6, "stride = width + 40");

        // Edge resistance 0.3x past first and last page.
        var pastFirst = ViewerMath.ApplyStripDelta(0, 100, index: 0, count: 5, stride);
        Assert.Close(pastFirst, 30.0, 1e-6, "first-page 0.3x edge resistance");
        var pastLast = ViewerMath.ApplyStripDelta(0, -100, index: 4, count: 5, stride);
        Assert.Close(pastLast, -30.0, 1e-6, "last-page 0.3x edge resistance");

        // Velocity flick advances one page with clamped velocity-matched duration.
        var (flickNext, durNext) = ViewerMath.SettleStrip(-40, velocityPxPerSec: -900, index: 1, count: 5, stride);
        Assert.True(flickNext == 1, $"expected +1 on left flick, got {flickNext}");
        Assert.True(durNext >= 0.16 && durNext <= 0.38, $"duration out of bounds: {durNext}");

        // Slow short drag snaps back to current page.
        var (snapBack, _) = ViewerMath.SettleStrip(-150, velocityPxPerSec: 0, index: 1, count: 5, stride);
        Assert.True(snapBack == 0, $"expected snap back 0, got {snapBack}");

        // Slow past-halfway drag advances.
        var (pastHalf, _) = ViewerMath.SettleStrip(-stride * 0.6, velocityPxPerSec: 0, index: 1, count: 5, stride);
        Assert.True(pastHalf == 1, $"expected +1 past halfway, got {pastHalf}");

        // Caption fade: 1.0 within same post, fades over first 40% of stride for different post.
        Assert.Close(ViewerMath.CaptionFade(-300, stride, "postA", "postA"), 1.0, 1e-6, "same post keeps caption");
        Assert.Close(ViewerMath.CaptionFade(-stride * 0.2, stride, "postA", "postB"), 0.5, 1e-6, "cross post halfway fade");
        Assert.Close(ViewerMath.CaptionFade(-stride * 0.45, stride, "postA", "postB"), 0.0, 1e-6, "cross post fully faded");
    }

    public static void PhotoCursorAnchoredZoomAndClamp()
    {
        const double viewW = 1280, viewH = 820, baseW = 1000, baseH = 800;
        var ptX = 800.0;
        var ptY = 300.0;

        var v0 = PhotoView.Identity;
        var v1 = ViewerMath.ZoomPhotoAt(v0, 3.0, ptX, ptY, baseW, baseH, viewW, viewH);
        Assert.Close(v1.Scale, 3.0, 1e-6, "zoom scale 3.0");

        // Photo point originally under (ptX, ptY) at v0:
        var localX = (ptX - viewW * 0.5 - v0.X) / v0.Scale;
        var localY = (ptY - viewH * 0.5 - v0.Y) / v0.Scale;
        // Same photo point at v1 must stay right under (ptX, ptY) (since 3000x2400 is wide enough not to clamp):
        var mappedX = viewW * 0.5 + v1.X + localX * v1.Scale;
        var mappedY = viewH * 0.5 + v1.Y + localY * v1.Scale;
        Assert.Close(mappedX, ptX, 1e-6, "cursor X anchored");
        Assert.Close(mappedY, ptY, 1e-6, "cursor Y anchored");

        // Clamping prevents pulling edges past viewport.
        var clamped = ViewerMath.ClampPhotoView(new PhotoView(2.0, 99999, -99999), baseW, baseH, viewW, viewH);
        Assert.Close(clamped.X, (baseW * 2.0 - viewW) * 0.5, 1e-6, "clamped max X");
        Assert.Close(clamped.Y, -(baseH * 2.0 - viewH) * 0.5, 1e-6, "clamped min Y");
    }

    public static void GridHiddenPhotoAndSourceFrameSync()
    {
        var cfg = new GridConfig(1000, 700, 1.25, 60, 52, 40) { Columns = GridConfig.ColumnsForWidth(1000), Exactness = 1.0 };
        var scene = new GridScene(cfg, level: 1);
        var tiles = Enumerable.Range(0, 40).Select(i => new ZoomGridTile(new TwimShelf.Core.FeedItem { MediaId = $"img-{i}" }, 1)).ToList();
        scene.SetTiles(tiles);

        var key7 = scene.KeyOfMedia("img-7");
        Assert.True(key7 != null, "KeyOfMedia returned null");
        var k7 = key7!.Value;

        scene.Engine.HiddenPhoto = k7;
        var drawn = new List<GridTile>();
        scene.Frame(0, drawn);
        var key6 = scene.KeyOfMedia("img-6");
        Assert.True(key6 != null, "KeyOfMedia(img-6) returned null");
        var k6 = key6!.Value;
        Assert.True(drawn.All(t => t.Photo != k7), "hidden tile should not be emitted");
        Assert.True(drawn.Any(t => t.Photo == k6), "neighbor tile should still be emitted");

        var rect7 = scene.Engine.RestFrame(7, scene.Engine.Rest);
        Assert.True(rect7.Width > 0 && rect7.Height > 0 && rect7.Y >= cfg.InsetTop, "RestFrame valid for visible tile");

        scene.Engine.HiddenPhoto = null;
        scene.Frame(0, drawn);
        Assert.True(drawn.Any(t => t.Photo == k7), "unhidden tile should reappear");
    }
}
