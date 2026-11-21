// Manages the media list, conveyor first-row reflow, and removal animation over ZoomEngine
// (same logic as Apple/Shared/Grid/GridScene.swift).
using System.Diagnostics;
using Windows.Foundation;

namespace TwimShelf.Controls.ZoomGrid;

public sealed class GridScene
{
    public ZoomEngine Engine { get; }
    public List<ZoomGridTile> Tiles { get; private set; } = [];
    readonly Dictionary<string, int> _keys = [];
    readonly Dictionary<int, ZoomGridTile> _tileByKey = [];
    int _nextKey;
    public bool Selecting;
    public HashSet<string> Selected = [];

    record struct ReflowState(RestState From, RestState To, double Start);
    ReflowState? _reflow;

    sealed class DeletionState(int[] oldItems, HashSet<int> removed, RestState rest, double start)
    {
        public readonly int[] OldItems = oldItems;
        public readonly HashSet<int> Removed = removed;
        public readonly RestState Rest = rest;
        public readonly double Start = start;
    }
    DeletionState? _deletion;
    List<ZoomGridTile>? _pending;

    public event Action? RestChanged;
    public event Action? ContentHeightChanged;

    public static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    public GridScene(GridConfig cfg, int level)
    {
        Engine = new ZoomEngine(cfg, new RestState(Math.Clamp(level, 0, cfg.Levels - 1), 0, 0));
        Engine.Items = [];
    }

    public bool IsAnimating => Engine.IsZooming || _reflow != null || _deletion != null;
    public bool IsBusy => Engine.IsZooming || _deletion != null;

    public ZoomGridTile? TileByKey(int key) => _tileByKey.GetValueOrDefault(key);
    public ZoomGridTile? TileAt(int index) => index >= 0 && index < Tiles.Count ? Tiles[index] : null;
    public int? KeyOfMedia(string mediaId) => _keys.TryGetValue(mediaId, out var k) ? k : null;
    public bool IsSelected(int key) => Selecting && _tileByKey.TryGetValue(key, out var t) && Selected.Contains(t.Item.MediaId);

    int KeyFor(string id)
    {
        if (_keys.TryGetValue(id, out var k)) return k;
        k = ++_nextKey;
        _keys[id] = k;
        return k;
    }

    // ---- Content ----

    public void SetTiles(List<ZoomGridTile> tiles)
    {
        if (IsBusy) { _pending = tiles; return; }
        var newKeys = new int[tiles.Count];
        for (var i = 0; i < tiles.Count; i++)
        {
            var k = KeyFor(tiles[i].Item.MediaId);
            newKeys[i] = k;
            _tileByKey[k] = tiles[i];
        }
        var old = Engine.Items;
        if (Selected.Count > 0)
        {
            var ids = new HashSet<string>(tiles.Count);
            foreach (var t in tiles) ids.Add(t.Item.MediaId);
            Selected.IntersectWith(ids);
        }
        if (old.AsSpan().SequenceEqual(newKeys))
        {
            Tiles = tiles;
            return;
        }
        if (old.Length > 0 && newKeys.Length < old.Length && FindRemoval(old, newKeys) is { } removed)
        {
            Tiles = tiles;
            StartDeletion(removed);
            return;
        }
        Replace(tiles, newKeys);
    }

    static HashSet<int>? FindRemoval(int[] oldItems, int[] newItems)
    {
        var removed = new HashSet<int>();
        var j = 0;
        for (var i = 0; i < oldItems.Length; i++)
        {
            if (j < newItems.Length && newItems[j] == oldItems[i]) j++;
            else removed.Add(i);
        }
        return j == newItems.Length ? removed : null;
    }

