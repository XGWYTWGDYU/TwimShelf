// GPU-accelerated zoomable media grid for WinUI 3 (Direct3D 11 SwapChainPanel + transparent
// ScrollViewer overlay), sharing the exact Photos zoom engine with Apple and Web/Electron.
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using TwimShelf.Services;
using Windows.Foundation;
using Windows.UI;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace TwimShelf.Controls.ZoomGrid;

public sealed partial class ZoomGridView : UserControl, IDisposable
{
    const double FooterHeight = 52.0;

    readonly SwapChainPanel _panel;
    readonly ScrollViewer _scroll;
    readonly Canvas _spacer;
    readonly TextBlock _footer;
    readonly DispatcherQueue _ui;
    readonly DispatcherQueueTimer _pinchReleaseTimer;

    GridRenderer? _renderer;
    GridScene? _scene;
    List<ZoomGridTile>? _pendingTiles;
    readonly List<GridTile> _drawn = [];
    readonly List<int> _prefetchKeys = [];

    bool _renderingHooked;
    bool _loaded;
    bool _active = true;
    bool _coveredByViewer;
    bool _needsDraw = true;
    bool _syncingScroll;
    bool _disposed;
    int _loadSignalPending;
    double _lastPrefetch = double.NaN;
    double _insetTop = FloatingBar.Space;

    public int InitialLevel { get; set; } = 1;
    public int Level => _scene?.Engine.Rest.Level ?? InitialLevel;
    public int EffectiveLevel => _step?.TargetLevel ?? _scene?.Engine.Zoom?.Target ?? Level;
    public int LevelCount => _scene?.Engine.Cfg.Levels ?? 3;
    public bool CanZoomIn => EffectiveLevel < LevelCount - 1;
    public bool CanZoomOut => EffectiveLevel > 0;
    public IReadOnlyList<ZoomGridTile> Tiles => (IReadOnlyList<ZoomGridTile>?)_scene?.Tiles ?? _pendingTiles ?? [];

    bool _selecting;
    public bool Selecting
    {
        get => _selecting;
        set
        {
            if (_selecting == value) return;
            _selecting = value;
            if (!value) _selected.Clear();
            if (_scene != null)
            {
                _scene.Selecting = value;
                _scene.Selected = _selected;
            }
            _needsDraw = true;
        }
    }

    readonly HashSet<string> _selected = [];
    public IReadOnlySet<string> Selected => _selected;

    public event Action<int>? TileOpened;
    public event Action<FeedItem>? TileUnfavoriteRequested;
    public event Action<int, Point>? TileContextRequested;
    public event Action? SelectionChanged;
    public event Action<int>? SettledAtLevel;
    public event Action? ZoomStateChanged;

    // Continuous pinch (Precision Touchpad Ctrl+wheel or touchscreen)
    bool _pinching;
    double _pinchScale = 1.0;
    double _pinchVelocity;
    readonly List<(double T, double S)> _pinchSamples = [];

    // Animated 1-level step zoom (toolbar buttons, Ctrl +/-, discrete mouse Ctrl+wheel)
    sealed class StepAnim
    {
        public double FromScale;
        public double ToScale;
        public double Start;
        public Point Finger;
        public int TargetLevel;
    }
    StepAnim? _step;

    // Click & drag-select
    int? _dragStart;
    Point _dragStartPt;
    bool _dragSelects = true;
    HashSet<string> _dragBase = [];
    bool _dragged;

