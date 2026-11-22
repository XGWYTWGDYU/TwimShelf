// Unified full-screen media viewer (modeled after Apple WWDC24 10145 fluid zoom transitions,
// MacPhotoView/MacPlayerView, Web Viewer/Player, and Flutter ViewerPage):
//  * GPU-composited spring zoom transitions using WinUI 3 UIElement.Scale/Translation (layout-safe)
//    + CompositionGeometricClip rounded-rect morph + separate backdrop fade + hidden source tile/card
//    sync (early unhide at m <= 0.14 to eliminate 1-frame flash).
//  * Interactive drag-to-dismiss (downward drag or touch side-edge swipe on photos & videos):
//    hides neighbor pages so adjacent items NEVER move with P1, anchors P1 under the pointer while
//    shrinking into a rounded floating card over the revealed Grid/Browse page, and launches a
//    velocity-preserving 2D spring directly into the source tile/card on release (or springs back).
//  * 3-page horizontal strip (current + preloaded neighbours, 40px gap) with vsync-driven ease-out
//    sliding, edge bounce, 1:1 trackpad/touch swipe with velocity settle, and cross-post caption fade.
//  * Unified photo & video experience: cursor-anchored 1×–8× photo zoom, animated double-click
//    1× <-> 2.5× zoom, seamless InlineVideo single-player handover, press-and-hold 2.5× video
//    boost, scrubbable progress bar, persisted volume, fullscreen (F/F11), expandable post caption.
using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls.ViewerEngine;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using Windows.Foundation;
using Windows.Media.Playback;
using static TwimShelf.Services.Strings;
using VirtualKey = Windows.System.VirtualKey;
using VirtualKeyModifiers = Windows.System.VirtualKeyModifiers;

namespace TwimShelf.Controls;

public sealed class ViewerOpenOptions
{
    public Place? Place { get; init; }
    /// Resolves `item`'s current rect in `MainWindow.Current.Content` coordinates (null if off-screen).
    public Func<FeedItem, Rect?>? SourceRect { get; init; }
    /// Notifies the underlying Grid or Browse page which `mediaId` is currently displayed (null when closed).
    public Action<string?>? ActiveMediaChanged { get; init; }
    /// Optional hook called right before measuring the close target (e.g., sync a visible multi-media Browse card's page).
    public Action<FeedItem>? SyncBeforeClose { get; init; }
    public double SourceCornerRadius { get; init; }
    /// True when the source crops the media to fill its rect (a square grid tile).
    public bool CropSource { get; init; }
    /// Optional already-decoded ImageSource from a Browse card for instant Frame-0 display.
    public Func<FeedItem, ImageSource?>? PreviewImage { get; init; }
    /// Optional cached square thumbnail path from the Grid for pixel-accurate Frame-0 display.
    public Func<FeedItem, string?>? SquarePreviewPath { get; init; }
}

public sealed partial class Viewer : UserControl
{
    static Viewer? _open;
    public static bool IsOpen => _open != null;
    public static Viewer? Shown => _open;
    public static event Action? Opened;
    public static event Action? Closed;

    readonly List<FeedItem> _items;
    readonly ViewerOpenOptions _options;
    int _index;
    readonly int _startIndex;

    // Two-node GPU composition hierarchy (invariant depth so pages never remount):
    //   _backdrop  -> black scrim behind the flying media
    //   _surface   -> UIElement.Scale & UIElement.Translation (never overwritten by XAML layout!)
    //     _clipHost -> CompositionVisual.Clip (rounded-rect clip in strict local 0..W, 0..H coords)
    //       _strip  -> 3-page Canvas (neighbors collapsed during transition & dismiss drag!)
    //   _chromeLayer -> top counter, side arrows, bottom shade/caption/controls
    readonly Grid _rootGrid = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Border _backdrop = new() { Background = new SolidColorBrush(Colors.Black), Opacity = 0, IsHitTestVisible = false };
    readonly Grid _surface = new() { Background = new SolidColorBrush(Colors.Transparent), CenterPoint = Vector3.Zero };
    readonly Grid _clipHost = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Canvas _strip = new()
    {
        Background = new SolidColorBrush(Colors.Transparent),
        // Scale only: keeps two-finger touch pinch in ManipulationDelta while letting ALL
        // single-pointer drags (Mouse, Touch, Pen) flow directly through PointerPressed/Moved/Released
        // without WinUI canceling mouse/touch pointer capture!
        ManipulationMode = ManipulationModes.Scale,
    };
    readonly Grid _chromeLayer = new() { Opacity = 0 };

    // Top chrome: window drag strip + counter
    readonly Grid _top;
    readonly Border _drag = new() { Background = new SolidColorBrush(Colors.Transparent), Margin = new Thickness(90, 0, 0, 0) };
    readonly TextBlock _counter = new()
    {
        Foreground = new SolidColorBrush(Colors.White),
        FontSize = 13,
        FontWeight = FontWeights.SemiBold,
        VerticalAlignment = VerticalAlignment.Center,
        Margin = new Thickness(20, 0, 0, 0),
        IsHitTestVisible = false,
    };

    // Navigation arrows
    readonly Button _prev, _next;