    void Replace(List<ZoomGridTile> tiles, int[] newKeys)
    {
        var cfg = Engine.Cfg;
        var r = Engine.Rest;
        var mid = new Point(cfg.Width * 0.5, cfg.InsetTop + (cfg.Height - cfg.InsetTop - cfg.InsetBottom) * 0.5);
        int? anchorIdx = Engine.RestIndex(mid) ?? (Engine.Items.Length > 0 ? 0 : null);
        (int Key, Rect Frame)? anchor = anchorIdx is { } ai ? (Engine.Items[ai], Engine.RestFrame(ai, r)) : null;

        Tiles = tiles;
        Engine.Items = newKeys;
        _reflow = null;
        var rest = new RestState(r.Level, 0, 0);
        if (anchor is { } a)
        {
            var j = Array.IndexOf(newKeys, a.Key);
            if (j >= 0)
            {
                var n = cfg.Columns[r.Level];
                var pitch = cfg.Pitch(r.Level);
                var col = (int)Math.Round(a.Frame.X / pitch, MidpointRounding.AwayFromZero);
                rest.Phase = GridMath.PosMod(col - j, n);
                var row = (j + rest.Phase) / n;
                rest.Offset = GridMath.Clamp(cfg.InsetTop + row * pitch - a.Frame.Y, 0.0, Engine.Cfg.MaxOffset(r.Level, rest.Phase));
                if (rest.Offset < cfg.InsetTop + cfg.Side(r.Level) + pitch)
                {
                    var row0 = j / n;
                    rest.Phase = 0;
                    rest.Offset = GridMath.Clamp(cfg.InsetTop + row0 * pitch - a.Frame.Y, 0.0, Engine.Cfg.MaxOffset(r.Level, 0));
                }
            }
        }
        Engine.Rest = rest;
        RestChanged?.Invoke();
    }

    public void SetConfig(GridConfig cfg)
    {
        if (IsBusy) return;
        cfg.Count = Engine.Items.Length;
        var old = Engine.Cfg;
        var r = Engine.Rest;
        if (Math.Abs(cfg.Scale - old.Scale) < 0.001 &&
            GridConfig.SameColumns(cfg.Columns, old.Columns) &&
            Math.Abs(cfg.Pitch(r.Level) - old.Pitch(r.Level)) > 1e-4)
        {
            var middle = (old.InsetTop + old.Height) * 0.5;
            var row = Math.Floor((middle - old.InsetTop + r.Offset) / old.Pitch(r.Level));
            var onScreen = old.InsetTop + (row + 0.5) * old.Pitch(r.Level) - r.Offset;
            Engine.Cfg = cfg;
            Engine.Rest.Offset = GridMath.Clamp(cfg.InsetTop + (row + 0.5) * cfg.Pitch(r.Level) - onScreen, 0.0, cfg.MaxOffset(r.Level, r.Phase));
            _reflow = null;
            RestChanged?.Invoke();
            return;
        }
        if (Math.Abs(cfg.Width - old.Width) < 0.01 &&
            Math.Abs(cfg.Scale - old.Scale) < 0.001 &&
            GridConfig.SameColumns(cfg.Columns, old.Columns))
        {
            Engine.Cfg = cfg;
            Engine.Rest.Offset = GridMath.Clamp(r.Offset, 0.0, cfg.MaxOffset(r.Level, r.Phase));
            RestChanged?.Invoke();
            return;
        }
        var level = r.Level;
        int? midIndex = Engine.Items.Length == 0 ? null : (Engine.RestIndex(new Point(old.Width * 0.5, old.InsetTop + 1)) ?? 0);
        Engine.Cfg = cfg;
        var rest = new RestState(Math.Min(level, cfg.Levels - 1), 0, 0);
        if (midIndex is { } mi && r.Offset > 0)
        {
            var row = mi / cfg.Columns[rest.Level];
            rest.Offset = GridMath.Clamp(row * cfg.Pitch(rest.Level), 0.0, cfg.MaxOffset(rest.Level, 0));
        }
        Engine.Rest = rest;
        _reflow = null;
        RestChanged?.Invoke();
    }

    // ---- Re-aligning first row ----

