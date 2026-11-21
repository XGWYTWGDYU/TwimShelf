// Unified full-screen media viewer (matching Apple MacPhotoView/MacPlayerView, Web Viewer/Player,
// and Flutter ViewerPage):
//  * GPU-composited zoom open & close transitions (transform + rounded-rect clip morph + separate
//    backdrop fade + hidden source tile/card sync with early unhide to eliminate 1-frame flash).
//  * 3-page horizontal strip (current + preloaded neighbours, 40px gap) with vsync-driven ease-out
//    sliding, edge bounce, 1:1 trackpad/touch swipe with velocity settle, and cross-post caption fade.
//  * Interactive drag-to-dismiss (downward drag or touch side-edge swipe) that springs back or
//    launches the zoom-close flight directly from where the pointer/finger released it.
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
using Windows.UI.ViewManagement;
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

    // Visual tree (invariant depth so pages never remount across transitions)
    readonly Grid _rootGrid = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Border _backdrop = new() { Background = new SolidColorBrush(Colors.Black), Opacity = 0, IsHitTestVisible = false };
    readonly Grid _surface = new() { Background = new SolidColorBrush(Colors.Transparent) };
    readonly Canvas _strip = new()
    {
        Background = new SolidColorBrush(Colors.Transparent),
        ManipulationMode = ManipulationModes.Scale | ManipulationModes.TranslateX | ManipulationModes.TranslateY,
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
        Spacing = 10,
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

    // GPU composition transition state
    enum TransitionPhase { None, Opening, Closing }
    TransitionPhase _transPhase;
    double _transStart;
    double _transDuration;
    double _transRaw;
    double _transFromRaw;
    Rect? _transSource;
    Rect _transMedia;
    bool _reducedMotion;
    bool _sourceHidden;
    bool _unhiddenForClose;
    bool _closing;
    bool _enteredFullScreen;

    Visual? _surfaceVisual;
    CompositionRoundedRectangleGeometry? _clipGeo;
    CompositionGeometricClip? _clip;

    // Interactive dismiss drag state
    DismissState _dismiss = DismissState.None;
    bool _dismissing;
    bool _dismissFromEdge;
    int _dismissEdgeDir = 1;
    double _dismissRawX, _dismissRawY;
    readonly List<(double T, double Dx, double Dy)> _dismissSamples = [];
    bool _springingBack;
    double _springStart, _springFromX, _springFromY;

    // Trackpad horizontal wheel swipe state
    bool _wheelSwiping;
    double _wheelPendingX;
    readonly List<(double T, double Dx)> _wheelSamples = [];
    DispatcherQueueTimer? _wheelEndTimer;

    // Pointer interaction on _strip (mouse photo pan / dismiss / single-click chrome toggle / video hold)
    uint? _activePointerId;
    PointerDeviceType _activePointerType;
    Point _pointerDownPt;
    Point _pointerLastPt;
    bool _pointerDraggingPan;
    bool _pointerMoved;
    bool _pointerHeldVideo;
    DispatcherQueueTimer? _singleClickTimer;

    // Touch manipulation tracking
    enum TouchGesture { None, Pinch, Pan, Swipe, Dismiss }
    TouchGesture _touchGesture;
    double _touchLastScale = 1.0;

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
        _reducedMotion = !AnimationsEnabled();

        IsTabStop = true;
        UseSystemFocusVisuals = false;

        // Top bar (window drag + counter)
        _top = new Grid { Height = 48, VerticalAlignment = VerticalAlignment.Top, Background = Fade(true) };
        _top.Children.Add(_drag);
        _top.Children.Add(_counter);

        // Prev / Next circular buttons
        _prev = RoundButton("\uE76B", L("viewer.previous"), 44, 16, () => Step(-1), "viewerPrev");
        _prev.HorizontalAlignment = HorizontalAlignment.Left;
        _prev.VerticalAlignment = VerticalAlignment.Center;
        _prev.Margin = new Thickness(16);

        _next = RoundButton("\uE76C", L("viewer.next"), 44, 16, () => Step(1), "viewerNext");
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
            Padding = new Thickness(6, 0, 6, 0),
        };
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

        // Photo action buttons (bottom-right round translucent pills, matching macOS & Web)
        _photoShare = RoundButton("\uE72D", L("viewer.share"), 36, 14, () => { }, "photoShare");
        _photoShare.Flyout = ShareMenu.For(() => Current);
        _photoFull = RoundButton("\uE740", "F", 36, 14, ToggleFullscreen, "photoFullscreen");
        _photoClose = RoundButton("\uE711", L("viewer.close"), 36, 14, () => Close(), "photoClose");
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

        _surface.Children.Add(_strip);
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
        _strip.ManipulationStarted += OnTouchManipulationStarted;
        _strip.ManipulationDelta += OnTouchManipulationDelta;
        _strip.ManipulationCompleted += OnTouchManipulationCompleted;

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

    static double Now() => Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency;

    static bool AnimationsEnabled()
    {
        try { return new UISettings().AnimationsEnabled; }
        catch { return true; }
    }

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
        if (_surfaceVisual != null) return;
        _surfaceVisual = ElementCompositionPreview.GetElementVisual(_surface);
        _surfaceVisual.CenterPoint = Vector3.Zero;
        var comp = _surfaceVisual.Compositor;
        _clipGeo = comp.CreateRoundedRectangleGeometry();
        _clip = comp.CreateGeometricClip(_clipGeo);
    }

    void OnViewerSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (e.NewSize.Width <= 0 || e.NewSize.Height <= 0) return;
        _viewW = e.NewSize.Width;
        _viewH = e.NewSize.Height;
        _caption.SetMaxExpandedHeight(_viewH * 0.45);
        LayoutStrip();
        if (_transPhase == TransitionPhase.None)
            ApplyTransitionVisual(CurrentRestFrame());
    }

    // ---- Open / Close GPU Zoom Transitions ----

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
        ViewerMath.EvaluateTransition(ViewportRect, CurrentMediaFrame(), null, _options.CropSource, _options.SourceCornerRadius, 1.0, false, _dismiss);

    void BeginOpenTransition()
    {
        _transSource = _reducedMotion ? null : _options.SourceRect?.Invoke(Current);
        _transMedia = CurrentMediaFrame();
        _transPhase = TransitionPhase.Opening;
        _transFromRaw = 0.0;
        _transRaw = 0.0;
        _transDuration = _transSource != null ? ViewerMath.OpenDuration : ViewerMath.FadeFallbackDuration;
        _transStart = Now();
        _sourceHidden = false;
        _unhiddenForClose = false;

        // Paint Frame 0 at exact source rect BEFORE making _surface visible -> zero full-screen flash.
        var f0 = ViewerMath.EvaluateTransition(ViewportRect, _transMedia, _transSource, _options.CropSource, _options.SourceCornerRadius, 0.0, false, DismissState.None);
        ApplyTransitionVisual(f0);
    }

    public void Close(bool immediate = false)
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
        _springingBack = false;
        _singleClickTimer?.Stop();
        _wheelEndTimer?.Stop();
        _hideTimer?.Stop();
        FinishStripMotion();

        // Interrupting open mid-flight starts close smoothly from the current progress `raw`.
        var startRaw = _transPhase == TransitionPhase.Opening ? _transRaw : 1.0;

        // Keep video playing live (muted, 1×) inside the shrinking zoom rect during close!
        ActiveVideo?.PrepareClose();

        // Allow Browse to sync a visible multi-media card's page before querying SourceRect.
        try { _options.SyncBeforeClose?.Invoke(Current); } catch { }

        _transSource = _reducedMotion ? null : _options.SourceRect?.Invoke(Current);
        _transMedia = CurrentMediaFrame();
        _transPhase = TransitionPhase.Closing;
        _transFromRaw = Math.Clamp(startRaw, 0.01, 1.0);
        _transRaw = _transFromRaw;
        var baseDur = _transSource != null ? ViewerMath.CloseDuration : ViewerMath.FadeFallbackDuration;
        _transDuration = Math.Max(0.08, baseDur * _transFromRaw);
        _transStart = Now();
        _unhiddenForClose = false;

        // Make sure chrome immediately stops taking hits while closing.
        _chromeLayer.IsHitTestVisible = false;
        _strip.IsHitTestVisible = false;
    }

    void ApplyTransitionVisual(TransitionFrame f)
    {
        _backdrop.Opacity = Math.Clamp(f.BackdropOpacity, 0, 1);
        _surface.Opacity = Math.Clamp(f.SurfaceOpacity, 0, 1);

        var chromeVisible = !_chromeHidden && !(Current.IsVideo && _videoIdle);
        _chromeLayer.Opacity = chromeVisible ? Math.Clamp(f.ChromeOpacity, 0, 1) : 0;

        if (_surfaceVisual == null) return;

        var atIdentity = Math.Abs(f.Scale - 1.0) < 1e-4 &&
                         Math.Abs(f.OffsetX) < 0.05 &&
                         Math.Abs(f.OffsetY) < 0.05 &&
                         _transPhase == TransitionPhase.None &&
                         !_dismiss.IsActive;
        if (atIdentity)
        {
            _surfaceVisual.Scale = Vector3.One;
            _surfaceVisual.Offset = Vector3.Zero;
            _surfaceVisual.Clip = null;
            return;
        }

        _surfaceVisual.Scale = new Vector3((float)f.Scale, (float)f.Scale, 1f);
        _surfaceVisual.Offset = new Vector3((float)f.OffsetX, (float)f.OffsetY, 0f);

        if (_transPhase != TransitionPhase.None && _transSource != null && _clipGeo != null && _clip != null)
        {
            _clipGeo.Offset = new Vector2((float)f.ClipX, (float)f.ClipY);
            _clipGeo.Size = new Vector2((float)Math.Max(0, f.ClipW), (float)Math.Max(0, f.ClipH));
            var r = (float)Math.Max(0, f.ClipCornerRadius);
            _clipGeo.CornerRadius = new Vector2(r, r);
            if (_surfaceVisual.Clip != _clip) _surfaceVisual.Clip = _clip;
        }
        else
        {
            _surfaceVisual.Clip = null;
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

        // Unhide underlying source tile/card if not already unhidden during the close tail.
        if (_sourceHidden)
        {
            _sourceHidden = false;
            _options.ActiveMediaChanged?.Invoke(null);
        }

        // Remove from visual tree BEFORE returning the MediaPlayer to its Browse card (so card layout
        // triggered by our removal sees Viewer.IsOpen == false and adopts the live player cleanly).
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

        // Dispose unconsumed lent player if it was never attached (edge case).
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

        // 1. Open / Close GPU transition
        if (_transPhase == TransitionPhase.Opening)
        {
            var elapsed = (now - _transStart) / Math.Max(0.01, _transDuration);
            _transRaw = Math.Clamp(elapsed, 0.0, 1.0);
            if (!_sourceHidden && _transRaw > 0.0)
            {
                _sourceHidden = true;
                _options.ActiveMediaChanged?.Invoke(Current.MediaId);
            }
            var frame = ViewerMath.EvaluateTransition(ViewportRect, _transMedia, _transSource, _options.CropSource, _options.SourceCornerRadius, _transRaw, false, DismissState.None);
            ApplyTransitionVisual(frame);
            if (_transRaw >= 1.0)
            {
                _transPhase = TransitionPhase.None;
                _transSource = null;
                ApplyTransitionVisual(CurrentRestFrame());
            }
        }
        else if (_transPhase == TransitionPhase.Closing)
        {
            var elapsed = (now - _transStart) / Math.Max(0.01, _transDuration);
            _transRaw = Math.Clamp(_transFromRaw * (1.0 - elapsed), 0.0, 1.0);
            // Unhide underlying source tile/card slightly BEFORE the flying layer dissolves so
            // there is zero 1-frame blank flash on landing (matching Flutter ViewerPage).
            if (!_unhiddenForClose && _transRaw <= ViewerMath.UnhideThreshold)
            {
                _unhiddenForClose = true;
                if (_sourceHidden)
                {
                    _sourceHidden = false;
                    _options.ActiveMediaChanged?.Invoke(null);
                }
            }
            var frame = ViewerMath.EvaluateTransition(ViewportRect, _transMedia, _transSource, _options.CropSource, _options.SourceCornerRadius, _transRaw, true, _dismiss);
            ApplyTransitionVisual(frame);
            if (_transRaw <= 0.0)
            {
                _transPhase = TransitionPhase.None;
                FinishClose();
                return;
            }
        }

        // 2. Interactive dismiss spring-back
        if (_springingBack && _transPhase == TransitionPhase.None)
        {
            var t = Math.Clamp((now - _springStart) / ViewerMath.SpringBackDuration, 0.0, 1.0);
            var ease = ViewerMath.EaseOutCubic(t);
            _dismissRawX = ViewerMath.Lerp(_springFromX, 0.0, ease);
            _dismissRawY = ViewerMath.Lerp(_springFromY, 0.0, ease);
            _dismiss = t >= 1.0
                ? DismissState.None
                : ViewerMath.EvaluateDismiss(_dismissRawX, _dismissRawY, _viewW, _viewH, _dismissFromEdge, _dismissEdgeDir);
            if (t >= 1.0) _springingBack = false;
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
        // Deactivate outgoing page
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
        if (_transPhase == TransitionPhase.Opening)
        {
            // Let rapid keyboard navigation finish the open transition cleanly.
            _transPhase = TransitionPhase.None;
            _transSource = null;
            if (!_sourceHidden) { _sourceHidden = true; _options.ActiveMediaChanged?.Invoke(Current.MediaId); }
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

    void BounceStrip(int delta)
    {
        AnimateStrip(-delta * 30.0, 0.12, () => AnimateStrip(0, 0.22, null));
    }

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
        if (_transPhase == TransitionPhase.None)
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
            if (_transPhase == TransitionPhase.None) ApplyTransitionVisual(CurrentRestFrame());
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
            if (_transPhase == TransitionPhase.None) ApplyTransitionVisual(CurrentRestFrame());
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
        if (_closing || _transPhase != TransitionPhase.None) return;
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

        // 3. Horizontal wheel / touchpad sideways swipe drives the 3-page strip.
        if (props.IsHorizontalMouseWheel)
        {
            e.Handled = true;
            if (_items.Count <= 1) return;

            // Discrete mouse tilt wheel notches (±120) step smoothly one page.
            if (!_wheelSwiping && Math.Abs(delta) >= 120 && delta % 120 == 0)
            {
                Step(delta > 0 ? 1 : -1);
                return;
            }

            // Continuous touchpad horizontal swipe: 1:1 finger-following strip movement.
            var now = Now();
            var dx = -delta * 0.85;
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
            return;
        }

        // 4. Plain vertical mouse wheel over an unzoomed photo steps prev/next (when caption not expanded).
        if (photo != null && !_caption.IsExpanded && !ctrl)
        {
            e.Handled = true;
            Step(delta < 0 ? 1 : -1);
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

    DispatcherQueueTimer MakeWheelEndTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(90);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
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
        };
        return t;
    }

    // ---- Pointer Interaction (Mouse Pan, Drag-to-Dismiss, Single/Double Click, Video Hold) ----

    void OnStripPointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_closing || _transPhase != TransitionPhase.None) return;
        var cp = e.GetCurrentPoint(this);
        var props = cp.Properties;

        // Mouse Back / Forward side buttons turn pages (matching Flutter ViewerPage).
        if (props.IsXButton1Pressed) { e.Handled = true; Step(-1); return; }
        if (props.IsXButton2Pressed) { e.Handled = true; Step(1); return; }

        if (!props.IsLeftButtonPressed) return;
        if (e.Pointer.PointerDeviceType == PointerDeviceType.Touch) return; // Handled by Manipulation events.

        _activePointerId = e.Pointer.PointerId;
        _activePointerType = e.Pointer.PointerDeviceType;
        _pointerDownPt = cp.Position;
        _pointerLastPt = cp.Position;
        _pointerMoved = false;
        _pointerDraggingPan = false;
        _dismissing = false;
        _pointerHeldVideo = false;

        if (ActiveVideo is { } vp)
        {
            _pointerHeldVideo = true;
            vp.BeginPointerHold();
            _strip.CapturePointer(e.Pointer);
            return;
        }

        if (ActivePhoto is { } photo)
        {
            _strip.CapturePointer(e.Pointer);
            if (photo.IsZoomed) _pointerDraggingPan = true;
        }
    }

    void OnStripPointerMoved(object sender, PointerRoutedEventArgs e)
    {
        if (_activePointerId != e.Pointer.PointerId || _closing) return;
        var pt = e.GetCurrentPoint(this).Position;
        var dx = pt.X - _pointerLastPt.X;
        var dy = pt.Y - _pointerLastPt.Y;
        var totalDx = pt.X - _pointerDownPt.X;
        var totalDy = pt.Y - _pointerDownPt.Y;
        _pointerLastPt = pt;

        if (!_pointerMoved && Math.Sqrt(totalDx * totalDx + totalDy * totalDy) > 6)
        {
            _pointerMoved = true;
            if (_pointerHeldVideo) ActiveVideo?.CancelHold();
        }

        if (_pointerDraggingPan && ActivePhoto is { } photo)
        {
            photo.PanBy(dx, dy);
            return;
        }

        // Unzoomed photo downward drag -> interactive drag-to-dismiss!
        if (ActivePhoto is { IsZoomed: false } && !_caption.IsExpanded)
        {
            if (!_dismissing && totalDy > 8 && totalDy > Math.Abs(totalDx) * 1.15)
            {
                _springingBack = false;
                _dismissing = true;
                _dismissFromEdge = false;
                _dismissRawX = totalDx;
                _dismissRawY = totalDy;
                _dismissSamples.Clear();
                UpdateDismissDrag(Now(), totalDx, totalDy);
            }
            else if (_dismissing)
            {
                _dismissRawX += dx;
                _dismissRawY += dy;
                UpdateDismissDrag(Now(), dx, dy);
            }
        }
    }

    void OnStripPointerReleased(object sender, PointerRoutedEventArgs e)
    {
        if (_activePointerId != e.Pointer.PointerId) return;
        _activePointerId = null;
        _strip.ReleasePointerCapture(e.Pointer);

        if (_pointerHeldVideo)
        {
            _pointerHeldVideo = false;
            var wasBoost = ActiveVideo?.EndPointerHold() == true;
            if (wasBoost) return;
            return;
        }

        if (_dismissing)
        {
            _dismissing = false;
            FinishDismissDrag();
            return;
        }

        if (!_pointerMoved && !_pointerDraggingPan && ActivePhoto != null && _transPhase == TransitionPhase.None)
        {
            // Delayed single-click chrome toggle so double-click can cancel it cleanly.
            _singleClickTimer ??= MakeSingleClickTimer();
            _singleClickTimer.Stop();
            _singleClickTimer.Start();
        }
        _pointerDraggingPan = false;
    }

    void OnStripPointerCanceled(object sender, PointerRoutedEventArgs e)
    {
        if (_activePointerId != e.Pointer.PointerId) return;
        _activePointerId = null;
        _strip.ReleasePointerCapture(e.Pointer);
        if (_pointerHeldVideo) { _pointerHeldVideo = false; ActiveVideo?.CancelHold(); }
        if (_dismissing) { _dismissing = false; CancelDismissDrag(); }
        _pointerDraggingPan = false;
    }

    void OnStripDoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (_closing || _transPhase != TransitionPhase.None) return;
        _singleClickTimer?.Stop();
        e.Handled = true;

        if (ActiveVideo is { } vp)
        {
            vp.CancelHold();
            vp.TogglePlay(showHud: true);
            return;
        }
        if (ActivePhoto is { } photo)
        {
            photo.ToggleDoubleTapZoom(e.GetPosition(this), Now());
        }
    }

    DispatcherQueueTimer MakeSingleClickTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(240);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            if (_closing || ActivePhoto == null) return;
            _chromeHidden = !_chromeHidden;
            ApplyTransitionVisual(CurrentRestFrame());
        };
        return t;
    }

    // ---- Touch Manipulations (Pinch Zoom, Pan, Horizontal Swipe, Down/Edge Dismiss) ----

    void OnTouchManipulationStarted(object sender, ManipulationStartedRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _closing || _transPhase != TransitionPhase.None) return;
        _touchGesture = TouchGesture.None;
        _touchLastScale = 1.0;
        _dismissSamples.Clear();
        _wheelSamples.Clear();
    }

    void OnTouchManipulationDelta(object sender, ManipulationDeltaRoutedEventArgs e)
    {
        if (e.PointerDeviceType != PointerDeviceType.Touch || _closing || _transPhase != TransitionPhase.None) return;
        var photo = ActivePhoto;
        var now = Now();

        // 1. Pinch zoom on a photo
        if (photo != null && Math.Abs(e.Delta.Scale - 1.0) > 0.001)
        {
            _touchGesture = TouchGesture.Pinch;
            var factor = e.Delta.Scale;
            var pt = _strip.TransformToVisual(this).TransformPoint(e.Position);
            photo.ZoomByFactor(factor, pt);
            _touchLastScale = e.Cumulative.Scale;
            e.Handled = true;
            return;
        }

        // 2. Pan while photo is zoomed
        if (photo != null && photo.IsZoomed && _touchGesture != TouchGesture.Dismiss)
        {
            _touchGesture = TouchGesture.Pan;
            photo.PanBy(e.Delta.Translation.X, e.Delta.Translation.Y);
            e.Handled = true;
            return;
        }

        var cx = e.Cumulative.Translation.X;
        var cy = e.Cumulative.Translation.Y;
        var dx = e.Delta.Translation.X;
        var dy = e.Delta.Translation.Y;

        if (_touchGesture == TouchGesture.None)
        {
            var startX = e.Position.X - cx;
            var edgeW = ViewerMath.EdgeZoneWidth(_viewW);
            var nearLeft = startX <= edgeW;
            var nearRight = startX >= _viewW - edgeW;
            if ((nearLeft || nearRight) && !_caption.IsExpanded)
            {
                var dir = nearLeft ? 1 : -1;
                if (cx * dir > 6 && Math.Abs(cx) > Math.Abs(cy) * 0.9)
                {
                    _springingBack = false;
                    _touchGesture = TouchGesture.Dismiss;
                    _dismissFromEdge = true;
                    _dismissEdgeDir = dir;
                    _dismissRawX = cx;
                    _dismissRawY = cy;
                    UpdateDismissDrag(now, cx, cy);
                    e.Handled = true;
                    return;
                }
            }
            if (photo != null && !_caption.IsExpanded && cy > 7 && cy > Math.Abs(cx) * 1.15)
            {
                _springingBack = false;
                _touchGesture = TouchGesture.Dismiss;
                _dismissFromEdge = false;
                _dismissRawX = cx;
                _dismissRawY = cy;
                UpdateDismissDrag(now, cx, cy);
                e.Handled = true;
                return;
            }
            if (_items.Count > 1 && Math.Abs(cx) > 5 && Math.Abs(cx) > Math.Abs(cy) * 1.2)
            {
                _stripMotion = null;
                _touchGesture = TouchGesture.Swipe;
                ApplyWheelSwipeDelta(cx, now);
                e.Handled = true;
                return;
            }
            return;
        }

        if (_touchGesture == TouchGesture.Dismiss)
        {
            _dismissRawX += dx;
            _dismissRawY += dy;
            UpdateDismissDrag(now, dx, dy);
            e.Handled = true;
        }
        else if (_touchGesture == TouchGesture.Swipe)
        {
            ApplyWheelSwipeDelta(dx, now);
            e.Handled = true;
        }
    }

    void OnTouchManipulationCompleted(object sender, ManipulationCompletedRoutedEventArgs e)
    {
        if (_touchGesture == TouchGesture.Dismiss)
        {
            _touchGesture = TouchGesture.None;
            FinishDismissDrag();
        }
        else if (_touchGesture == TouchGesture.Swipe)
        {
            _touchGesture = TouchGesture.None;
            var v = 0.0;
            if (_wheelSamples.Count > 1)
            {
                var span = Math.Max(1.0 / 60.0, _wheelSamples[^1].T - _wheelSamples[0].T);
                v = _wheelSamples.Sum(s => s.Dx) / span;
            }
            _wheelSamples.Clear();
            SettleStripSwipe(v);
        }
        else
        {
            _touchGesture = TouchGesture.None;
        }
    }

    // ---- Interactive Dismiss Drag Helpers ----

    void UpdateDismissDrag(double now, double dx, double dy)
    {
        _dismissSamples.Add((now, dx, dy));
        while (_dismissSamples.Count > 1 && now - _dismissSamples[0].T > 0.1)
            _dismissSamples.RemoveAt(0);
        _dismiss = ViewerMath.EvaluateDismiss(_dismissRawX, _dismissRawY, _viewW, _viewH, _dismissFromEdge, _dismissEdgeDir);
        ApplyTransitionVisual(CurrentRestFrame());
    }

    void FinishDismissDrag()
    {
        double vx = 0, vy = 0;
        if (_dismissSamples.Count > 1)
        {
            var span = Math.Max(1.0 / 60.0, _dismissSamples[^1].T - _dismissSamples[0].T);
            vx = _dismissSamples.Sum(s => s.Dx) / span;
            vy = _dismissSamples.Sum(s => s.Dy) / span;
        }
        _dismissSamples.Clear();

        if (ViewerMath.ShouldCommitDismiss(_dismissRawX, _dismissRawY, vx, vy, _viewW, _viewH, _dismissFromEdge, _dismissEdgeDir))
            Close();
        else
            CancelDismissDrag();
    }

    void CancelDismissDrag()
    {
        if (!_dismiss.IsActive) return;
        _springFromX = _dismissRawX;
        _springFromY = _dismissRawY;
        _springStart = Now();
        _springingBack = true;
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

        // Tear down all pages and rebuild cleanly around the updated list.
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

    static Button IconButton(string glyph, string tip, Action click, string automationId)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 15, Foreground = new SolidColorBrush(Colors.White) },
            Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0),
            Width = 36,
            Height = 36,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(18),
        };
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, automationId);
        b.Click += (_, _) => click();
        return b;
    }

    static Button RoundButton(string glyph, string tip, double diameter, double iconSize, Action click, string automationId)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = iconSize, Foreground = new SolidColorBrush(Colors.White) },
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x66, 0, 0, 0)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x2E, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Width = diameter,
            Height = diameter,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(diameter * 0.5),
        };
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