    // Bottom chrome: shade + expandable caption + video bar / photo action buttons
    readonly Grid _bottom;
    readonly ViewerCaption _caption = new() { Margin = new Thickness(0, 0, 0, 8) };
    readonly Grid _videoRow = new() { ColumnSpacing = 8 };
    readonly Button _play, _speed, _mute, _videoShare, _videoFull, _videoClose;
    readonly TextBlock _at = TimeText(), _length = TimeText();
    readonly Slider _position = new()
    {
        Minimum = 0,
        Maximum = 1,
        StepFrequency = 0.0005,
        IsThumbToolTipEnabled = false,
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly StackPanel _photoActions = new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 4,
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly Button _photoShare, _photoFull, _photoClose;

    // 3-page strip state
    readonly Dictionary<int, FrameworkElement> _pages = [];
    double _viewW, _viewH;
    double _stripOffset;
    double Stride => ViewerMath.Stride(_viewW);

    sealed class StripMotion
    {
        public double From, To, Start, Duration;
        public Action? Done;
    }
    StripMotion? _stripMotion;

    // Fluid spring zoom flight state
    ZoomFlight? _flight;
    double _lastTickTime;
    double _flightCreateTime;
    bool _flightPrimed; // Waits up to 80ms for Frame-0 preview pixels before launching spring
    bool _sourceHidden;
    bool _unhiddenForClose;
    bool _closing;
    bool _enteredFullScreen;

    Visual? _clipVisual;
    CompositionRoundedRectangleGeometry? _clipGeo;
    CompositionGeometricClip? _clip;

    // Interactive dismiss drag & velocity-preserving spring-back state
    DismissState _dismiss = DismissState.None;
    bool _dismissFromEdge;
    int _dismissEdgeDir = 1;
    Point _dismissGrabPt;
    Rect _dismissMedia;
    double _dismissRawX, _dismissRawY;
    readonly List<(double T, double Dx, double Dy)> _dismissSamples = [];

    sealed class SpringBackState
    {
        public Spring1D CenterX, CenterY, Scale, CornerRadius, Progress;
    }
    SpringBackState? _springBack;

    // Wheel & trackpad horizontal swipe state
    readonly ViewerWheelRouter _wheelRouter = new();
    bool _wheelSwiping;
    double _wheelPendingX;
    readonly List<(double T, double Dx)> _wheelSamples = [];
    DispatcherQueueTimer? _wheelEndTimer;

    // Single-pointer drag (Mouse, Touch, Pen) + two-finger pinch state on _strip
    uint? _dragPointerId;
    PointerDeviceType _dragPointerType;
    Point _dragDownPt;
    Point _dragLastPt;
    bool _dragMoved;
    bool _pointerHeldVideo;
    bool _pinchingPhoto;
    DispatcherQueueTimer? _singleClickTimer;

    enum GestureMode { None, Pan, Swipe, Dismiss }
    GestureMode _dragGesture;

    // Chrome visibility & video auto-hide
    bool _chromeHidden;
    bool _videoIdle;
    bool _pointerOverControls;
    bool _settingPosition;
    bool _scrubbing;
    DispatcherQueueTimer? _hideTimer;

    // Lent player from Browse card
    MediaPlayer? _lent;
    readonly string? _lentPath;

    // Host & focus restoration
    Panel? _host;
    Control? _returnFocus;
    bool _renderingHooked;

    public static void Open(List<FeedItem> items, int index, Place? place = null) =>
        Open(items, index, new ViewerOpenOptions { Place = place });

    public static void Open(List<FeedItem> items, int index, ViewerOpenOptions? options)
    {
        if (_open != null || items.Count == 0 || MainWindow.Current?.Content is not Panel root) return;
        var opts = options ?? new ViewerOpenOptions();
        var clamped = Math.Clamp(index, 0, items.Count - 1);
        var first = items[clamped];

        // Adopt the playing Browse card's live MediaPlayer before stopping other cards.
        var lent = first.IsVideo ? InlineVideo.Lend(first.Path) : null;
        InlineVideo.StopAll(exceptPath: first.IsVideo ? first.Path : null);

        var v = new Viewer(items, clamped, opts, lent, first.Path);
        Grid.SetRowSpan(v, 2);
        v._returnFocus = FocusManager.GetFocusedElement(root.XamlRoot) as Control;
        v._host = root;
        _open = v;
        root.Children.Add(v);

        MainWindow.Current.SetTitleBar(v._drag);
        MainWindow.Current.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
        Opened?.Invoke();
    }

    Viewer(List<FeedItem> items, int index, ViewerOpenOptions options, MediaPlayer? lent, string? lentPath)
    {
        _items = items;
        _index = index;
        _startIndex = index;
        _options = options;
        _lent = lent;
        _lentPath = lentPath;
        RequestedTheme = ElementTheme.Dark;

        IsTabStop = true;
        UseSystemFocusVisuals = false;

        // Top bar (window drag + counter)
        _top = new Grid { Height = 48, VerticalAlignment = VerticalAlignment.Top, Background = Fade(true) };
        _top.Children.Add(_drag);
        _top.Children.Add(_counter);

        // Prev / Next Fluent 2 vertical rounded-rectangle navigation buttons (Windows 11 Photos style)
        _prev = NavButton("\uE76B", L("viewer.previous"), () => Step(-1), "viewerPrev");
        _prev.HorizontalAlignment = HorizontalAlignment.Left;
        _prev.VerticalAlignment = VerticalAlignment.Center;
        _prev.Margin = new Thickness(16);

        _next = NavButton("\uE76C", L("viewer.next"), () => Step(1), "viewerNext");
        _next.HorizontalAlignment = HorizontalAlignment.Right;
        _next.VerticalAlignment = VerticalAlignment.Center;
        _next.Margin = new Thickness(16);

        // Video controls row
        _play = IconButton("\uE768", L("viewer.play"), () => ActiveVideo?.TogglePlay(showHud: false), "videoPlay");
        _speed = new Button
        {
            Content = new TextBlock
            {
                Text = FormatSpeed(ViewerVideoPage.SavedRate),
                Foreground = new SolidColorBrush(Colors.White),
                FontSize = 13,
                FontWeight = FontWeights.SemiBold,
            },
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            MinWidth = 44,
            Height = 36,
            Padding = new Thickness(8, 0, 8, 0),
            CornerRadius = new CornerRadius(6),
        };
        ApplySubtleResources(_speed);
        ToolTipService.SetToolTip(_speed, L("player.speed"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_speed, L("player.speed"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_speed, "videoSpeed");
        _speed.Flyout = SpeedMenu();

        _mute = IconButton("\uE767", L("audio.turnOn"), () => ActiveVideo?.ToggleMute(), "videoMute");
        _videoShare = IconButton("\uE72D", L("viewer.share"), () => { }, "viewerShare");
        _videoShare.Flyout = ShareMenu.For(() => Current);
        _videoFull = IconButton("\uE740", "F", ToggleFullscreen, "viewerFullscreen");
        _videoClose = IconButton("\uE711", L("viewer.close"), () => Close(), "videoClose");

        _position.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _scrubbing = true), true);
        _position.AddHandler(PointerReleasedEvent, new PointerEventHandler((_, _) => _scrubbing = false), true);
        _position.AddHandler(PointerCaptureLostEvent, new PointerEventHandler((_, _) => _scrubbing = false), true);
        _position.ValueChanged += (_, e) =>
        {
            if (!_settingPosition && ActiveVideo is { } vp)
            {
                vp.SeekToFraction(e.NewValue);
                WakeVideoChrome();
            }
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_position, L("windows.viewer.position"));

        UIElement[] row = [_play, _at, _position, _length, _speed, _mute, _videoShare, _videoFull, _videoClose];
        for (var i = 0; i < row.Length; i++)
        {
            _videoRow.ColumnDefinitions.Add(new ColumnDefinition
            {
                Width = row[i] == _position ? new GridLength(1, GridUnitType.Star) : GridLength.Auto,
            });
            Grid.SetColumn((FrameworkElement)row[i], i);
            _videoRow.Children.Add(row[i]);
        }

        // Photo action buttons: unified Fluent 2 Subtle icon buttons (matching video controls)
        _photoShare = IconButton("\uE72D", L("viewer.share"), () => { }, "photoShare");
        _photoShare.Flyout = ShareMenu.For(() => Current);
        _photoFull = IconButton("\uE740", "F", ToggleFullscreen, "photoFullscreen");
        _photoClose = IconButton("\uE711", L("viewer.close"), () => Close(), "photoClose");
        _photoActions.Children.Add(_photoShare);
        _photoActions.Children.Add(_photoFull);
        _photoActions.Children.Add(_photoClose);

        // Bottom shade containing caption + video bar / photo actions
        _bottom = new Grid
        {
            Padding = new Thickness(20, 44, 20, 14),
            VerticalAlignment = VerticalAlignment.Bottom,
            Background = Fade(false),
        };
        _bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bottom.Children.Add(_caption);
        Grid.SetRow(_videoRow, 1);
        _bottom.Children.Add(_videoRow);
        Grid.SetRow(_photoActions, 1);
        _bottom.Children.Add(_photoActions);
        _bottom.PointerEntered += (_, _) => { _pointerOverControls = true; WakeVideoChrome(); };
        _bottom.PointerExited += (_, _) => { _pointerOverControls = false; WakeVideoChrome(); };
        _bottom.PointerPressed += (_, e) => e.Handled = true;

        _chromeLayer.Children.Add(_top);
        _chromeLayer.Children.Add(_prev);
        _chromeLayer.Children.Add(_next);
        _chromeLayer.Children.Add(_bottom);

        _clipHost.Children.Add(_strip);
        _surface.Children.Add(_clipHost);
        _surface.Opacity = 0; // Revealed on Frame 0 once composition transform/clip is applied.

        _rootGrid.Children.Add(_backdrop);
        _rootGrid.Children.Add(_surface);
        _rootGrid.Children.Add(_chromeLayer);
        Content = _rootGrid;

        // Wire events
        _strip.PointerPressed += OnStripPointerPressed;
        _strip.PointerMoved += OnStripPointerMoved;
        _strip.PointerReleased += OnStripPointerReleased;
        _strip.PointerCanceled += OnStripPointerCanceled;
        _strip.DoubleTapped += OnStripDoubleTapped;
        _strip.ManipulationStarted += OnStripManipulationStarted;
        _strip.ManipulationDelta += OnStripManipulationDelta;
        _strip.ManipulationCompleted += OnStripManipulationCompleted;

        PointerWheelChanged += OnWheel;
        PointerMoved += (_, _) => { if (Current.IsVideo) WakeVideoChrome(); };
        KeyDown += OnKey;
        RightTapped += (_, e) =>
        {
            if (_closing) return;
            MediaActions.Menu(Current, _options.Place).ShowAt(this, e.GetPosition(this));
            e.Handled = true;
        };

        var esc = new KeyboardAccelerator { Key = VirtualKey.Escape };
        esc.Invoked += (_, e) => { Close(); e.Handled = true; };
        KeyboardAccelerators.Add(esc);
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;

        SizeChanged += OnViewerSizeChanged;
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    FeedItem Current => _items[_index];
    ViewerPhotoPage? ActivePhoto => _pages.TryGetValue(_index, out var el) ? el as ViewerPhotoPage : null;
    ViewerVideoPage? ActiveVideo => _pages.TryGetValue(_index, out var el) ? el as ViewerVideoPage : null;
    bool IsolatingCurrentPage => _flight != null || _dismiss.IsActive || _springBack != null;

    static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    // ---- Lifecycle & GPU Composition Setup ----

    void OnLoaded(object sender, RoutedEventArgs e)
    {
        _viewW = Math.Max(1, ActualWidth);
        _viewH = Math.Max(1, ActualHeight);
        _caption.SetMaxExpandedHeight(_viewH * 0.45);

        InitComposition();
        EnsurePages();
        ActivateCurrentPage();
        UpdateChrome();
        BeginOpenTransition();

        if (!_renderingHooked)
        {
            _lastTickTime = Now();
            CompositionTarget.Rendering += OnRendering;
            _renderingHooked = true;
        }
        Focus(FocusState.Programmatic);
    }

    void OnUnloaded(object sender, RoutedEventArgs e)
    {
        if (_renderingHooked)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }
        _hideTimer?.Stop();
        _wheelEndTimer?.Stop();
        _singleClickTimer?.Stop();
    }

    void InitComposition()
    {
        if (_clipVisual != null) return;
        _clipVisual = ElementCompositionPreview.GetElementVisual(_clipHost);
        var comp = _clipVisual.Compositor;
        _clipGeo = comp.CreateRoundedRectangleGeometry();
        _clip = comp.CreateGeometricClip(_clipGeo);
        _clipVisual.Clip = _clip;
    }

    void OnViewerSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width <= 0 || e.NewSize.Height <= 0) return;
        _viewW = e.NewSize.Width;
        _viewH = e.NewSize.Height;
        _caption.SetMaxExpandedHeight(_viewH * 0.45);
        LayoutStrip();
        if (_flight == null)
            ApplyTransitionVisual(CurrentRestFrame());
    }

    // ---- Open / Close Fluid Spring Zoom Transitions ----

    Rect ViewportRect => new(0, 0, Math.Max(1, _viewW), Math.Max(1, _viewH));

    Rect CurrentMediaFrame()
    {
        var bounds = ViewportRect;
        if (ActivePhoto is { } photo) return photo.MediaFrame(bounds);
        if (ActiveVideo is { } video) return video.MediaFrame(bounds);
        var item = Current;
        return item.Width > 0 && item.Height > 0
            ? ViewerMath.FitMedia(bounds, item.Width, item.Height)
            : ViewerMath.FitAspect(bounds, item.CardAspectRatio);
    }

    TransitionFrame CurrentRestFrame() =>
        ViewerMath.EvaluateRestOrDismiss(ViewportRect, _dismiss.IsActive || _springBack != null ? _dismissMedia : CurrentMediaFrame(), _dismiss);

    void SyncNeighborVisibility()
    {
        var isolate = IsolatingCurrentPage;
        foreach (var (i, el) in _pages)
        {
            var want = (!isolate || i == _index) ? Visibility.Visible : Visibility.Collapsed;
            if (el.Visibility != want) el.Visibility = want;
        }
    }

    void BeginOpenTransition()
    {
        var source = _options.SourceRect?.Invoke(Current);
        var media = CurrentMediaFrame();
        _flight = ZoomFlight.StartOpen(ViewportRect, media, source, _options.CropSource, _options.SourceCornerRadius);
        _flightCreateTime = Now();
        _flightPrimed = false;
        _sourceHidden = false;
        _unhiddenForClose = false;

        SyncNeighborVisibility();
        var f0 = _flight.CurrentFrame();
        ApplyTransitionVisual(f0);
        // If Frame-0 preview image is still decoding asynchronously (e.g. Grid thumbnail), keep
        // _surface transparent until ready so the real Grid tile stays visible with zero blank flash.
        if (ActivePhoto is { IsPreviewReady: false }) _surface.Opacity = 0;
    }

    public void Close(bool immediate = false) => CloseWithVelocity(immediate, fromDismiss: null, velX: 0, velY: 0);

    void CloseWithVelocity(bool immediate, DismissState? fromDismiss, double velX, double velY)
    {
        if (_host == null) return;
        if (immediate)
        {
            _closing = true;
            FinishClose();
            return;
        }
        if (_closing) return;
        _closing = true;
        _springBack = null;
        _singleClickTimer?.Stop();
        _wheelEndTimer?.Stop();
        _hideTimer?.Stop();
        FinishStripMotion();

        // Keep video playing live (muted, 1×) inside the shrinking zoom card during close!
        ActiveVideo?.PrepareClose();

        // Sync a visible multi-media Browse card's page before measuring SourceRect.
        try { _options.SyncBeforeClose?.Invoke(Current); } catch { }

        var targetSource = _options.SourceRect?.Invoke(Current);

        if (_flight is { Closing: false } activeOpen)
        {
            // Seamless C1 mid-flight reversal: keeps current position & velocity!
            activeOpen.ReverseToClose(targetSource);
        }
        else
        {
            var media = fromDismiss is { IsActive: true } ? _dismissMedia : CurrentMediaFrame();
            _flight = ZoomFlight.StartClose(
                ViewportRect, media, targetSource, _options.CropSource, _options.SourceCornerRadius,
                fromDismiss: fromDismiss, velX: velX, velY: velY);
            _flightPrimed = true; // Close starts moving immediately on the next tick.
            _lastTickTime = Now();
        }
        _unhiddenForClose = false;
        _chromeLayer.IsHitTestVisible = false;
        _strip.IsHitTestVisible = false;
        SyncNeighborVisibility();
        ApplyTransitionVisual(_flight.CurrentFrame());
    }

    void ApplyTransitionVisual(TransitionFrame f)
    {
        _backdrop.Opacity = Math.Clamp(f.BackdropOpacity, 0, 1);
        _surface.Opacity = Math.Clamp(f.SurfaceOpacity, 0, 1);

        var chromeVisible = !_chromeHidden && !(Current.IsVideo && _videoIdle);
        _chromeLayer.Opacity = chromeVisible ? Math.Clamp(f.ChromeOpacity, 0, 1) : 0;

        // UIElement.Scale & UIElement.Translation are native WinUI 3 GPU Composition properties
        // that are NEVER overwritten by XAML layout passes!
        _surface.CenterPoint = Vector3.Zero;
        _surface.Scale = new Vector3((float)f.Scale, (float)f.Scale, 1f);
        _surface.Translation = new Vector3((float)f.OffsetX, (float)f.OffsetY, 0f);

        if (_clipGeo != null && _clip != null && _clipVisual != null)
        {
            if (f.UseClip)
            {
                _clipGeo.Offset = new Vector2((float)f.ClipX, (float)f.ClipY);
                _clipGeo.Size = new Vector2((float)Math.Max(0, f.ClipW), (float)Math.Max(0, f.ClipH));
                var r = (float)Math.Max(0, f.ClipCornerRadius);
                _clipGeo.CornerRadius = new Vector2(r, r);
                if (_clipVisual.Clip != _clip) _clipVisual.Clip = _clip;
            }
            else
            {
                _clipVisual.Clip = null;
            }
        }
    }

    void FinishClose()
    {
        if (_host == null) return;
        if (_renderingHooked)
        {
            CompositionTarget.Rendering -= OnRendering;
            _renderingHooked = false;
        }
        _hideTimer?.Stop();
        _wheelEndTimer?.Stop();
        _singleClickTimer?.Stop();

        if (_enteredFullScreen && MainWindow.Current is { } mw)
        {
            try
            {
                if (mw.AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen)
                    mw.AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
            }
            catch { }
            _enteredFullScreen = false;
        }

        if (_sourceHidden)
        {
            _sourceHidden = false;
            _options.ActiveMediaChanged?.Invoke(null);
        }

        // Remove from visual tree BEFORE returning the MediaPlayer to its Browse card.
        var host = _host;
        _host = null;
        _open = null;
        host.Children.Remove(this);

        foreach (var (i, el) in _pages)
        {
            if (el is ViewerVideoPage vp) vp.Teardown(closing: i == _index);
            else if (el is ViewerPhotoPage pp) pp.Teardown();
        }
        _pages.Clear();
        _strip.Children.Clear();

        if (_lent != null && !string.IsNullOrEmpty(_lentPath))
        {
            var l = _lent;
            _lent = null;
            InlineVideo.Return(l, _lentPath, closing: true);
        }

        if (MainWindow.Current is { } w)
        {
            w.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
            w.RestoreTitleBar();
        }
        try { _returnFocus?.Focus(FocusState.Programmatic); } catch { }
        Closed?.Invoke();
    }

    // ---- Per-VSync Render Loop ----

    void OnRendering(object? sender, object e)
    {
        if (_host == null) return;
        var now = Now();
        var dt = Math.Clamp(now - _lastTickTime, 0.0, 1.0 / 30.0);
        _lastTickTime = now;

        // 1. Fluid Spring Zoom Open / Close Flight
        if (_flight is { } fl)
        {
            if (!_flightPrimed)
            {
                var ready = fl.Closing || ActivePhoto is not { IsPreviewReady: false } || (now - _flightCreateTime) >= 0.08;
                if (!ready)
                {
                    // Keep exact Frame-0 alignment while preview decodes (source tile still visible underneath).
                    var waitFrame = fl.CurrentFrame();
                    ApplyTransitionVisual(waitFrame);
                    _surface.Opacity = 0;
                }
                else
                {
                    _flightPrimed = true;
                    // Refresh MediaFrame now that preview/natural size may have resolved.
                    if (!fl.Closing)
                    {
                        var freshMedia = CurrentMediaFrame();
                        if (Math.Abs(freshMedia.Width - fl.Media.Width) > 1 || Math.Abs(freshMedia.Height - fl.Media.Height) > 1)
                            _flight = fl = ZoomFlight.StartOpen(ViewportRect, freshMedia, fl.Source, fl.CropSource, fl.SourceCornerRadius);
                    }
                    if (!_sourceHidden && !fl.Closing)
                    {
                        _sourceHidden = true;
                        _options.ActiveMediaChanged?.Invoke(Current.MediaId);
                    }
                    ApplyTransitionVisual(fl.CurrentFrame());
                }
            }
            else
            {
                var settled = fl.Step(dt);
                if (fl.Closing && !_unhiddenForClose && fl.NormalizedMorph <= ViewerMath.UnhideThreshold)
                {
                    _unhiddenForClose = true;
                    if (_sourceHidden)
                    {
                        _sourceHidden = false;
                        _options.ActiveMediaChanged?.Invoke(null);
                    }
                }
                ApplyTransitionVisual(fl.CurrentFrame());
                if (settled)
                {
                    var wasClosing = fl.Closing;
                    _flight = null;
                    if (wasClosing)
                    {
                        FinishClose();
                        return;
                    }
                    _dismiss = DismissState.None;
                    SyncNeighborVisibility();
                    ApplyTransitionVisual(CurrentRestFrame());
                }
            }
        }

        // 2. Interactive Dismiss Velocity-Preserving Spring-Back
        if (_springBack is { } sb && _flight == null)
        {
            const double omega = 18.0, damp = 0.92;
            sb.CenterX.Step(dt, omega, damp);
            sb.CenterY.Step(dt, omega, damp);
            sb.Scale.Step(dt, omega, damp);
            sb.CornerRadius.Step(dt, omega, damp);
            sb.Progress.Step(dt, omega, damp);

            var done = sb.CenterX.IsSettled(0.5, 4.0)
                    && sb.CenterY.IsSettled(0.5, 4.0)
                    && sb.Scale.IsSettled(0.002, 0.02)
                    && sb.Progress.IsSettled(0.004, 0.03);
            if (done)
            {
                _springBack = null;
                _dismiss = DismissState.None;
                SyncNeighborVisibility();
            }
            else
            {
                _dismiss = new DismissState(
                    sb.CenterX.Value,
                    sb.CenterY.Value,
                    Math.Clamp(sb.Scale.Value, 0.3, 1.05),
                    Math.Max(0, sb.CornerRadius.Value),
                    Math.Clamp(sb.Progress.Value, 0.0, 1.0));
            }
            ApplyTransitionVisual(CurrentRestFrame());
        }

        // 3. Horizontal strip slide / bounce motion
        if (_stripMotion is { } m)
        {
            var t = Math.Clamp((now - m.Start) / Math.Max(0.01, m.Duration), 0.0, 1.0);
            var ease = ViewerMath.EaseOutCubic(t);
            _stripOffset = ViewerMath.Lerp(m.From, m.To, ease);
            LayoutStrip();
            if (t >= 1.0)
            {
                _stripMotion = null;
                m.Done?.Invoke();
            }
        }

        // 4. Active photo smooth double-click / reset zoom animation
        ActivePhoto?.TickAnimation(now);
    }

    // ---- 3-Page Horizontal Strip ----

    void EnsurePages()
    {
        var lo = Math.Max(0, _index - 1);
        var hi = Math.Min(_items.Count - 1, _index + 1);

        foreach (var key in _pages.Keys.Where(k => k < lo || k > hi).ToList())
        {
            var el = _pages[key];
            _pages.Remove(key);
            if (el is ViewerVideoPage vp) vp.Teardown(closing: false);
            else if (el is ViewerPhotoPage pp) pp.Teardown();
            _strip.Children.Remove(el);
        }

        for (var i = lo; i <= hi; i++)
        {
            if (_pages.ContainsKey(i)) continue;
            var item = _items[i];
            var previewImg = _options.PreviewImage?.Invoke(item);
            var squarePreview = i == _startIndex || _options.CropSource ? _options.SquarePreviewPath?.Invoke(item) : null;
            FrameworkElement page;
            if (item.IsVideo)
            {
                var vp = new ViewerVideoPage(item, previewImg, squarePreview, _options.CropSource);
                vp.StateChanged += () => { if (ReferenceEquals(ActiveVideo, vp)) SyncVideoControls(); };
                vp.UserActivity += WakeVideoChrome;
                vp.UpdatePosterSize(_viewW, _viewH);
                page = vp;
            }
            else
            {
                var pp = new ViewerPhotoPage(item, previewImg, squarePreview, _options.CropSource);
                pp.UpdateLayoutSize(_viewW, _viewH);
                page = pp;
            }
            _pages[i] = page;
            _strip.Children.Add(page);
        }
        LayoutStrip();
        SyncNeighborVisibility();
    }

    void ActivateCurrentPage()
    {
        if (ActiveVideo is { } vp)
        {
            MediaPlayer? lent = null;
            if (_lent != null && string.Equals(_lentPath, vp.Item.Path, StringComparison.OrdinalIgnoreCase))
            {
                lent = _lent;
                _lent = null;
            }
            vp.Activate(lent);
            WakeVideoChrome();
        }
        else
        {
            _hideTimer?.Stop();
            _videoIdle = false;
        }
    }

    void LayoutStrip()
    {
        var w = Math.Max(1, _viewW);
        var h = Math.Max(1, _viewH);
        _strip.Width = w;
        _strip.Height = h;
        var stride = Stride;
        foreach (var (i, el) in _pages)
        {
            el.Width = w;
            el.Height = h;
            Canvas.SetLeft(el, (i - _index) * stride + _stripOffset);
            Canvas.SetTop(el, 0);
        }

        var towards = _index + (_stripOffset < 0 ? 1 : -1);
        var towardsPost = towards >= 0 && towards < _items.Count ? _items[towards].PostId : null;
        _caption.Opacity = ViewerMath.CaptionFade(_stripOffset, stride, Current.PostId, towardsPost);
    }

    void CommitStrip(int delta)
    {
        if (delta == 0 || _index + delta < 0 || _index + delta >= _items.Count)
        {
            _stripOffset = 0;
            LayoutStrip();
            return;
        }
        ActivePhoto?.ResetZoom();
        ActiveVideo?.Deactivate(closing: false);

        _index += delta;
        _stripOffset = Math.Clamp(_stripOffset + delta * Stride, -Stride, Stride);
        if (Math.Abs(_stripOffset) < 1.0) _stripOffset = 0;

        EnsurePages();
        ActivateCurrentPage();
        if (_sourceHidden) _options.ActiveMediaChanged?.Invoke(Current.MediaId);
        UpdateChrome();
    }

    void AnimateStrip(double target, double duration, Action? done)
    {
        _stripMotion = new StripMotion
        {
            From = _stripOffset,
            To = target,
            Start = Now(),
            Duration = Math.Max(0.05, duration),
            Done = done,
        };
    }

    void FinishStripMotion()
    {
        if (_stripMotion is not { } m) return;
        _stripMotion = null;
        _stripOffset = m.To;
        LayoutStrip();
        m.Done?.Invoke();
    }

    void Step(int delta)
    {
        if (_closing || _items.Count == 0) return;
        if (_flight is { Closing: false })
        {
            _flight = null;
            if (!_sourceHidden) { _sourceHidden = true; _options.ActiveMediaChanged?.Invoke(Current.MediaId); }
            SyncNeighborVisibility();
            ApplyTransitionVisual(CurrentRestFrame());
        }
        FinishStripMotion();
        if (_index + delta < 0 || _index + delta >= _items.Count)
        {
            BounceStrip(delta);
            return;
        }
        AnimateStrip(-delta * Stride, 0.28, () => CommitStrip(delta));
    }

    void BounceStrip(int delta) =>
        AnimateStrip(-delta * 30.0, 0.12, () => AnimateStrip(0, 0.22, null));

    void SettleStripSwipe(double velocityPxPerSec)
    {
        var (d, dur) = ViewerMath.SettleStrip(_stripOffset, velocityPxPerSec, _index, _items.Count, Stride);
        AnimateStrip(-d * Stride, dur, () => CommitStrip(d));
    }

    // ---- Chrome & Controls Sync ----

    void UpdateChrome()
    {
        var item = Current;
        var multi = _items.Count > 1;
        _counter.Text = multi ? $"{_index + 1} / {_items.Count}" : "";
        _prev.Visibility = multi && _index > 0 ? Visibility.Visible : Visibility.Collapsed;
        _next.Visibility = multi && _index < _items.Count - 1 ? Visibility.Visible : Visibility.Collapsed;

        _caption.SetItem(item);
        _videoRow.Visibility = item.IsVideo ? Visibility.Visible : Visibility.Collapsed;
        _photoActions.Visibility = item.IsVideo ? Visibility.Collapsed : Visibility.Visible;

        if (item.IsVideo) SyncVideoControls();
        UpdateFullscreenGlyph();
        if (_flight == null)
            ApplyTransitionVisual(CurrentRestFrame());
    }

    void SyncVideoControls()
    {
        if (ActiveVideo is not { } vp) return;
        var playing = vp.IsPlaying;
        ((FontIcon)_play.Content).Glyph = playing ? "\uE769" : "\uE768";
        var playTip = playing ? L("viewer.pause") : L("viewer.play");
        ToolTipService.SetToolTip(_play, playTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_play, playTip);

        var muted = vp.IsMuted;
        ((FontIcon)_mute.Content).Glyph = muted ? "\uE74F" : "\uE767";
        ToolTipService.SetToolTip(_mute, muted ? L("audio.turnOn") : null);

        ((TextBlock)_speed.Content).Text = FormatSpeed(vp.Rate);

        var pos = vp.Position;
        var dur = vp.Duration;
        _at.Text = ViewerVideoPage.FormatTime(pos);
        _length.Text = ViewerVideoPage.FormatTime(dur);
        if (!_scrubbing)
        {
            _settingPosition = true;
            _position.Value = dur.TotalMilliseconds > 0 ? Math.Clamp(pos.TotalMilliseconds / dur.TotalMilliseconds, 0, 1) : 0;
            _settingPosition = false;
        }
    }

    void WakeVideoChrome()
    {
        if (_closing || !Current.IsVideo) return;
        if (_videoIdle)
        {
            _videoIdle = false;
            if (_flight == null) ApplyTransitionVisual(CurrentRestFrame());
        }
        _hideTimer ??= MakeHideTimer();
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    DispatcherQueueTimer MakeHideTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(2500);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            if (_closing || !Current.IsVideo || _pointerOverControls || _caption.IsExpanded) return;
            if (ActiveVideo?.IsPlaying != true) return;
            _videoIdle = true;
            if (_flight == null) ApplyTransitionVisual(CurrentRestFrame());
        };
        return t;
    }

    void ToggleFullscreen()
    {
        if (MainWindow.Current is not { } w) return;
        try
        {
            var isFull = w.AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
            w.AppWindow.SetPresenter(isFull ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
            _enteredFullScreen = !isFull;
            UpdateFullscreenGlyph();
        }
        catch { }
    }

    void UpdateFullscreenGlyph()
    {
        var isFull = MainWindow.Current?.AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
        var glyph = isFull ? "\uE73F" : "\uE740";
        ((FontIcon)_photoFull.Content).Glyph = glyph;
        ((FontIcon)_videoFull.Content).Glyph = glyph;
    }

    // ---- Wheel & Trackpad Gestures ----

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (_closing || _flight != null || _dismiss.IsActive) return;
        var cp = e.GetCurrentPoint(this);
        var props = cp.Properties;
        var delta = props.MouseWheelDelta;
        if (delta == 0) return;

        var ctrl = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Control);
        var photo = ActivePhoto;

        // 1. Ctrl+Wheel or Precision Touchpad pinch zooms a photo anchored under the cursor.
        if (ctrl && photo != null)
        {
            e.Handled = true;
            var factor = Math.Exp(delta * 0.0045);
            photo.ZoomByFactor(factor, cp.Position);
            return;
        }

        // 2. While a photo is zoomed, wheel pans it.
        if (photo != null && photo.IsZoomed)
        {
            e.Handled = true;
            if (props.IsHorizontalMouseWheel) photo.PanBy(-delta * 0.6, 0);
            else photo.PanBy(0, delta * 0.6);
            return;
        }

        // 3. Unzoomed photo or video: mouse scroll wheel steps prev/next; touchpad horizontal swipe
        //    drives the 3-page strip continuously (touchpad vertical scroll does not skip pages).
        if (_caption.IsExpanded || ctrl) return;

        e.Handled = true;
        if (_items.Count <= 1) return;

        var nowMs = Environment.TickCount64;
        var shift = e.KeyModifiers.HasFlag(VirtualKeyModifiers.Shift);
        var isTouchpad = TouchpadInputState.IsTouchpadWheel(delta, shift, nowMs);
        var decision = _wheelRouter.OnWheel(props.IsHorizontalMouseWheel, delta, isTouchpad, nowMs);

        switch (decision.Kind)
        {
            case ViewerWheelKind.StepNext:
                if (_wheelSwiping) FinishWheelSwipe();
                Step(1);
                break;
            case ViewerWheelKind.StepPrev:
                if (_wheelSwiping) FinishWheelSwipe();
                Step(-1);
                break;
            case ViewerWheelKind.SwipeSettle:
                if (_wheelSwiping) FinishWheelSwipe();
                break;
            case ViewerWheelKind.SwipeDelta:
            {
                var now = Now();
                var dx = decision.SwipeDx;
                if (!_wheelSwiping)
                {
                    _wheelPendingX += dx;
                    if (Math.Abs(_wheelPendingX) < 4) return;
                    _stripMotion = null;
                    _wheelSwiping = true;
                    _wheelSamples.Clear();
                    ApplyWheelSwipeDelta(_wheelPendingX, now);
                    _wheelPendingX = 0;
                }
                else
                {
                    ApplyWheelSwipeDelta(dx, now);
                }
                _wheelEndTimer ??= MakeWheelEndTimer();
                _wheelEndTimer.Stop();
                _wheelEndTimer.Start();
                break;
            }
        }
    }

    void ApplyWheelSwipeDelta(double dx, double now)
    {
        _wheelSamples.Add((now, dx));
        while (_wheelSamples.Count > 1 && now - _wheelSamples[0].T > 0.1)
            _wheelSamples.RemoveAt(0);
        _stripOffset = ViewerMath.ApplyStripDelta(_stripOffset, dx, _index, _items.Count, Stride);
        LayoutStrip();
    }

    void FinishWheelSwipe()
    {
        _wheelEndTimer?.Stop();
        if (!_wheelSwiping) return;
        _wheelSwiping = false;
        _wheelPendingX = 0;
        var v = 0.0;
        if (_wheelSamples.Count > 1)
        {
            var span = Math.Max(1.0 / 60.0, _wheelSamples[^1].T - _wheelSamples[0].T);
            v = _wheelSamples.Sum(s => s.Dx) / span;
        }
        _wheelSamples.Clear();
        SettleStripSwipe(Math.Abs(v) < 50 ? 0 : v);
    }

    DispatcherQueueTimer MakeWheelEndTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(90);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            _wheelRouter.NotifyTimerSettled();
            FinishWheelSwipe();
        };
        return t;
    }

    // ---- Unified Single-Pointer Drag (Mouse + Touch + Pen) + Two-Finger Pinch ----

    void OnStripPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closing || _flight != null) return;
        var cp = e.GetCurrentPoint(this);
        var props = cp.Properties;

        if (props.IsXButton1Pressed) { e.Handled = true; Step(-1); return; }
        if (props.IsXButton2Pressed) { e.Handled = true; Step(1); return; }
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Mouse && !props.IsLeftButtonPressed) return;

        // Second finger down while already tracking a touch pointer -> yield cleanly to two-finger pinch.
        if (_dragPointerId != null && _dragPointerId != e.Pointer.PointerId)
        {
            AbortActivePointerDrag();
            return;
        }

        _dragPointerId = e.Pointer.PointerId;
        _dragPointerType = e.Pointer.PointerDeviceType;
        _dragDownPt = cp.Position;
        _dragLastPt = cp.Position;
        _dragMoved = false;
        _dragGesture = GestureMode.None;
        _pointerHeldVideo = false;
        _pinchingPhoto = false;
        _springBack = null;
        _singleClickTimer?.Stop();

        if (e.Pointer.PointerDeviceType != PointerDeviceType.Touch)
            _strip.CapturePointer(e.Pointer);

        if (ActiveVideo is { } vp && e.Pointer.PointerDeviceType != PointerDeviceType.Touch)
        {
            _pointerHeldVideo = true;
            vp.BeginPointerHold();
            return;
        }
        if (ActivePhoto is { IsZoomed: true })
            _dragGesture = GestureMode.Pan;
    }

    void OnStripPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_dragPointerId != e.Pointer.PointerId || _pinchingPhoto || _closing || _flight != null) return;
        var pt = e.GetCurrentPoint(this).Position;
        var dx = pt.X - _dragLastPt.X;
        var dy = pt.Y - _dragLastPt.Y;
        var totalDx = pt.X - _dragDownPt.X;
        var totalDy = pt.Y - _dragDownPt.Y;
        _dragLastPt = pt;
        var now = Now();

        if (!_dragMoved && Math.Sqrt(totalDx * totalDx + totalDy * totalDy) > 6)
        {
            _dragMoved = true;
            if (_pointerHeldVideo) { _pointerHeldVideo = false; ActiveVideo?.CancelHold(); }
        }

        if (_dragGesture == GestureMode.Pan && ActivePhoto is { } photo)
        {
            photo.PanBy(dx, dy);
            return;
        }

        if (_dragGesture == GestureMode.None)
        {
            // Side-edge inward swipe dismiss (touch)
            if (_dragPointerType == PointerDeviceType.Touch && !_caption.IsExpanded)
            {
                var edgeW = ViewerMath.EdgeZoneWidth(_viewW);
                var nearLeft = _dragDownPt.X <= edgeW;
                var nearRight = _dragDownPt.X >= _viewW - edgeW;
                if (nearLeft || nearRight)
                {
                    var dir = nearLeft ? 1 : -1;
                    if (totalDx * dir > 6 && Math.Abs(totalDx) > Math.Abs(totalDy) * 0.9)
                    {
                        _dragGesture = GestureMode.Dismiss;
                        BeginDismissDrag(fromEdge: true, edgeDir: dir, _dragDownPt, totalDx, totalDy, now);
                        return;
                    }
                }
            }

            // Downward drag-to-dismiss on unzoomed photo or video (Mouse, Touch, Pen)
            if ((ActivePhoto is { IsZoomed: false } || ActiveVideo != null) && !_caption.IsExpanded &&
                totalDy > 8 && totalDy > Math.Abs(totalDx) * 1.15)
            {
                _dragGesture = GestureMode.Dismiss;
                BeginDismissDrag(fromEdge: false, edgeDir: 1, _dragDownPt, totalDx, totalDy, now);
                return;
            }

            // Horizontal 1:1 strip drag on unzoomed photo or video (Mouse, Touch, Pen)
            if (_items.Count > 1 && !_caption.IsExpanded &&
                Math.Abs(totalDx) > 8 && Math.Abs(totalDx) > Math.Abs(totalDy) * 1.2)
            {
                _stripMotion = null;
                _dragGesture = GestureMode.Swipe;
                _wheelSamples.Clear();
                ApplyWheelSwipeDelta(totalDx, now);
                return;
            }
            return;
        }

        if (_dragGesture == GestureMode.Dismiss)
        {
            _dismissRawX += dx;
            _dismissRawY += dy;
            UpdateDismissDrag(now, dx, dy);
        }
        else if (_dragGesture == GestureMode.Swipe)
        {
            ApplyWheelSwipeDelta(dx, now);
        }
    }

    void OnStripPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_dragPointerId != e.Pointer.PointerId) return;
        _dragPointerId = null;
        try { _strip.ReleasePointerCapture(e.Pointer); } catch { }
        var mode = _dragGesture;
        _dragGesture = GestureMode.None;

        if (mode == GestureMode.Dismiss)
        {
            FinishDismissDrag();
            return;
        }
        if (mode == GestureMode.Swipe)
        {
            var v = 0.0;
            if (_wheelSamples.Count > 1)
            {
                var span = Math.Max(1.0 / 60.0, _wheelSamples[^1].T - _wheelSamples[0].T);
                v = _wheelSamples.Sum(s => s.Dx) / span;
            }
            _wheelSamples.Clear();
            SettleStripSwipe(v);
            return;
        }
        if (_pointerHeldVideo)
        {
            _pointerHeldVideo = false;
            ActiveVideo?.EndPointerHold();
            return;
        }
        if (!_dragMoved && mode == GestureMode.None && ActivePhoto != null && _flight == null && !_closing)
        {
            _singleClickTimer ??= MakeSingleClickTimer();
            _singleClickTimer.Stop();
            _singleClickTimer.Start();
        }
    }

    void OnStripPointerCanceled(object sender, PointerRoutedEventArgs e)
    {
        if (_dragPointerId != e.Pointer.PointerId) return;
        try { _strip.ReleasePointerCapture(e.Pointer); } catch { }
        AbortActivePointerDrag();
    }

    void AbortActivePointerDrag()
    {
        _dragPointerId = null;
        var mode = _dragGesture;
        _dragGesture = GestureMode.None;
        if (_pointerHeldVideo) { _pointerHeldVideo = false; ActiveVideo?.CancelHold(); }
        if (mode == GestureMode.Dismiss) CancelDismissDrag(0, 0);
        else if (mode == GestureMode.Swipe) SettleStripSwipe(0);
    }

    void OnStripDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (_closing || _flight != null) return;
        _singleClickTimer?.Stop();
        e.Handled = true;

        if (ActiveVideo is { } vp)
        {
            vp.CancelHold();
            vp.TogglePlay(showHud: true);
            return;
        }
        if (ActivePhoto is { } photo)
            photo.ToggleDoubleTapZoom(e.GetPosition(this), Now());
    }

    DispatcherQueueTimer MakeSingleClickTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(240);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            if (_closing || ActivePhoto == null || _dragMoved || _dismiss.IsActive) return;
            _chromeHidden = !_chromeHidden;
            ApplyTransitionVisual(CurrentRestFrame());
        };
        return t;
    }

    void OnStripManipulationStarted(object sender, ManipulationStartedRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _closing || _flight != null) return;
        _pinchingPhoto = false;
    }

    void OnStripManipulationDelta(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _closing || _flight != null) return;
        if (ActivePhoto is { } photo && Math.Abs(e.Delta.Scale - 1.0) > 0.001)
        {
            if (!_pinchingPhoto)
            {
                _pinchingPhoto = true;
                AbortActivePointerDrag();
            }
            Point pt;
            try { pt = _strip.TransformToVisual(this).TransformPoint(e.Position); } catch { pt = e.Position; }
            photo.ZoomByFactor(e.Delta.Scale, pt);
            e.Handled = true;
        }
    }

    void OnStripManipulationCompleted(object sender, ManipulationCompletedRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch) return;
        _pinchingPhoto = false;
    }

    // ---- Interactive Dismiss Drag Helpers ----

    void BeginDismissDrag(bool fromEdge, int edgeDir, Point grabPoint, double initialDx, double initialDy, double now)
    {
        _springBack = null;
        _stripMotion = null;
        _stripOffset = 0;
        LayoutStrip();

        _dismissFromEdge = fromEdge;
        _dismissEdgeDir = edgeDir;
        _dismissGrabPt = grabPoint;
        _dismissMedia = CurrentMediaFrame();
        _dismissRawX = initialDx;
        _dismissRawY = initialDy;
        _dismissSamples.Clear();
        UpdateDismissDrag(now, initialDx, initialDy);
        SyncNeighborVisibility();
    }

    void UpdateDismissDrag(double now, double dx, double dy)
    {
        _dismissSamples.Add((now, dx, dy));
        while (_dismissSamples.Count > 1 && now - _dismissSamples[0].T > 0.1)
            _dismissSamples.RemoveAt(0);
        _dismiss = ViewerMath.EvaluateDismiss(
            _dismissMedia, _dismissGrabPt, _dismissRawX, _dismissRawY, _viewW, _viewH, _dismissFromEdge, _dismissEdgeDir);
        SyncNeighborVisibility();
        ApplyTransitionVisual(CurrentRestFrame());
    }

    void FinishDismissDrag(double fallbackVx = 0, double fallbackVy = 0)
    {
        double vx = fallbackVx, vy = fallbackVy;
        if (_dismissSamples.Count > 1)
        {
            var span = Math.Max(1.0 / 60.0, _dismissSamples[^1].T - _dismissSamples[0].T);
            vx = _dismissSamples.Sum(s => s.Dx) / span;
            vy = _dismissSamples.Sum(s => s.Dy) / span;
        }
        _dismissSamples.Clear();

        if (ViewerMath.ShouldCommitDismiss(_dismissRawX, _dismissRawY, vx, vy, _viewW, _viewH, _dismissFromEdge, _dismissEdgeDir))
            CloseWithVelocity(immediate: false, fromDismiss: _dismiss, velX: vx, velY: vy);
        else
            CancelDismissDrag(vx, vy);
    }

    void CancelDismissDrag(double vx, double vy)
    {
        if (!_dismiss.IsActive) return;
        var mediaCx = _dismissMedia.X + _dismissMedia.Width * 0.5;
        var mediaCy = _dismissMedia.Y + _dismissMedia.Height * 0.5;
        _springBack = new SpringBackState
        {
            CenterX = new Spring1D(_dismiss.CenterX, mediaCx, Math.Clamp(vx, -1800, 1800)),
            CenterY = new Spring1D(_dismiss.CenterY, mediaCy, Math.Clamp(vy, -1800, 1800)),
            Scale = new Spring1D(_dismiss.Scale, 1.0),
            CornerRadius = new Spring1D(_dismiss.CornerRadius, 0.0),
            Progress = new Spring1D(_dismiss.Progress, 0.0),
        };
        _lastTickTime = Now();
    }

    // ---- Keyboard Shortcuts ----

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (_closing) return;
        var ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var shift = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);

        if (ctrl && e.Key == VirtualKey.C)
        {
            _ = ShareMenu.Copy(Current);
            e.Handled = true;
            return;
        }

        switch (e.Key)
        {
            case VirtualKey.Escape:
                Close();
                break;
            case VirtualKey.Left:
                if (shift && ActiveVideo is { } vl) vl.SeekBy(-5);
                else Step(-1);
                break;
            case VirtualKey.Right:
                if (shift && ActiveVideo is { } vr) vr.SeekBy(5);
                else Step(1);
                break;
            case VirtualKey.J when ActiveVideo is { } vj:
                vj.SeekBy(-5);
                break;
            case VirtualKey.L when ActiveVideo is { } vll:
                vll.SeekBy(5);
                break;
            case VirtualKey.Space when ActiveVideo is { } vs:
                vs.TogglePlay(showHud: true);
                break;
            case VirtualKey.Up when ActiveVideo is { } vu:
                vu.StepVolume(0.1);
                break;
            case VirtualKey.Down when ActiveVideo is { } vd:
                vd.StepVolume(-0.1);
                break;
            case VirtualKey.M when ActiveVideo is { } vm:
                vm.ToggleMute();
                break;
            case VirtualKey.F when !ctrl:
            case VirtualKey.F11:
                ToggleFullscreen();
                break;
            case VirtualKey.Add or (VirtualKey)187 when ActivePhoto is { } pIn:
                pIn.ZoomToScale(pIn.CurrentScale * 1.4, new Point(_viewW * 0.5, _viewH * 0.5), Now());
                break;
            case VirtualKey.Subtract or (VirtualKey)189 when ActivePhoto is { } pOut:
                pOut.ZoomToScale(pOut.CurrentScale / 1.4, new Point(_viewW * 0.5, _viewH * 0.5), Now());
                break;
            case VirtualKey.Number0 or VirtualKey.NumberPad0 when ActivePhoto is { } pReset:
                pReset.ZoomToScale(1.0, new Point(_viewW * 0.5, _viewH * 0.5), Now());
                break;
            case VirtualKey.Delete when _options.Place != Place.Trash:
                _ = Trash();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    // ---- Trash Action ----

    async Task Trash()
    {
        var item = Current;
        var receipt = await MediaActions.Run(ActionKind.Trash, [item.MediaId], done: n => L("trash.moved", n));
        if (receipt == null || _host == null || _closing) return;
        var at = _items.FindIndex(m => m.MediaId == item.MediaId);
        if (at < 0) return;

        foreach (var el in _pages.Values)
        {
            if (el is ViewerVideoPage vp) vp.Teardown(closing: false);
            else if (el is ViewerPhotoPage pp) pp.Teardown();
            _strip.Children.Remove(el);
        }
        _pages.Clear();

        _items.RemoveAt(at);
        if (_items.Count == 0) { Close(); return; }
        if (at < _index) _index--;
        _index = Math.Min(_index, _items.Count - 1);
        _stripOffset = 0;
        _stripMotion = null;

        EnsurePages();
        ActivateCurrentPage();
        if (_sourceHidden) _options.ActiveMediaChanged?.Invoke(Current.MediaId);
        UpdateChrome();
    }

    // ---- UI Builders ----

    static Brush Fade(bool top) => new LinearGradientBrush
    {
        StartPoint = new Point(0, top ? 0 : 1),
        EndPoint = new Point(0, top ? 1 : 0),
        GradientStops =
        {
            new GradientStop { Color = Windows.UI.Color.FromArgb(0xB8, 0, 0, 0), Offset = 0 },
            new GradientStop { Color = Windows.UI.Color.FromArgb(0x66, 0, 0, 0), Offset = 0.55 },
            new GradientStop { Color = Windows.UI.Color.FromArgb(0, 0, 0, 0), Offset = 1 },
        },
    };

    static void ApplySubtleResources(Button b)
    {
        var hover = new SolidColorBrush(Windows.UI.Color.FromArgb(0x18, 255, 255, 255));
        var press = new SolidColorBrush(Windows.UI.Color.FromArgb(0x0E, 255, 255, 255));
        var none = new SolidColorBrush(Colors.Transparent);
        b.Resources["ButtonBackgroundPointerOver"] = hover;
        b.Resources["ButtonBackgroundPressed"] = press;
        b.Resources["ButtonBorderBrushPointerOver"] = none;
        b.Resources["ButtonBorderBrushPressed"] = none;
    }

    static Button IconButton(string glyph, string tip, Action click, string automationId)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 15, Foreground = new SolidColorBrush(Colors.White) },
            Background = new SolidColorBrush(Colors.Transparent),
            BorderBrush = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Width = 36,
            Height = 36,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(6),
        };
        ApplySubtleResources(b);
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, automationId);
        b.Click += (_, _) => click();
        return b;
    }

    static Button NavButton(string glyph, string tip, Action click, string automationId)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 15, Foreground = new SolidColorBrush(Colors.White) },
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x66, 0x1C, 0x1C, 0x1C)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x14, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Width = 36,
            Height = 52,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
        };
        b.Resources["ButtonBackgroundPointerOver"] = new SolidColorBrush(Windows.UI.Color.FromArgb(0x99, 0x26, 0x26, 0x26));
        b.Resources["ButtonBackgroundPressed"] = new SolidColorBrush(Windows.UI.Color.FromArgb(0x7A, 0x18, 0x18, 0x18));
        b.Resources["ButtonBorderBrushPointerOver"] = new SolidColorBrush(Windows.UI.Color.FromArgb(0x24, 255, 255, 255));
        b.Resources["ButtonBorderBrushPressed"] = new SolidColorBrush(Windows.UI.Color.FromArgb(0x14, 255, 255, 255));
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, automationId);
        b.Click += (_, _) => click();
        return b;
    }

    static TextBlock TimeText() => new()
    {
        Foreground = new SolidColorBrush(Colors.White),
        FontSize = 12,
        FontWeight = FontWeights.Medium,
        VerticalAlignment = VerticalAlignment.Center,
    };

    static string FormatSpeed(double r) =>
        (r == Math.Round(r) ? ((int)r).ToString(CultureInfo.InvariantCulture) : r.ToString(CultureInfo.InvariantCulture)) + "\u00D7"; // i18n-exempt

    MenuFlyout SpeedMenu()
    {
        var m = new MenuFlyout();
        foreach (var r in new[] { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0 })
        {
            var item = new RadioMenuFlyoutItem
            {
                Text = FormatSpeed(r),
                GroupName = "speed",
                IsChecked = Math.Abs(r - ViewerVideoPage.SavedRate) < 0.01,
            };
            item.Click += (_, _) =>
            {
                ActiveVideo?.SetRate(r);
                ViewerVideoPage.SavedRate = r;
                ((TextBlock)_speed.Content).Text = FormatSpeed(r);
                foreach (var o in m.Items)
                    if (o is RadioMenuFlyoutItem x) x.IsChecked = x.Text == FormatSpeed(r);
            };
            m.Items.Add(item);
        }
        return m;
    }
}

/// A one-shot timer that can be started again.
public sealed class DispatcherTimerLite
{
    readonly DispatcherQueueTimer _t;
    public DispatcherTimerLite(FrameworkElement owner, TimeSpan after, Action tick)
    {
        _t = owner.DispatcherQueue.CreateTimer();
        _t.Interval = after;
        _t.IsRepeating = false;
        _t.Tick += (_, _) => tick();
    }
    public void Restart() { _t.Stop(); _t.Start(); }
    public void Stop() => _t.Stop();
}
