// The media viewer: over the whole window (as the Mac app's), one media at a time — a photo to zoom
// (wheel with Ctrl, double click, pinch on a touch screen) and pan, a video played by Windows (Media
// Foundation) under the app's own controls, as the Flutter app's: play, time, position, speed and
// sound, then 分享 and 关闭. ← → (or the arrows, the wheel sideways) go through the list it was
// opened with; Esc or 关闭 returns. A photo has only 分享 and 关闭 (the rest is in its right-click menu).
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using Windows.Media.Core;
using Windows.Media.Playback;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public sealed partial class Viewer : UserControl
{
    static Viewer? _open;
    public static bool IsOpen => _open != null;
    public static Viewer? Shown => _open;
    public static event Action? Closed;

    readonly List<FeedItem> _items;
    int _index;
    readonly Grid _stage = new();
    readonly ScrollViewer _zoom;
    readonly Image _image = new() { Stretch = Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    // the viewport's size, the photo fitted and centred in it (an Image of a set size draws at its left)
    readonly Grid _frame = new();
    readonly MediaPlayerElement _player = new() { AreTransportControlsEnabled = false, Stretch = Stretch.Uniform, AutoPlay = true };
    readonly TextBlock _counter = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), VerticalAlignment = VerticalAlignment.Center };
    readonly TextBlock _caption = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true };
    readonly Button _prev, _next;
    readonly Grid _top, _bottom;
    // the video's row: play, time, position, length, speed, sound
    readonly Grid _videoRow = new() { ColumnSpacing = 8 };
    readonly Button _play, _speed, _mute;
    readonly TextBlock _at = TimeText(), _length = TimeText();
    readonly Slider _position = new() { Minimum = 0, Maximum = 1, StepFrequency = 0.001, IsThumbToolTipEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    bool _settingPosition;
    static double _rate = 1;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _clock;
    readonly Border _drag = new() { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), Margin = new Thickness(90, 0, 0, 0) };
    MediaPlayer? _media;
    Panel? _host; // where Open put it (Parent is not reliable for this)
    Control? _returnFocus; // what had the focus before: it gets it back (not the first field on the page)
    CancellationTokenSource? _loading;

    /// place: where the media are shown (the bin's get its own menu: restore, delete for good).
    public static void Open(List<FeedItem> items, int index, TwimShelf.Models.Place? place = null)
    {
        if (_open != null || items.Count == 0 || MainWindow.Current?.Content is not Panel root) return;
        // the card playing the opened video lends its player (before the cards' videos stop)
        var first = items[Math.Clamp(index, 0, items.Count - 1)];
        var lent = first.IsVideo ? InlineVideo.Lend(first.Path) : null;
        InlineVideo.StopAll();
        var v = new Viewer(items, index, lent, first.Path) { _place = place };
        Grid.SetRowSpan(v, 2);
        v._returnFocus = FocusManager.GetFocusedElement(root.XamlRoot) as Control;
        root.Children.Add(v);
        v._host = root;
        _open = v;
        MainWindow.Current.SetTitleBar(v._drag);
        // no minimize/maximize/close while it is open (a click meant for the viewer would close the
        // window): the title bar collapsed hides them; the top strip still moves the window
        MainWindow.Current.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
        v.Loaded += (_, _) => v.Focus(FocusState.Programmatic);
    }

    Viewer(List<FeedItem> items, int index, MediaPlayer? lent = null, string? lentPath = null)
    {
        _lent = lent;
        _lentPath = lentPath;
        _items = items;
        _index = Math.Clamp(index, 0, items.Count - 1);
        IsTabStop = true;
        _zoom = new ScrollViewer
        {
            ZoomMode = ZoomMode.Enabled,
            MinZoomFactor = 1,
            MaxZoomFactor = 8,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollMode.Auto,
            VerticalScrollMode = ScrollMode.Auto,
            Content = _frame,
        };
        _frame.Children.Add(_image);
        _zoom.SizeChanged += (_, e) => FitImage(e.NewSize.Width, e.NewSize.Height);
        _zoom.Loaded += (_, _) => FitImage(_zoom.ActualWidth, _zoom.ActualHeight);
        _zoom.DoubleTapped += (_, e) =>
        {
            if (_zoom.ZoomFactor > 1.01) _zoom.ChangeView(0, 0, 1);
            else { var p = e.GetPosition(_frame); _zoom.ChangeView(p.X * 2.5 - _zoom.ViewportWidth / 2, p.Y * 2.5 - _zoom.ViewportHeight / 2, 2.5f); }
        };
        _stage.Children.Add(_zoom);
        _stage.Children.Add(_player);
        _player.Tapped += (_, _) => TogglePlay();
        _prev = Arrow("", HorizontalAlignment.Left, () => Go(-1));
        _next = Arrow("", HorizontalAlignment.Right, () => Go(1));
        _stage.Children.Add(_prev);
        _stage.Children.Add(_next);

        // the window's caption buttons stay at the top right: what is left of them moves the window
        _top = new Grid { Height = 48, VerticalAlignment = VerticalAlignment.Top, Background = Fade(true), Opacity = 0.9 };
        _top.Children.Add(_drag);

        _play = Tool("\uE768", L("viewer.play"), TogglePlay);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_play, "videoPlay");
        _speed = new Button
        {
            Content = new TextBlock { Text = Speed(_rate), Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold },
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), MinWidth = 48, Height = 40,
        };
        ToolTipService.SetToolTip(_speed, L("player.speed"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_speed, L("player.speed"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_speed, "videoSpeed");
        _speed.Flyout = SpeedMenu();
        _mute = Tool("\uE767", L("audio.turnOn"), () => { if (_media != null) { _media.IsMuted = !_media.IsMuted; ShowMute(); } });
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_mute, "videoMute");
        _position.ValueChanged += (_, e) => { if (!_settingPosition && _media != null) _media.PlaybackSession.Position = _media.PlaybackSession.NaturalDuration * e.NewValue; };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_position, L("windows.viewer.position"));
        UIElement[] row = [_play, _at, _position, _length, _speed, _mute];
        for (var i = 0; i < row.Length; i++)
        {
            _videoRow.ColumnDefinitions.Add(new ColumnDefinition { Width = row[i] == _position ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            Grid.SetColumn((FrameworkElement)row[i], i);
            _videoRow.Children.Add(row[i]);
        }

        var share = Tool("\uE72D", L("viewer.share"), () => { });
        share.Flyout = ShareMenu.For(() => Current);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(share, "viewerShare");
        var close = Tool("\uE711", L("viewer.close"), Close);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(close, "photoClose");
        var actions = new Grid();
        actions.ColumnDefinitions.Add(new ColumnDefinition());
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _counter.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        actions.Children.Add(_counter);
        Grid.SetColumn(share, 1);
        actions.Children.Add(share);
        Grid.SetColumn(close, 2);
        actions.Children.Add(close);

        _caption.Margin = new Thickness(0, 0, 0, 6);
        _bottom = new Grid { Padding = new Thickness(16, 36, 16, 8), VerticalAlignment = VerticalAlignment.Bottom, Background = Fade(false) };
        _bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bottom.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _bottom.Children.Add(_caption);
        Grid.SetRow(_videoRow, 1);
        _bottom.Children.Add(_videoRow);
        Grid.SetRow(actions, 2);
        _bottom.Children.Add(actions);
        // (a UserControl draws no background of its own: the page behind would show through)
        Content = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Black), Children = { _stage, _top, _bottom } };

        KeyDown += OnKey;
        // focusable (a UserControl isn't by default, so the focus it's given on opening went nowhere
        // and Esc did nothing), and Esc closes it wherever the focus is
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        var esc = new KeyboardAccelerator { Key = Windows.System.VirtualKey.Escape };
        esc.Invoked += (_, e) => { Close(); e.Handled = true; };
        KeyboardAccelerators.Add(esc);
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        PointerWheelChanged += OnWheel;
        PointerMoved += (_, _) => ShowChrome();
        RightTapped += (_, e) => { MediaActions.Menu(Current, _place).ShowAt(this, e.GetPosition(this)); e.Handled = true; };
        Show();
    }

    static Brush Fade(bool top) => new LinearGradientBrush
    {
        StartPoint = new Windows.Foundation.Point(0, top ? 0 : 1),
        EndPoint = new Windows.Foundation.Point(0, top ? 1 : 0),
        GradientStops =
        {
            new GradientStop { Color = Windows.UI.Color.FromArgb(0xB3, 0, 0, 0), Offset = 0 },
            new GradientStop { Color = Windows.UI.Color.FromArgb(0, 0, 0, 0), Offset = 1 },
        },
    };

    static Button Tool(string glyph, string tip, Action click)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 16, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Width = 40, Height = 40, Padding = new Thickness(0),
        };
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        b.Click += (_, _) => click();
        return b;
    }

    static Button Arrow(string glyph, HorizontalAlignment side, Action click)
    {
        var b = Tool(glyph, L(side == HorizontalAlignment.Left ? "viewer.previous" : "viewer.next"), click);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, side == HorizontalAlignment.Left ? "viewerPrev" : "viewerNext");
        b.HorizontalAlignment = side;
        b.VerticalAlignment = VerticalAlignment.Center;
        b.Width = b.Height = 48;
        b.CornerRadius = new CornerRadius(24);
        b.Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x50, 0, 0, 0));
        b.Margin = new Thickness(16);
        return b;
    }

    static TextBlock TimeText() => new()
    {
        Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), VerticalAlignment = VerticalAlignment.Center,
    };

    static string Speed(double r) => (r == Math.Round(r) ? ((int)r).ToString() : r.ToString(System.Globalization.CultureInfo.InvariantCulture)) + "\u00D7"; // i18n-exempt: a speed

    static string Time(TimeSpan t) => t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");

    MenuFlyout SpeedMenu()
    {
        var m = new MenuFlyout();
        foreach (var r in new[] { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0 })
        {
            var item = new RadioMenuFlyoutItem { Text = Speed(r), GroupName = "speed", IsChecked = r == _rate };
            item.Click += (_, _) =>
            {
                _rate = r;
                if (_media != null) _media.PlaybackSession.PlaybackRate = r;
                ((TextBlock)_speed.Content).Text = Speed(r);
                foreach (var o in m.Items) if (o is RadioMenuFlyoutItem x) x.IsChecked = x.Text == Speed(r);
            };
            m.Items.Add(item);
        }
        return m;
    }

    void TogglePlay()
    {
        if (_media == null) return;
        if (_media.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) _media.Pause(); else _media.Play();
        ShowPlay();
    }

    void ShowPlay()
    {
        var playing = _media?.PlaybackSession.PlaybackState is MediaPlaybackState.Playing or MediaPlaybackState.Opening or MediaPlaybackState.Buffering;
        ((FontIcon)_play.Content).Glyph = playing ? "\uE769" : "\uE768";
        var tip = playing ? L("viewer.pause") : L("viewer.play");
        ToolTipService.SetToolTip(_play, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_play, tip);
    }

    void ShowMute()
    {
        var muted = _media?.IsMuted == true;
        ((FontIcon)_mute.Content).Glyph = muted ? "\uE74F" : "\uE767";
        ToolTipService.SetToolTip(_mute, muted ? L("audio.turnOn") : null);
    }

    /// The time, the position and the play button, four times a second while a video is shown.
    void Tick()
    {
        if (_media == null) return;
        var s = _media.PlaybackSession;
        var length = s.NaturalDuration;
        _at.Text = Time(s.Position);
        _length.Text = Time(length);
        _settingPosition = true;
        _position.Value = length.TotalMilliseconds > 0 ? Math.Clamp(s.Position / length, 0, 1) : 0;
        _settingPosition = false;
        ShowPlay();
    }

    FeedItem Current => _items[_index];

    void Show()
    {
        _loading?.Cancel();
        var cancel = _loading = new CancellationTokenSource();
        var item = Current;
        _counter.Text = _items.Count > 1 ? $"{_index + 1} / {_items.Count}" : "";
        _caption.Text = string.Join("  ", new[] { item.AuthorName, item.ScreenName == null ? null : "@" + item.ScreenName, item.Text }.Where(s => !string.IsNullOrEmpty(s)));
        _caption.Visibility = _caption.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        _prev.Visibility = _index > 0 ? Visibility.Visible : Visibility.Collapsed;
        _next.Visibility = _index < _items.Count - 1 ? Visibility.Visible : Visibility.Collapsed;
        StopVideo();
        _image.Source = null;
        _zoom.ChangeView(0, 0, 1, true);
        if (item.IsVideo)
        {
            _zoom.Visibility = Visibility.Collapsed;
            _player.Visibility = Visibility.Visible;
            // the card's own player when the card plays this video now (it goes on, nothing restarts);
            // else a new one, from where this video was left before
            var m = _lent is { } lent && string.Equals(_lentPath, item.Path, StringComparison.OrdinalIgnoreCase) ? lent : null;
            _lent = null;
            if (m != null)
            {
                m.IsMuted = false;
                m.IsLoopingEnabled = true;
            }
            else
            {
                m = new MediaPlayer { Source = MediaSource.CreateFromUri(new Uri(item.Path)), IsLoopingEnabled = true, AutoPlay = true };
                if (InlineVideo.TakePosition(item.Path) is { } from)
                {
                    void Opened(MediaPlayer x, object _) { x.MediaOpened -= Opened; x.PlaybackSession.Position = from; }
                    m.MediaOpened += Opened;
                }
            }
            _mediaPath = item.Path;
            m.PlaybackSession.PlaybackRate = _rate;
            m.MediaOpened += (_, _) => DispatcherQueue.TryEnqueue(() => { if (_media == m) m.PlaybackSession.PlaybackRate = _rate; });
            _media = m;
            _player.SetMediaPlayer(m);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_player, "playerSurface");
            _videoRow.Visibility = Visibility.Visible;
            ShowMute();
            Tick();
            if (_clock == null)
            {
                _clock = DispatcherQueue.CreateTimer();
                _clock.Interval = TimeSpan.FromMilliseconds(250);
                _clock.Tick += (_, _) => Tick();
            }
            _clock.Start();
        }
        else
        {
            _videoRow.Visibility = Visibility.Collapsed;
            _clock?.Stop();
            _player.Visibility = Visibility.Collapsed;
            _zoom.Visibility = Visibility.Visible;
            _ = LoadPhoto(item, cancel.Token);
        }
    }

    async Task LoadPhoto(FeedItem item, CancellationToken cancel)
    {
        var path = await Thumbnails.Displayable(item.Path, 8192);
        if (cancel.IsCancellationRequested) return;
        var bmp = new BitmapImage();
        bmp.ImageOpened += (_, _) => FitImage(_zoom.ActualWidth, _zoom.ActualHeight);
        bmp.UriSource = new Uri(path);
        _image.Source = bmp;
    }

    /// The photo fills the viewer (fitted, centred) at zoom 1; zooming magnifies from there.
    void FitImage(double w, double h)
    {
        if (w <= 0 || h <= 0) return;
        _frame.Width = w;
        _frame.Height = h;
    }

    void StopVideo(bool closing = false)
    {
        if (_media == null) return;
        var m = _media;
        _media = null;
        _player.SetMediaPlayer(null);
        // back to its card, or its position kept for the card
        InlineVideo.Return(m, _mediaPath ?? "", closing);
    }
    MediaPlayer? _lent;
    TwimShelf.Models.Place? _place;
    string? _lentPath, _mediaPath;

    void Go(int by)
    {
        var i = Math.Clamp(_index + by, 0, _items.Count - 1);
        if (i == _index) return;
        _index = i;
        Show();
    }

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case Windows.System.VirtualKey.Escape: Close(); break;
            case Windows.System.VirtualKey.Left: Go(-1); break;
            case Windows.System.VirtualKey.Right: Go(1); break;
            case Windows.System.VirtualKey.Space when _media != null: TogglePlay(); break;
            case Windows.System.VirtualKey.Delete when _place != TwimShelf.Models.Place.Trash: _ = Trash(); break;
            default: return;
        }
        e.Handled = true;
    }

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(this).Properties;
        if (p.IsHorizontalMouseWheel) { Go(p.MouseWheelDelta > 0 ? 1 : -1); e.Handled = true; return; }
        if (e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control) || Current.IsVideo) return;
        // a plain wheel over a photo that is not zoomed goes to the next or previous media
        if (_zoom.ZoomFactor <= 1.01) { Go(p.MouseWheelDelta < 0 ? 1 : -1); e.Handled = true; }
    }

    DispatcherTimerLite? _hide;
    void ShowChrome()
    {
        _top.Opacity = 1;
        _bottom.Opacity = 1;
        _hide ??= new DispatcherTimerLite(this, TimeSpan.FromSeconds(3), () => { if (_media?.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) { _top.Opacity = 0; _bottom.Opacity = 0; } });
        _hide.Restart();
    }

    async Task Trash()
    {
        var item = Current;
        var receipt = await MediaActions.Run(ActionKind.Trash, [item.MediaId], done: n => L("trash.moved", n));
        // the one deleted leaves (not whatever is shown by now: paging goes on meanwhile), and nothing
        // when it failed
        if (receipt == null || _host == null) return;
        var at = _items.FindIndex(m => m.MediaId == item.MediaId);
        if (at < 0) return;
        _items.RemoveAt(at);
        if (_items.Count == 0) { Close(); return; }
        var showing = at == _index;
        if (at < _index) _index--;
        _index = Math.Min(_index, _items.Count - 1);
        if (showing) { Show(); return; }
        // another one is shown by now: it stays, only the count and arrows change
        _counter.Text = _items.Count > 1 ? $"{_index + 1} / {_items.Count}" : "";
        _prev.Visibility = _index > 0 ? Visibility.Visible : Visibility.Collapsed;
        _next.Visibility = _index < _items.Count - 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Close()
    {
        _clock?.Stop();
        _hide?.Stop();
        _host?.Children.Remove(this);
        _host = null;
        try { _returnFocus?.Focus(FocusState.Programmatic); } catch { }
        _open = null;
        // the video back to its card only now: while the viewer still counted as open, the layout of
        // its leaving had the card stop (and reload) the player it was just given
        StopVideo(closing: true);
        if (MainWindow.Current is { } w)
        {
            w.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
            w.RestoreTitleBar();
        }
        Closed?.Invoke();
    }
}

/// A one-shot timer that can be started again (the viewer's controls fading out).
public sealed class DispatcherTimerLite
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _t;
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