    (double Offset, double Time)? _lastScroll;
    const double GlideBelow = 300.0;

    public void RealignBeforeTopShows()
    {
        var cfg = Engine.Cfg;
        var r = Engine.Rest;
        var now = Now();
        var speed = 0.0;
        if (_lastScroll is { } last && now - last.Time > 0 && now - last.Time < 0.1)
            speed = Math.Abs(r.Offset - last.Offset) / (now - last.Time);
        _lastScroll = (r.Offset, now);
        if (r.Phase == 0 || _reflow != null) return;
        if (r.Offset < cfg.InsetTop + 3 * cfg.Pitch(r.Level))
            RealignToTop(animated: speed < GlideBelow);
    }

    public void RealignToTop(bool animated = true)
    {
        if (Engine.IsZooming || _reflow != null || _deletion != null) return;
        var r = Engine.Rest;
        if (r.Phase == 0) return;
        if (animated)
            _reflow = new ReflowState(r, new RestState(r.Level, 0, r.Offset), Now());
        Engine.Rest.Phase = 0;
        ContentHeightChanged?.Invoke();
    }

    // ---- Removal ----

    void StartDeletion(HashSet<int> removed)
    {
        var old = Engine.Items;
        _reflow = null;
        _deletion = new DeletionState(old, removed, Engine.Rest, Now());
        var kept = new int[old.Length - removed.Count];
        var j = 0;
        for (var i = 0; i < old.Length; i++)
            if (!removed.Contains(i)) kept[j++] = old[i];
        Engine.Items = kept;
    }

    void FinishDeletion()
    {
        _deletion = null;
        ContentHeightChanged?.Invoke();
        if (_pending is { } p) { _pending = null; SetTiles(p); }
    }

    void ZoomEnded()
    {
        var r = Engine.Rest;
        _reflow = null;
        RestChanged?.Invoke();
        if (r.Phase != 0 && r.Offset < Engine.Cfg.InsetTop + Engine.Cfg.Side(r.Level))
            RealignToTop();
        if (_pending is { } p) { _pending = null; SetTiles(p); }
    }

    public bool FinishZoomNow()
    {
        if (Engine.FinishNow() == null) return false;
        ZoomEnded();
        return true;
    }

    // ---- Frame ----

    /// Advances animations and populates `output` back-to-front. Returns true if a zoom just finished.
    public bool Frame(double now, List<GridTile> output)
    {
        output.Clear();
        var zoomFinished = false;
        if (Engine.IsZooming)
        {
            if (_deletion != null) FinishDeletion();
            if (Engine.Tick(now) != null)
            {
                ZoomEnded();
                zoomFinished = true;
            }
        }
        if (Engine.IsZooming)
            Engine.ZoomTiles(output);
        else if (_deletion is { } d)
            DeletionTiles(d, now, output);
        else if (_reflow is { } rf)
            ReflowTiles(rf, now, output);
        else
            Engine.RestTiles(Engine.Rest, output);
        return zoomFinished;
    }

    void ReflowTiles(ReflowState rf, double now, List<GridTile> output)
    {
        var t = Math.Min(1.0, (now - rf.Start) / 0.3);
        var e = 1.0 - Math.Pow(1.0 - t, 3.0);
        var cfg = Engine.Cfg;
        var l = rf.To.Level;
        var n = cfg.Columns[l];
        var p = cfg.Pitch(l);
        var side = cfg.Side(l);
        var delta = rf.To.Phase - rf.From.Phase;
        var phase = rf.From.Phase + delta * e;
        var offset = Engine.Rest.Offset;
        var rowMin = (int)Math.Floor((offset - cfg.InsetTop) / p) - 1;
        var rowMax = (int)Math.Floor((offset - cfg.InsetTop + cfg.Height) / p) + 1;
        var iMin = Math.Max(0, rowMin * n - rf.From.Phase - 1);
        var iMax = Math.Min(cfg.Count - 1, (rowMax + 1) * n);
        if (t >= 1.0) _reflow = null;
        if (iMin > iMax) return;

        void Add(double col, int row, int index)
        {
            var x = col * p;
            var y = cfg.InsetTop + row * p - offset;
            if (x + side <= 0 || x >= cfg.Width || y + side <= 0 || y >= cfg.Height) return;
            var (r0, r1, r2, r3) = Engine.Radii(x, side, true, true);
            output.Add(new GridTile
            {
                X = x, Y = y, Side = side, Alpha = 1.0,
                Index = index, Photo = Engine.Items[index],
                R0 = r0, R1 = r1, R2 = r2, R3 = r3,
            });
        }

        for (var i = iMin; i <= iMax; i++)
        {
            var k = i + phase;
            var row = (int)Math.Floor(k / n);
            var col = k - row * n;
            Add(col, row, i);
            if (col > n - 1) Add(col - n, row + 1, i);
        }
    }