    public ZoomGridView(double insetTop = FloatingBar.Space)
    {
        _insetTop = insetTop;
        _ui = DispatcherQueue;
        _pinchReleaseTimer = _ui.CreateTimer();
        _pinchReleaseTimer.Interval = TimeSpan.FromMilliseconds(85);
        _pinchReleaseTimer.IsRepeating = false;
        _pinchReleaseTimer.Tick += (_, _) => EndWheelPinch();

        _panel = new SwapChainPanel { IsHitTestVisible = false };
        _panel.SizeChanged += (_, _) => OnLayoutChanged();
        _panel.CompositionScaleChanged += (_, _) => OnLayoutChanged();

        _footer = new TextBlock
        {
            FontSize = 12,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextAlignment = TextAlignment.Center,
            IsHitTestVisible = false,
        };

        _spacer = new Canvas
        {
            Background = new SolidColorBrush(Colors.Transparent),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Top,
            ManipulationMode = ManipulationModes.Scale | ManipulationModes.System,
        };
        _spacer.Children.Add(_footer);
        _spacer.PointerPressed += OnSpacerPointerPressed;
        _spacer.PointerMoved += OnSpacerPointerMoved;
        _spacer.PointerReleased += OnSpacerPointerReleased;
        _spacer.PointerCanceled += (_, _) => _dragStart = null;
        _spacer.RightTapped += OnSpacerRightTapped;
        _spacer.ManipulationStarted += OnTouchManipulationStarted;
        _spacer.ManipulationDelta += OnTouchManipulationDelta;
        _spacer.ManipulationCompleted += OnTouchManipulationCompleted;

        _scroll = new ScrollViewer
        {
            Content = _spacer,
            Background = new SolidColorBrush(Colors.Transparent),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollMode = ScrollMode.Auto,
            HorizontalScrollMode = ScrollMode.Disabled,
            ZoomMode = ZoomMode.Disabled,
        };
        _scroll.ViewChanged += OnScrollViewChanged;
        _scroll.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(OnWheel), handledEventsToo: true);

