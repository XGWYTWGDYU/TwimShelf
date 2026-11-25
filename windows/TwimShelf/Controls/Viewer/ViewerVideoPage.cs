// One video page of the unified viewer's horizontal strip (matching MacPlayerView, Web Player.tsx,
// and Flutter VideoPage):
//  * While inactive (neighbour page in the strip), displays the video's cached poster/preview so
//    horizontal swipes never slide in a black rectangle.
//  * When active, adopts the Browse card's live MediaPlayer (or a parked player) via InlineVideo
//    for zero-restart continuous playback; mutes & keeps playing live during zoom-close, then hands
//    the player straight back to any visible matching card.
//  * Gestures: double-click/double-tap = play/pause (with HUD), press-and-hold (250ms) = 2.5× boost
//    (sticky HUD "2.5× ▶▶", returns to chosen speed on release), scrub slider, seek ±5s, volume ±10%.
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using TwimShelf.Services;
using Windows.Foundation;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace TwimShelf.Controls.ViewerEngine;

public sealed partial class ViewerVideoPage : Grid
{
    public FeedItem Item { get; }
    public event Action? StateChanged;
    public event Action? UserActivity;

    public static double SavedRate { get; set; } = 1.0;
    public static bool SavedMuted { get; set; }

    readonly Image _poster = new()
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        IsHitTestVisible = false,
    };
    readonly MediaPlayerElement _player = new()
    {
        AreTransportControlsEnabled = false,
        Stretch = Stretch.Uniform,
        AutoPlay = true,
        Opacity = 0,
        IsHitTestVisible = false,
    };
    readonly Border _hud;
    readonly TextBlock _hudText = new()
    {
        Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(0xF5, 255, 255, 255)),
        FontSize = 14,
        FontWeight = FontWeights.SemiBold,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    readonly bool _cropSquarePreview;
    CancellationTokenSource? _posterLoading;
    DispatcherQueueTimer? _clock;
    DispatcherQueueTimer? _holdTimer;
    DispatcherQueueTimer? _hudTimer;
    MediaPlayer? _media;
    bool _active;
    bool _boosting;
    bool _preparedClose;
    bool _hasFrame;
    double _viewW, _viewH;
    uint _videoW, _videoH;

    public bool IsActive => _active;
    public bool IsPlaying => _media?.PlaybackSession.PlaybackState is MediaPlaybackState.Playing or MediaPlaybackState.Opening or MediaPlaybackState.Buffering;
    public bool IsMuted => _media?.IsMuted ?? SavedMuted;
    public double Rate => SavedRate;
    public TimeSpan Position
    {
        get { try { return _media?.PlaybackSession.Position ?? TimeSpan.Zero; } catch { return TimeSpan.Zero; } }
    }
    public TimeSpan Duration
    {
        get { try { return _media?.PlaybackSession.NaturalDuration ?? TimeSpan.Zero; } catch { return TimeSpan.Zero; } }
    }

    public ViewerVideoPage(FeedItem item, ImageSource? previewImage = null, string? squarePreviewPath = null, bool cropSquarePreview = false)
    {
        Item = item;
        _cropSquarePreview = cropSquarePreview && previewImage == null && !string.IsNullOrEmpty(squarePreviewPath);

        IsHitTestVisible = false;
        _hud = new Border
        {
            Child = _hudText,
            RequestedTheme = ElementTheme.Dark,
            Background = new AcrylicBrush
            {
                TintColor = Windows.UI.Color.FromArgb(0xFF, 0x20, 0x20, 0x20),
                TintOpacity = 0.72,
                TintLuminosityOpacity = 0.78,
                FallbackColor = Windows.UI.Color.FromArgb(0xE0, 0x24, 0x24, 0x24),
            },
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x28, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 9, 16, 9),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 48, 0, 0),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 32),
            OpacityTransition = new ScalarTransition { Duration = TimeSpan.FromMilliseconds(160) },
            Opacity = 0,
            IsHitTestVisible = false,
        };

        Children.Add(_poster);
        Children.Add(_player);
        Children.Add(_hud);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_player, "playerSurface");

        if (previewImage != null)
        {
            _poster.Stretch = Stretch.Uniform;
            _poster.Source = previewImage;
        }
        else if (!string.IsNullOrEmpty(squarePreviewPath) && File.Exists(squarePreviewPath))
        {
            _poster.Stretch = _cropSquarePreview ? Stretch.Fill : Stretch.Uniform;
            try { _poster.Source = new BitmapImage(new Uri(squarePreviewPath)); } catch { }
        }
        else
        {
            _poster.Stretch = Stretch.Uniform;
            _ = LoadPosterAsync();
        }

        SizeChanged += (_, e) => UpdatePosterSize(e.NewSize.Width, e.NewSize.Height);
    }

    async Task LoadPosterAsync()
    {
        _posterLoading?.Cancel();
        var cancel = _posterLoading = new CancellationTokenSource();
        try
        {
            var src = await Thumbnails.VideoPoster(Item.Path, 1024, cancel.Token);
            if (!cancel.IsCancellationRequested && src != null && _poster.Source == null)
            {
                _poster.Stretch = Stretch.Uniform;
                _poster.Source = src;
            }
        }
        catch { }
    }

    public void UpdatePosterSize(double w, double h)
    {
        if (w <= 0 || h <= 0) return;
        _viewW = w;
        _viewH = h;
        if (_cropSquarePreview && !_hasFrame)
        {
            var fitted = FittedRect(new Rect(0, 0, w, h));
            var side = Math.Min(fitted.Width, fitted.Height);
            _poster.Width = side;
            _poster.Height = side;
        }
        else
        {
            _poster.Width = double.NaN;
            _poster.Height = double.NaN;
        }
    }

    Rect FittedRect(Rect bounds)
    {
        double w = _videoW > 0 ? _videoW : Item.Width;
        double h = _videoH > 0 ? _videoH : Item.Height;
        if (w > 0 && h > 0) return ViewerMath.FitMedia(bounds, w, h);
        return ViewerMath.FitAspect(bounds, Item.CardAspectRatio);
    }

    public Rect MediaFrame(Rect viewportBounds)
    {
        var w = viewportBounds.Width > 0 ? viewportBounds.Width : _viewW;
        var h = viewportBounds.Height > 0 ? viewportBounds.Height : _viewH;
        if (w <= 0 || h <= 0) return viewportBounds;
        return FittedRect(new Rect(0, 0, w, h));
    }

    /// Becomes the active page on screen: adopts the lent/parked player or opens a fresh one.
    public void Activate(MediaPlayer? lent = null)
    {
        if (_active) return;
        _active = true;
        _preparedClose = false;
        _boosting = false;

        var m = lent ?? InlineVideo.Lend(Item.Path);
        var adopted = m != null;
        if (m != null)
        {
            try
            {
                m.IsMuted = SavedMuted;
                m.IsLoopingEnabled = true;
                m.Volume = Prefs.Instance.PlayerVolume;
                m.PlaybackSession.PlaybackRate = SavedRate;
                if (m.PlaybackSession.PlaybackState != MediaPlaybackState.Playing) m.Play();
            }
            catch { }
        }
        else
        {
            m = new MediaPlayer
            {
                Source = MediaSource.CreateFromUri(new Uri(Item.Path)),
                IsLoopingEnabled = true,
                AutoPlay = true,
                IsMuted = SavedMuted,
                Volume = Prefs.Instance.PlayerVolume,
            };
            if (InlineVideo.PeekPosition(Item.Path) is { } from)
            {
                void SeekOnce(MediaPlayer x, object _)
                {
                    x.MediaOpened -= SeekOnce;
                    try { x.PlaybackSession.Position = from; } catch { }
                }
                m.MediaOpened += SeekOnce;
            }
        }

        _media = m;
        m.MediaOpened += OnMediaOpened;
        m.PlaybackSession.NaturalVideoSizeChanged += OnNaturalVideoSizeChanged;
        m.PlaybackSession.PositionChanged += OnFirstFrame;
        m.PlaybackSession.PlaybackStateChanged += OnPlaybackStateChanged;
        UpdateVideoDimensions(m);

        _player.SetMediaPlayer(m);
        if (adopted)
        {
            _hasFrame = true;
            _player.Opacity = 1;
            _poster.Visibility = Visibility.Collapsed;
        }
        else
        {
            _hasFrame = false;
            _player.Opacity = 0;
            _poster.Visibility = Visibility.Visible;
        }

        _clock ??= MakeClock();
        _clock.Start();
        StateChanged?.Invoke();
    }

    DispatcherQueueTimer MakeClock()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(100);
        t.Tick += (_, _) => StateChanged?.Invoke();
        return t;
    }

    void OnMediaOpened(MediaPlayer sender, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_media != sender) return;
            try
            {
                sender.PlaybackSession.PlaybackRate = _boosting ? 2.5 : SavedRate;
                sender.Volume = Prefs.Instance.PlayerVolume;
                sender.IsMuted = _preparedClose || SavedMuted;
            }
            catch { }
            UpdateVideoDimensions(sender);
            RevealVideoSurface();
            StateChanged?.Invoke();
        });
    }

    void OnNaturalVideoSizeChanged(MediaPlaybackSession session, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_media?.PlaybackSession != session) return;
            UpdateVideoDimensions(_media);
        });
    }

    void OnFirstFrame(MediaPlaybackSession session, object args)
    {
        if (session.Position <= TimeSpan.Zero) return;
        session.PositionChanged -= OnFirstFrame;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_media?.PlaybackSession != session) return;
            RevealVideoSurface();
        });
    }

    void OnPlaybackStateChanged(MediaPlaybackSession session, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_media?.PlaybackSession != session) return;
            StateChanged?.Invoke();
        });
    }

    void UpdateVideoDimensions(MediaPlayer m)
    {
        try
        {
            var s = m.PlaybackSession;
            if (s.NaturalVideoWidth > 0 && s.NaturalVideoHeight > 0)
            {
                _videoW = s.NaturalVideoWidth;
                _videoH = s.NaturalVideoHeight;
            }
        }
        catch { }
    }

    void RevealVideoSurface()
    {
        _hasFrame = true;
        _player.Opacity = 1;
        _poster.Visibility = Visibility.Collapsed;
    }

    // ---- Gestures: double-click play/pause, press-and-hold 2.5× boost ----

    public void BeginPointerHold()
    {
        if (!_active || _media == null) return;
        CancelHold();
        _holdTimer ??= MakeHoldTimer();
        _holdTimer.Start();
    }

    public bool EndPointerHold()
    {
        _holdTimer?.Stop();
        if (!_boosting) return false;
        _boosting = false;
        try { if (_media != null) _media.PlaybackSession.PlaybackRate = SavedRate; } catch { }
        HideHudAfter(400);
        return true;
    }

    public void CancelHold()
    {
        _holdTimer?.Stop();
        if (_boosting)
        {
            _boosting = false;
            try { if (_media != null) _media.PlaybackSession.PlaybackRate = SavedRate; } catch { }
            HideHudAfter(200);
        }
    }

    DispatcherQueueTimer MakeHoldTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(250);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            if (!_active || _media == null) return;
            _boosting = true;
            try
            {
                _media.PlaybackSession.PlaybackRate = 2.5;
                if (_media.PlaybackSession.PlaybackState == MediaPlaybackState.Paused) _media.Play();
            }
            catch { }
            FlashHud("2.5\u00D7 \u25B6\u25B6", sticky: true);
        };
        return t;
    }

    // ---- Controls API ----

    public void TogglePlay(bool showHud = true)
    {
        if (_media == null) return;
        var playing = _media.PlaybackSession.PlaybackState == MediaPlaybackState.Playing;
        if (playing)
        {
            _media.Pause();
            if (showHud) FlashHud("\u275A\u275A");
        }
        else
        {
            try { _media.PlaybackSession.PlaybackRate = SavedRate; } catch { }
            _media.Play();
            if (showHud) FlashHud("\u25B6\uFE0E");
        }
        StateChanged?.Invoke();
        UserActivity?.Invoke();
    }

    public void SeekBy(double seconds)
    {
        if (_media == null) return;
        var d = Duration.TotalSeconds;
        if (d <= 0) return;
        var target = Math.Clamp(Position.TotalSeconds + seconds, 0, d);
        try { _media.PlaybackSession.Position = TimeSpan.FromSeconds(target); } catch { }
        FlashHud($"{FormatTime(TimeSpan.FromSeconds(target))} / {FormatTime(Duration)}");
        StateChanged?.Invoke();
        UserActivity?.Invoke();
    }

    public void SeekToFraction(double fraction)
    {
        if (_media == null) return;
        var d = Duration;
        if (d.TotalMilliseconds <= 0) return;
        try { _media.PlaybackSession.Position = d * Math.Clamp(fraction, 0, 1); } catch { }
        StateChanged?.Invoke();
    }

    public void StepVolume(double delta)
    {
        if (_media == null) return;
        var next = Math.Round(Math.Clamp(Prefs.Instance.PlayerVolume + delta, 0.0, 1.0) * 10.0) / 10.0;
        Prefs.Instance.PlayerVolume = next;
        _media.Volume = next;
        if (next > 0 && _media.IsMuted) { _media.IsMuted = false; SavedMuted = false; }
        FlashHud($"\U0001F50A {(int)Math.Round(next * 100)}%");
        StateChanged?.Invoke();
        UserActivity?.Invoke();
    }

    public void ToggleMute()
    {
        if (_media == null) return;
        var muted = !_media.IsMuted;
        _media.IsMuted = muted;
        SavedMuted = muted;
        FlashHud(muted ? "\U0001F507" : $"\U0001F50A {(int)Math.Round(_media.Volume * 100)}%");
        StateChanged?.Invoke();
        UserActivity?.Invoke();
    }

    public void SetRate(double rate)
    {
        SavedRate = rate;
        try { if (_media != null && !_boosting) _media.PlaybackSession.PlaybackRate = rate; } catch { }
        StateChanged?.Invoke();
        UserActivity?.Invoke();
    }

    public void FlashHud(string text, bool sticky = false)
    {
        _hudText.Text = text;
        _hud.Opacity = 1;
        _hudTimer?.Stop();
        if (!sticky) HideHudAfter(700);
    }

    void HideHudAfter(int ms)
    {
        _hudTimer ??= MakeHudTimer();
        _hudTimer.Stop();
        _hudTimer.Interval = TimeSpan.FromMilliseconds(ms);
        _hudTimer.Start();
    }

    DispatcherQueueTimer MakeHudTimer()
    {
        var t = DispatcherQueue.CreateTimer();
        t.IsRepeating = false;
        t.Tick += (_, _) => _hud.Opacity = 0;
        return t;
    }

    public static string FormatTime(TimeSpan t) =>
        t.TotalHours >= 1 ? t.ToString(@"h\:mm\:ss") : t.ToString(@"m\:ss");

    /// Called at the start of close zoom animation: mutes & resets rate while keeping live playback
    /// running inside the shrinking zoom rect.
    public void PrepareClose()
    {
        _preparedClose = true;
        CancelHold();
        _hud.Opacity = 0;
        if (_media != null) InlineVideo.PrepareReturn(_media, Item.Path);
    }

    /// Leaves screen (paged away or viewer finished closing).
    public void Deactivate(bool closing)
    {
        _active = false;
        CancelHold();
        _clock?.Stop();
        _hudTimer?.Stop();
        _hud.Opacity = 0;

        if (_media is { } m)
        {
            _media = null;
            try
            {
                m.MediaOpened -= OnMediaOpened;
                m.PlaybackSession.NaturalVideoSizeChanged -= OnNaturalVideoSizeChanged;
                m.PlaybackSession.PositionChanged -= OnFirstFrame;
                m.PlaybackSession.PlaybackStateChanged -= OnPlaybackStateChanged;
            }
            catch { }
            _player.SetMediaPlayer(null);
            InlineVideo.Return(m, Item.Path, closing);
        }
        _hasFrame = false;
        _player.Opacity = 0;
        _poster.Visibility = Visibility.Visible;
        if (_poster.Source == null) _ = LoadPosterAsync();
    }

    public void Teardown(bool closing)
    {
        Deactivate(closing);
        _posterLoading?.Cancel();
        _posterLoading = null;
        _poster.Source = null;
    }
}