    void DeletionTiles(DeletionState d, double now, List<GridTile> output)
    {
        var t = Math.Min(1.0, (now - d.Start) / 0.36);
        var e = GridMath.CubicBezier(0.25, 0.9, 0.3, 1.0, t);
        var cfg = Engine.Cfg;
        var r = d.Rest;
        r.Offset = Engine.Rest.Offset;
        var n = cfg.Columns[r.Level];
        var p = cfg.Pitch(r.Level);
        var side = cfg.Side(r.Level);
        var rowMin = (int)Math.Floor((r.Offset - cfg.InsetTop) / p) - 1;
        var rowMax = (int)Math.Floor((r.Offset - cfg.InsetTop + cfg.Height) / p) + 1;
        var lo = Math.Max(0, rowMin * n - r.Phase);
        var hi = Math.Min(d.OldItems.Length - 1, (rowMax + 1) * n - r.Phase);

        if (lo <= hi)
        {
            Rect FrameOf(int i)
            {
                var (col, row) = cfg.Cell(i, r.Level, r.Phase);
                return new Rect(col * p, cfg.InsetTop + row * p - r.Offset, side, side);
            }
            GridTile MakeTile(Rect f, int index, int key, double alpha)
            {
                var (r0, r1, r2, r3) = Engine.Radii(f.X, side, true, true);
                return new GridTile
                {
                    X = f.X, Y = f.Y, Side = side, Alpha = alpha,
                    Index = index, Photo = key,
                    R0 = r0, R1 = r1, R2 = r2, R3 = r3,
                };
            }

            for (var i = lo; i <= hi; i++)
                if (d.Removed.Contains(i))
                    output.Add(MakeTile(FrameOf(i), i, d.OldItems[i], 1.0 - e));

            var before = 0;
            foreach (var ri in d.Removed) if (ri < lo) before++;
            for (var i = lo; i <= hi; i++)
            {
                if (d.Removed.Contains(i)) { before++; continue; }
                var j = i - before;
                var f0 = FrameOf(i);
                var f1 = FrameOf(j);
                var f = new Rect(f0.X + (f1.X - f0.X) * e, f0.Y + (f1.Y - f0.Y) * e, side, side);
                if (f.Y + f.Height < 0 || f.Y > cfg.Height) continue;
                output.Add(MakeTile(f, j, d.OldItems[i], 1.0));
            }
        }
        if (t >= 1.0) FinishDeletion();
    }

    readonly List<GridTile> _nearbyScratch = [];

    public void NearbyKeys(double screens, List<int> keysOut)
    {
        keysOut.Clear();
        var r = Engine.Rest;
        var h = Engine.Cfg.Height;
        _nearbyScratch.Clear();
        for (var k = -screens; k <= screens; k += 1.0)
        {
            if (Math.Abs(k) < 0.01) continue;
            r.Offset = Engine.Rest.Offset + k * h;
            Engine.RestTiles(r, _nearbyScratch);
        }
        foreach (var t in _nearbyScratch) keysOut.Add(t.Photo);
    }
}