        Content = new Microsoft.UI.Xaml.Controls.Grid { Children = { _panel, _scroll } };

        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
        ActualThemeChanged += (_, _) => { ApplyThemeColors(); _needsDraw = true; };
    }

    // ---- Lifecycle ----

    void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_disposed) return;
        _loaded = true;
        EnsureRenderer();
        ApplyThemeColors();
        OnLayoutChanged();
        if (_active && !_renderingHooked)
        {
            CompositionTarget.Rendering += OnRendering;
            _renderingHooked = true;
        }
        _needsDraw = true;
    }

    void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _loaded = false;
        if (_renderingHooked)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }
        _pinchReleaseTimer.Stop();
    }

    /// Pauses or resumes the vsync render loop while this grid stays cached in the visual tree.
    public void SetActive(bool active)
    {
        if (_disposed || _active == active) return;
        _active = active;
        if (active)
        {
            if (_loaded)
            {
                EnsureRenderer();
                ApplyThemeColors();
                OnLayoutChanged();
                if (!_renderingHooked)
                {
                    CompositionTarget.Rendering += OnRendering;
                    _renderingHooked = true;
                }
            }
            _needsDraw = true;
        }
        else
        {
            if (_renderingHooked)
            {
                CompositionTarget.Rendering -= OnRendering;
                _renderingHooked = false;
            }
            _pinchReleaseTimer.Stop();
        }
    }

    void EnsureRenderer()
    {
        if (_renderer != null || _disposed) return;
        try
        {
            _renderer = new GridRenderer(_panel);
            _renderer.Thumbnails.Loaded += SignalTextureLoaded;
            ApplyThemeColors();
        }
        catch (Exception ex)
        {
            Diagnostics.Log("ZoomGridView D3D11 init failed: " + ex);
        }
    }

    void SignalTextureLoaded()
    {
        if (_disposed) return;
        if (Interlocked.Exchange(ref _loadSignalPending, 1) == 0)
        {
            _ui.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref _loadSignalPending, 0);
                _needsDraw = true;
            });
        }
    }

    void ApplyThemeColors()
    {
        if (_renderer == null) return;
        var dark = ActualTheme == ElementTheme.Dark;
        if (dark)
        {
            _renderer.PlaceholderR = 0.17f;
            _renderer.PlaceholderG = 0.17f;
            _renderer.PlaceholderB = 0.19f;
        }
        else
        {
            _renderer.PlaceholderR = 0.90f;
            _renderer.PlaceholderG = 0.90f;
            _renderer.PlaceholderB = 0.92f;
        }
        if (Application.Current.Resources.TryGetValue("SystemAccentColor", out var obj) && obj is Color c)
        {
            _renderer.AccentR = c.R / 255f;
            _renderer.AccentG = c.G / 255f;
            _renderer.AccentB = c.B / 255f;
        }
    }

    // ---- Public API ----

    public void SetTiles(List<ZoomGridTile> tiles, string footer)
    {
        _footer.Text = footer;
        // Warm the small disk thumbnail cache in the background (matching Apple & Electron).
        Thumbnails.Warm(tiles.Where(t => !t.Item.IsVideo).Select(t => t.Item.MediaId), Thumbnails.SmallSide);
        _renderer?.Thumbnails.ClearPendingRequests();
        if (_scene == null)
        {
            _pendingTiles = tiles;
            return;
        }
        _scene.SetTiles(tiles);
        _lastPrefetch = double.NaN;
        if (_selected.Count > 0)
        {
            var ids = new HashSet<string>(tiles.Count);
            foreach (var t in tiles) ids.Add(t.Item.MediaId);
            if (_selected.RemoveWhere(id => !ids.Contains(id)) > 0)
                SelectionChanged?.Invoke();
        }
        _needsDraw = true;
    }

    public void SelectAll(bool on)
    {
        _selected.Clear();
        if (on)
            foreach (var t in Tiles) _selected.Add(t.Item.MediaId);
        if (_scene != null) _scene.Selected = _selected;
        _needsDraw = true;
        SelectionChanged?.Invoke();
    }

    public void SetSelected(string mediaId, bool on)
    {
        if (on) _selected.Add(mediaId); else _selected.Remove(mediaId);
        if (_scene != null) _scene.Selected = _selected;
        _needsDraw = true;
        SelectionChanged?.Invoke();
    }

    /// Hides or reveals one tile in the GPU grid (used during Viewer zoom flight so the source tile
    /// never duplicates underneath the flying media).
    public void SetHiddenMedia(string? mediaId)
    {
        if (_scene == null) return;
        int? key = string.IsNullOrEmpty(mediaId) ? null : _scene.KeyOfMedia(mediaId);
        if (_scene.Engine.HiddenPhoto == key) return;
        _scene.Engine.HiddenPhoto = key;
        _needsDraw = true;
    }

    /// Hides the underlying SwapChainPanel while the opaque full-screen Viewer covers the grid so
    /// D3D11 SwapChainPresent calls never punch through the overlay during horizontal swipes, and
    /// redraws one synchronized frame immediately when revealed for dismiss/close zoom.
    public void SetCoveredByViewer(bool covered)
    {
        if (_disposed || _coveredByViewer == covered) return;
        _coveredByViewer = covered;
        _panel.Visibility = covered ? Visibility.Collapsed : Visibility.Visible;
        if (!covered)
        {
            _needsDraw = true;
            DrawNow();
        }
    }

    void DrawNow()
    {
        if (_disposed || !_active || _coveredByViewer || _scene == null || _renderer == null || !_renderer.IsReady) return;
        SyncScrollOffset();
        var now = GridScene.Now();
        if (_step != null) AdvanceStep(now);
        var wasZooming = _scene.Engine.IsZooming;
        var zoomFinished = _scene.Frame(now, _drawn);
        if (wasZooming && zoomFinished) ZoomDidEnd();
        var cfg = _scene.Engine.Cfg;
        var moreUploads = _renderer.Draw(_drawn, cfg.Width, cfg.Height, cfg.Scale, key =>
            _scene.TileByKey(key) is { } tile ? (tile.Item, tile.Count, _scene.IsSelected(key)) : null);
        _needsDraw = moreUploads || _scene.IsAnimating;
    }

    /// Returns the tile's current rect in `relativeTo` coordinates if visible in the grid viewport.
    public Rect? ViewerSourceFrame(string mediaId, UIElement relativeTo)
    {
        if (!IsLoaded || XamlRoot == null || _scene == null) return null;
        var index = _scene.Tiles.FindIndex(t => t.Item.MediaId == mediaId);
        if (index < 0) return null;
        var cfg = _scene.Engine.Cfg;
        if (cfg.Width <= 0 || cfg.Height <= 0) return null;
        var frame = _scene.Engine.RestFrame(index, _scene.Engine.Rest);
        if (frame.X + frame.Width <= 0 || frame.X >= cfg.Width || frame.Y + frame.Height <= 0 || frame.Y >= cfg.Height)
            return null;
        try
        {
            var pt = TransformToVisual(relativeTo).TransformPoint(new Point(frame.X, frame.Y));
            return new Rect(pt.X, pt.Y, frame.Width, frame.Height);
        }
        catch { return null; }
    }

    /// Steps one level in (-1) or out (+1), anchored at `anchor` (or viewport center).
    public void Step(int delta, Point? anchor = null)
    {
        if (_scene == null || _scene.Engine.Items.Length == 0) return;
        var cfg = _scene.Engine.Cfg;
        var now = GridScene.Now();

        // Allow chaining rapid Ctrl+wheel / button steps smoothly (including mid-settle regrab).
        if (_scene.Engine.Zoom is { } z)
        {
            var fromTarget = _step?.TargetLevel ?? z.Target;
            var nextTarget = Math.Clamp(fromTarget - delta, 0, cfg.Levels - 1);
            if (nextTarget == fromTarget) return;
            var ptMid = _step?.Finger ?? anchor ?? new Point(cfg.Width * 0.5, (cfg.Height - cfg.InsetBottom) * 0.5);
            if (!z.Pinching) _scene.Engine.BeginPinch(ptMid, now);
            var currentSide = cfg.DisplaySide(z.LnRaw);
            var baseSide = Math.Exp(z.LnBase);
            _step = new StepAnim
            {
                FromScale = currentSide / baseSide,
                ToScale = cfg.Side(nextTarget) / baseSide,
                Start = now,
                Finger = ptMid,
                TargetLevel = nextTarget,
            };
            _needsDraw = true;
            ZoomStateChanged?.Invoke();
            return;
        }

        if (_scene.IsBusy) return;
        var r = _scene.Engine.Rest;
        var target = Math.Clamp(r.Level - delta, 0, cfg.Levels - 1);
        if (target == r.Level) return;

        var pt = anchor ?? new Point(cfg.Width * 0.5, (cfg.Height - cfg.InsetBottom) * 0.5);
        _scene.Engine.Rest.Offset = _scroll.VerticalOffset;
        _scene.Engine.BeginPinch(pt, now);
        BeginZoomUi();
        _step = new StepAnim
        {
            FromScale = 1.0,
            ToScale = cfg.Side(target) / cfg.Side(r.Level),
            Start = now,
            Finger = pt,
            TargetLevel = target,
        };
        _needsDraw = true;
        ZoomStateChanged?.Invoke();
    }

    // ---- Layout & Scroll Sync ----

    GridConfig BuildConfig()
    {
        var w = Math.Max(0, _panel.ActualWidth);
        var h = Math.Max(0, _panel.ActualHeight);
        var scale = Math.Max(1.0, _panel.CompositionScaleX > 0 ? _panel.CompositionScaleX : (XamlRoot?.RasterizationScale ?? 1.0));
        double? winW = MainWindow.Current?.Bounds.Width is > 0 and var bw ? bw : null;
        var cfg = new GridConfig(w, h, scale, _insetTop, FooterHeight, 0)
        {
            Columns = GridConfig.ColumnsForWidth(w, winW),
            Exactness = 1.0,
        };
        return cfg;
    }

    void OnLayoutChanged()
    {
        if (_disposed) return;
        var w = _panel.ActualWidth;
        var h = _panel.ActualHeight;
        if (w <= 0 || h <= 0) return;

        var sx = _panel.CompositionScaleX > 0 ? _panel.CompositionScaleX : (float)(XamlRoot?.RasterizationScale ?? 1.0);
        var sy = _panel.CompositionScaleY > 0 ? _panel.CompositionScaleY : sx;
        EnsureRenderer();
        _renderer?.Resize(w, h, sx, sy);

        _spacer.Width = w;
        _footer.Width = w;

        var cfg = BuildConfig();
        if (_scene == null)
        {
            var s = new GridScene(cfg, InitialLevel);
            s.RestChanged += ApplyRestToScroll;
            s.ContentHeightChanged += UpdateContentHeight;
            s.Selecting = _selecting;
            s.Selected = _selected;
            _scene = s;
            if (_pendingTiles != null)
            {
                var t = _pendingTiles;
                _pendingTiles = null;
                s.SetTiles(t);
            }
            ApplyRestToScroll();
        }
        else if (!_scene.Engine.Cfg.GeometryEquals(in cfg))
        {
            _scene.SetConfig(cfg);
            _lastPrefetch = double.NaN;
        }
        _needsDraw = true;
    }

    void ApplyRestToScroll()
    {
        if (_scene == null) return;
        var cfg = _scene.Engine.Cfg;
        var r = _scene.Engine.Rest;
        var h = cfg.ContentHeight(r.Level, r.Phase);
        _syncingScroll = true;
        _spacer.Height = Math.Max(cfg.Height, cfg.InsetTop + Math.Max(h, 1.0) + cfg.InsetBottom);
        Canvas.SetTop(_footer, cfg.InsetTop + h + 14.0);
        // Ensure ScrollViewer knows the updated ScrollableHeight before seeking to r.Offset.
        _scroll.UpdateLayout();
        _scroll.ChangeView(null, r.Offset, null, disableAnimation: true);
        _ui.TryEnqueue(DispatcherQueuePriority.Normal, () => _syncingScroll = false);
        _needsDraw = true;
    }

    void UpdateContentHeight()
    {
        if (_scene == null) return;
        var cfg = _scene.Engine.Cfg;
        var r = _scene.Engine.Rest;
        var h = cfg.ContentHeight(r.Level, r.Phase);
        _syncingScroll = true;
        _spacer.Height = Math.Max(cfg.Height, cfg.InsetTop + Math.Max(h, 1.0) + cfg.InsetBottom);
        Canvas.SetTop(_footer, cfg.InsetTop + h + 14.0);
        _scroll.UpdateLayout();
        var maxOffset = cfg.MaxOffset(r.Level, r.Phase);
        if (r.Offset > maxOffset + 0.5)
            _scroll.ChangeView(null, maxOffset, null, disableAnimation: false);
        _ui.TryEnqueue(DispatcherQueuePriority.Normal, () => _syncingScroll = false);
        _needsDraw = true;
    }

    void OnScrollViewChanged(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (_scene == null || _syncingScroll) return;
        if (_scene.Engine.IsZooming)
        {
            if (!(_scene.Engine.Zoom?.Pinching ?? false))
            {
                if (_scene.FinishZoomNow()) ZoomDidEnd();
            }
            return;
        }
        SyncScrollOffset();
    }

    void SyncScrollOffset()
    {
        if (_scene == null || _syncingScroll || _scene.Engine.IsZooming) return;
        var y = _scroll.VerticalOffset;
        if (Math.Abs(y - _scene.Engine.Rest.Offset) < 0.01) return;
        _scene.Engine.Rest.Offset = y;
        _scene.RealignBeforeTopShows();
        if (_scene.Engine.Rest.Offset <= 0.5) _scene.RealignToTop();
        _needsDraw = true;
    }

    // ---- Per-VSync Render Loop ----

    void OnRendering(object? sender, object e)
    {
        if (_disposed || !_active || _coveredByViewer || _scene == null || _renderer == null || !_renderer.IsReady) return;

        // Pull latest ScrollViewer offset directly on vsync so scrolling is locked with zero lag.
        SyncScrollOffset();

        var now = GridScene.Now();
        if (_step != null) AdvanceStep(now);

        if (!_scene.IsAnimating && !_needsDraw) return;

        var wasZooming = _scene.Engine.IsZooming;
        var zoomFinished = _scene.Frame(now, _drawn);
        if (wasZooming && zoomFinished) ZoomDidEnd();

        var cfg = _scene.Engine.Cfg;
        var moreUploads = _renderer.Draw(_drawn, cfg.Width, cfg.Height, cfg.Scale, key =>
            _scene.TileByKey(key) is { } tile ? (tile.Item, tile.Count, _scene.IsSelected(key)) : null);

        _needsDraw = moreUploads || _scene.IsAnimating;
        Prefetch();
    }

    void AdvanceStep(double now)
    {
        if (_step is not { } st || _scene == null) return;
        var t = Math.Min(1.0, (now - st.Start) / 0.30);
        var e = 1.0 - Math.Pow(1.0 - t, 3.0);
        var scale = st.FromScale * Math.Pow(st.ToScale / st.FromScale, e);
        _scene.Engine.PinchChanged(scale, st.Finger);
        if (t >= 1.0)
        {
            var finalScale = st.ToScale;
            _step = null;
            _scene.Engine.Release(0.0, finalScale);
        }
    }

    void Prefetch()
    {
        if (_scene == null || _renderer == null || _scene.IsAnimating) return;
        var r = _scene.Engine.Rest;
        var cfg = _scene.Engine.Cfg;
        if (!double.IsNaN(_lastPrefetch) && Math.Abs(r.Offset - _lastPrefetch) <= cfg.Height / 3.0) return;
        _lastPrefetch = r.Offset;
        var px = cfg.Side(r.Level) * cfg.Scale;
        _scene.NearbyKeys(2.0, _prefetchKeys);
        foreach (var k in _prefetchKeys)
        {
            if (_scene.TileByKey(k) is { } t)
                _renderer.Thumbnails.TextureFor(t.Item, px, prefetch: true);
        }
    }

    void BeginZoomUi() => _footer.Opacity = 0;

    void ZoomDidEnd()
    {
        _footer.Opacity = 1;
        _pinching = false;
        _step = null;
        OnLayoutChanged();
        SettledAtLevel?.Invoke(Level);
    }

    // ---- Wheel / Precision Touchpad Pinch ----

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (_scene == null) return;
        var ctrl = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control);
        if (!ctrl)
        {
            if (_scene.Engine.IsZooming && !(_scene.Engine.Zoom?.Pinching ?? false))
            {
                if (_scene.FinishZoomNow()) ZoomDidEnd();
            }
            else if (_scene.Engine.IsZooming || _step != null)
            {
                e.Handled = true;
            }
            return;
        }

        e.Handled = true;
        if (_scene.Engine.Items.Length == 0) return;

        var cp = e.GetCurrentPoint(this);
        var delta = cp.Properties.MouseWheelDelta;
        if (delta == 0) return;
        var pt = cp.Position;

        // Discrete mouse wheel notches (±120) step smoothly anchored under the cursor;
        // Precision Touchpad pinch sends fine-grained deltas and drives continuous 1:1 pinch.
        if (!_pinching && Math.Abs(delta) >= 120 && delta % 120 == 0)
        {
            Step(delta > 0 ? -1 : 1, anchor: pt);
            return;
        }

        var now = GridScene.Now();
        if (!_pinching)
        {
            _step = null;
            if (!_scene.Engine.IsZooming) _scene.Engine.Rest.Offset = _scroll.VerticalOffset;
            _pinching = true;
            _pinchScale = 1.0;
            _pinchVelocity = 0.0;
            _pinchSamples.Clear();
            _pinchSamples.Add((now, 1.0));
            _scene.Engine.BeginPinch(pt, now);
            BeginZoomUi();
        }
        if (!(_scene.Engine.Zoom?.Pinching ?? false)) return;

        _pinchScale *= Math.Exp(delta * 0.0045);
        _pinchSamples.Add((now, _pinchScale));
        while (_pinchSamples.Count > 1 && now - _pinchSamples[0].T > 0.12)
            _pinchSamples.RemoveAt(0);
        var first = _pinchSamples[0];
        _pinchVelocity = now - first.T > 0.01 ? (_pinchScale - first.S) / (now - first.T) : 0.0;
        _scene.Engine.PinchChanged(_pinchScale, pt);
        _needsDraw = true;

        _pinchReleaseTimer.Stop();
        _pinchReleaseTimer.Start();
    }

    void EndWheelPinch()
    {
        if (!_pinching) return;
        _pinching = false;
        if (_scene?.Engine.Zoom?.Pinching == true)
        {
            _scene.Engine.Release(_pinchVelocity, _pinchScale);
            _needsDraw = true;
        }
    }

    // ---- Touchscreen Pinch ----

    void OnTouchManipulationStarted(object sender, ManipulationStartedRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _scene == null || _scene.Engine.Items.Length == 0) return;
        _pinching = false;
    }

    void OnTouchManipulationDelta(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _scene == null || _scene.Engine.Items.Length == 0) return;
        if (!_pinching && Math.Abs(e.Cumulative.Scale - 1.0) < 0.01) return;

        var pt = _spacer.TransformToVisual(this).TransformPoint(e.Position);
        var now = GridScene.Now();
        if (!_pinching)
        {
            _step = null;
            if (!_scene.Engine.IsZooming) _scene.Engine.Rest.Offset = _scroll.VerticalOffset;
            _pinching = true;
            _pinchScale = 1.0;
            _pinchVelocity = 0.0;
            _pinchSamples.Clear();
            _pinchSamples.Add((now, 1.0));
            _scene.Engine.BeginPinch(pt, now);
            BeginZoomUi();
        }
        _pinchScale = Math.Max(0.1, e.Cumulative.Scale);
        _pinchSamples.Add((now, _pinchScale));
        while (_pinchSamples.Count > 1 && now - _pinchSamples[0].T > 0.12)
            _pinchSamples.RemoveAt(0);
        var first = _pinchSamples[0];
        _pinchVelocity = now - first.T > 0.01 ? (_pinchScale - first.S) / (now - first.T) : 0.0;
        _scene.Engine.PinchChanged(_pinchScale, pt);
        _needsDraw = true;
        e.Handled = true;
    }

    void OnTouchManipulationCompleted(object sender, ManipulationCompletedRoutedEventArgs e)
    {
        if (!_pinching) return;
        _pinching = false;
        if (_scene?.Engine.Zoom?.Pinching == true)
        {
            _scene.Engine.Release(_pinchVelocity, _pinchScale);
            _needsDraw = true;
        }
    }

    // ---- Clicks, Drag-Select, Right-Click ----

    int? IndexAt(Point viewPoint)
    {
        if (_scene == null || _scene.IsAnimating) return null;
        return _scene.Engine.RestIndex(viewPoint);
    }

    void OnSpacerPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        var cp = e.GetCurrentPoint(this);
        if (!cp.Properties.IsLeftButtonPressed) return;
        _dragged = false;
        _dragStartPt = cp.Position;
        _dragStart = IndexAt(cp.Position);
        _dragBase = [.. _selected];
        if (_dragStart is { } i && _scene?.TileAt(i) is { } tile)
            _dragSelects = !_selected.Contains(tile.Item.MediaId);
        if (_selecting && _dragStart != null)
            _spacer.CapturePointer(e.Pointer);
    }

    void OnSpacerPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (!_selecting || _dragStart is not { } s) return;
        var cp = e.GetCurrentPoint(this);
        if (!cp.Properties.IsLeftButtonPressed) return;
        var j = IndexAt(cp.Position);
        if (j is not { } end) return;
        if (!_dragged && end == s && Math.Abs(cp.Position.X - _dragStartPt.X) < 6 && Math.Abs(cp.Position.Y - _dragStartPt.Y) < 6)
            return;

        _dragged = true;
        _selected.Clear();
        foreach (var id in _dragBase) _selected.Add(id);
        var lo = Math.Min(s, end);
        var hi = Math.Max(s, end);
        for (var k = lo; k <= hi && k < Tiles.Count; k++)
        {
            var id = Tiles[k].Item.MediaId;
            if (_dragSelects) _selected.Add(id); else _selected.Remove(id);
        }
        if (_scene != null) _scene.Selected = _selected;
        _needsDraw = true;
        SelectionChanged?.Invoke();
    }

    void OnSpacerPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        var start = _dragStart;
        _dragStart = null;
        _spacer.ReleasePointerCapture(e.Pointer);
        if (_dragged || start is not { } s) return;

        var pt = e.GetCurrentPoint(this).Position;
        if (IndexAt(pt) != s) return;
        if (_selecting)
        {
            if (_scene?.TileAt(s) is not { } tile) return;
            var id = tile.Item.MediaId;
            if (!_selected.Add(id)) _selected.Remove(id);
            if (_scene != null) _scene.Selected = _selected;
            _needsDraw = true;
            SelectionChanged?.Invoke();
        }
        else
        {
            if (_scene?.TileAt(s) is { } tile && tile.Item.Favorite)
            {
                var frame = _scene.Engine.RestFrame(s, _scene.Engine.Rest);
                var lx = pt.X - frame.X;
                var ly = pt.Y - frame.Y;
                if (frame.Width >= 40 && lx >= 0 && lx <= 30 && ly >= frame.Height - 30 && ly <= frame.Height)
                {
                    TileUnfavoriteRequested?.Invoke(tile.Item);
                    return;
                }
            }
            TileOpened?.Invoke(s);
        }
    }

    void OnSpacerRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var pt = e.GetPosition(this);
        if (IndexAt(pt) is not { } i) return;
        TileContextRequested?.Invoke(i, pt);
        e.Handled = true;
    }

    // ---- Dispose ----

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_renderingHooked)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }
        _pinchReleaseTimer.Stop();
        if (_renderer != null)
        {
            _renderer.Thumbnails.Loaded -= SignalTextureLoaded;
            _renderer.Thumbnails.ClearPendingRequests();
            _renderer.Dispose();
            _renderer = null;
        }
    }
}
