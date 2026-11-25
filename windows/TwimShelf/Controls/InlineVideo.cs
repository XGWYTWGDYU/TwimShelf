// Continuous inline & viewer video playback engine (matching Apple InlineVideos & Flutter
// VideoSession):
//  * Muted looping autoplay for visible Browse cards (>=50% on screen), paused while scrolling.
//  * Remembers every video's playback position across scroll-offs, card recycles, and viewer paging.
//  * Parks up to 4 recently used MediaPlayers at their exact paused frame (plus up to 12 idle
//    players) so scrolling back or paging back resumes immediately without reopening Media Foundation.
//  * Seamless single-player handover between Browse cards and the unified Viewer: opening a playing
//    card hands its live MediaPlayer straight into the viewer; closing mutes and keeps playing live
//    inside the shrinking zoom rect, then hands the live MediaPlayer directly back to the matching
//    visible card (even if the user paged to a different visible video card inside the viewer!).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace TwimShelf.Controls;

public sealed partial class InlineVideo : Grid
{
    const int MaxParked = 4;
    const int MaxIdle = 12;

    static readonly Stack<MediaPlayer> Idle = new();
    static readonly List<(string Path, MediaPlayer Player)> Parked = [];
    static readonly HashSet<InlineVideo> Playing = [];
    static readonly HashSet<InlineVideo> Mounted = [];
    static readonly Dictionary<string, TimeSpan> Positions = new(StringComparer.OrdinalIgnoreCase);

    static InlineVideo? _lentFrom;

    readonly MediaPlayerElement _element = new()
    {
        Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform,
        AreTransportControlsEnabled = false,
        IsHitTestVisible = false,
    };

    MediaPlayer? _player;
    string? _path;
    string? _boundPath;
    string? _lentPath;
    bool _cardOnScreen;
    bool _pausedInPlace;
    TimeSpan _revealFrom;

    public InlineVideo()
    {
        Children.Add(_element);
        _element.Visibility = Visibility.Collapsed;
        IsHitTestVisible = false;
        Loaded += (_, _) => Mounted.Add(this);
        // A card taken out of the page (the feed lays out anew) stops its video and saves its place.
        Unloaded += (_, _) =>
        {
            Mounted.Remove(this);
            if (_lentFrom != this) Stop();
        };
    }

    /// While the feed scrolls, no new player starts (fast flings don't churn Media Foundation on
    /// the UI thread); visible cards start once scrolling rests.
    public static bool Held;

    static string KeyOf(string path)
    {
        if (string.IsNullOrEmpty(path)) return "";
        try { return Path.GetFullPath(path); } catch { return path; }
    }

    /// Records which video path this card slot currently represents (even while paused or hidden),
    /// so closing the viewer on any visible video card can hand the live player straight to it.
    public void BindPath(string? path, bool onScreen)
    {
        _boundPath = string.IsNullOrEmpty(path) ? null : KeyOf(path);
        _cardOnScreen = onScreen;
    }

    public void SetCardOnScreen(bool onScreen) => _cardOnScreen = onScreen;

    /// Last known playback position for a video, without consuming it.
    public static TimeSpan? PeekPosition(string path)
    {
        var k = KeyOf(path);
        return Positions.TryGetValue(k, out var t) && t > TimeSpan.Zero ? t : null;
    }

    /// Consumes the saved position once (legacy helper).
    public static TimeSpan? TakePosition(string path) => PeekPosition(path);

    public static void SavePosition(string path, TimeSpan position)
    {
        var k = KeyOf(path);
        if (string.IsNullOrEmpty(k) || position <= TimeSpan.Zero) return;
        Positions[k] = position;
    }

    /// Acquires an already-loaded MediaPlayer for `path` for the viewer:
    ///  1. Live player currently playing on an on-screen Browse card (zero-latency handover, never pauses)
    ///  2. Parked player paused at its exact frame for `path` (instant resume without reopening)
    /// Returns null if the viewer should create a fresh MediaPlayer (seeking to `PeekPosition(path)`).
    public static MediaPlayer? Lend(string path)
    {
        var key = KeyOf(path);
        var v = Playing.FirstOrDefault(x =>
            x._player != null && x.IsLoaded && x.XamlRoot != null &&
            string.Equals(x._path, key, StringComparison.OrdinalIgnoreCase));
        if (v?._player is { } p)
        {
            p.PlaybackSession.PositionChanged -= v.FirstFrame;
            Playing.Remove(v);
            v._element.SetMediaPlayer(null);
            v._element.Visibility = Visibility.Collapsed;
            v._player = null;
            v._path = null;
            v._pausedInPlace = false;
            v._lentPath = key;
            _lentFrom = v;
            Services.Diagnostics.Log($"video: lent live card player at {p.PlaybackSession.Position.TotalSeconds:0.00} s");
            return p;
        }

        if (TakeParked(key) is { } parked)
        {
            Services.Diagnostics.Log($"video: resumed parked player at {parked.PlaybackSession.Position.TotalSeconds:0.00} s");
            return parked;
        }
        return null;
    }

    /// Called the moment the viewer begins its close zoom animation (matching Flutter
    /// VideoSession.prepareLeaveViewer): mutes and resets rate to 1× while keeping video playing
    /// live inside the shrinking transition rect.
    public static void PrepareReturn(MediaPlayer p, string path)
    {
        try
        {
            var at = p.PlaybackSession.Position;
            if (at > TimeSpan.Zero) SavePosition(path, at);
            p.IsMuted = true;
            p.IsLoopingEnabled = true;
            p.PlaybackSession.PlaybackRate = 1.0;
        }
        catch { }
    }

    /// Called when the viewer finishes closing or pages away from a video.
    ///  * On closing: hands the live player directly to any visible Browse card displaying `path`
    ///    (preferring the card that originally lent it), so playback continues with zero flash.
    ///  * Otherwise: saves its exact position and parks the player (up to 4) for instant resume.
    public static void Return(MediaPlayer p, string path, bool closing)
    {
        var key = KeyOf(path);
        TimeSpan at = TimeSpan.Zero;
        try { at = p.PlaybackSession.Position; } catch { }
        if (at > TimeSpan.Zero) SavePosition(key, at);

        if (closing)
        {
            var target = FindReturnTarget(key);
            _lentFrom = null;
            if (target != null)
            {
                target._lentPath = null;
                target.AdoptLivePlayer(p, key);
                Services.Diagnostics.Log($"video: back on card at {at.TotalSeconds:0.00} s (same player)");
                return;
            }
        }
        else if (_lentFrom != null && string.Equals(_lentFrom._lentPath, key, StringComparison.OrdinalIgnoreCase))
        {
            // Viewer paged away from the lent video: keep _lentFrom cleared and park this player so
            // paging right back or closing later still resumes smoothly from `at`.
            _lentFrom._lentPath = null;
            _lentFrom = null;
        }

        Services.Diagnostics.Log($"video: parked {System.IO.Path.GetFileName(key)} at {at.TotalSeconds:0.00} s");
        ParkPlayer(key, p);
    }

    static InlineVideo? FindReturnTarget(string key)
    {
        if (_lentFrom is { } v && v.IsLoaded && v.XamlRoot != null && v._cardOnScreen &&
            string.Equals(v._boundPath ?? v._lentPath, key, StringComparison.OrdinalIgnoreCase))
            return v;

        foreach (var candidate in Mounted)
        {
            if (candidate.IsLoaded && candidate.XamlRoot != null && candidate._cardOnScreen &&
                string.Equals(candidate._boundPath, key, StringComparison.OrdinalIgnoreCase))
                return candidate;
        }
        return null;
    }

    void AdoptLivePlayer(MediaPlayer p, string key)
    {
        if (_player != null && _player != p) Stop();
        _player = p;
        _path = key;
        _boundPath = key;
        _pausedInPlace = false;
        Playing.Add(this);
        try
        {
            p.IsMuted = true;
            p.IsLoopingEnabled = true;
            p.PlaybackSession.PlaybackRate = 1.0;
        }
        catch { }
        _element.SetMediaPlayer(p);
        _element.Visibility = Visibility.Visible;
        try { p.Play(); } catch { }
    }

    public bool IsPlaying(string path) =>
        _player != null && !_pausedInPlace && string.Equals(_path, KeyOf(path), StringComparison.OrdinalIgnoreCase);

    /// Partially visible card (< 50% in view): pause in place keeping the current video frame
    /// visible so nudging back into view resumes in 0 ms without reopening or flashing the poster.
    public void PauseInPlace()
    {
        if (_player == null || _pausedInPlace) return;
        _pausedInPlace = true;
        try
        {
            var pos = _player.PlaybackSession.Position;
            if (!string.IsNullOrEmpty(_path) && pos > TimeSpan.Zero) SavePosition(_path, pos);
            _player.Pause();
        }
        catch { }
    }

    public void Play(string path)
    {
        var key = KeyOf(path);
        _boundPath = key;
        if (_player != null && string.Equals(_path, key, StringComparison.OrdinalIgnoreCase))
        {
            if (_pausedInPlace)
            {
                _pausedInPlace = false;
                try { _player.Play(); } catch { }
            }
            return;
        }
        Stop();
        _path = key;
        _pausedInPlace = false;

        // Instant resume from parked pool if this video was recently paused on screen or in viewer.
        if (TakeParked(key) is { } parked)
        {
            _player = parked;
            Playing.Add(this);
            try
            {
                parked.IsMuted = true;
                parked.IsLoopingEnabled = true;
                parked.PlaybackSession.PlaybackRate = 1.0;
            }
            catch { }
            _element.SetMediaPlayer(parked);
            _element.Visibility = Visibility.Visible;
            try { parked.Play(); } catch { }
            return;
        }

        var p = Idle.Count > 0
            ? Idle.Pop()
            : new MediaPlayer { IsMuted = true, IsLoopingEnabled = true, AutoPlay = true, RealTimePlayback = false };
        p.IsMuted = true;
        p.IsLoopingEnabled = true;
        p.PlaybackSession.PlaybackRate = 1.0;
        _player = p;
        Playing.Add(this);

        _revealFrom = TimeSpan.Zero;
        if (PeekPosition(key) is { } from)
        {
            _revealFrom = from;
            void Opened(MediaPlayer m, object _)
            {
                m.MediaOpened -= Opened;
                try { m.PlaybackSession.Position = from; } catch { }
            }
            p.MediaOpened += Opened;
            Services.Diagnostics.Log($"video: card starts at {from.TotalSeconds:0.00} s");
        }
        p.Source = MediaSource.CreateFromUri(new Uri(key));
        _element.SetMediaPlayer(p);
        p.PlaybackSession.PositionChanged += FirstFrame;
        p.Play();
    }

    void FirstFrame(MediaPlaybackSession s, object _)
    {
        if (s.Position <= TimeSpan.Zero) return;
        if (_revealFrom > TimeSpan.Zero)
        {
            var dur = s.NaturalDuration;
            var nearEnd = dur > TimeSpan.Zero && _revealFrom >= dur - TimeSpan.FromMilliseconds(600);
            var reached = s.Position >= _revealFrom || (nearEnd && s.Position >= TimeSpan.FromMilliseconds(50));
            if (!reached) return;
        }
        s.PositionChanged -= FirstFrame;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_player?.PlaybackSession == s) _element.Visibility = Visibility.Visible;
        });
    }

    public void Stop(bool park = true)
    {
        var p = _player;
        var key = _path;
        if (p == null) return;
        _player = null;
        _path = null;
        _pausedInPlace = false;
        _revealFrom = TimeSpan.Zero;
        Playing.Remove(this);
        try { p.PlaybackSession.PositionChanged -= FirstFrame; } catch { }
        _element.Visibility = Visibility.Collapsed;
        _element.SetMediaPlayer(null);

        try
        {
            var pos = p.PlaybackSession.Position;
            if (!string.IsNullOrEmpty(key) && pos > TimeSpan.Zero) SavePosition(key, pos);
        }
        catch { }

        if (park && !string.IsNullOrEmpty(key))
            ParkPlayer(key, p);
        else
            RecyclePlayer(p);
    }

    /// Stops all playing inline cards (except optionally one path currently being adopted by the viewer).
    public static void StopAll(string? exceptPath = null)
    {
        var exceptKey = string.IsNullOrEmpty(exceptPath) ? null : KeyOf(exceptPath);
        foreach (var v in Playing.ToList())
        {
            if (exceptKey != null && string.Equals(v._path, exceptKey, StringComparison.OrdinalIgnoreCase))
                continue;
            v.Stop(park: true);
        }
    }

    static MediaPlayer? TakeParked(string key)
    {
        for (var i = Parked.Count - 1; i >= 0; i--)
        {
            if (!string.Equals(Parked[i].Path, key, StringComparison.OrdinalIgnoreCase)) continue;
            var p = Parked[i].Player;
            Parked.RemoveAt(i);
            return p;
        }
        return null;
    }

    static void ParkPlayer(string key, MediaPlayer p)
    {
        try
        {
            p.Pause();
            p.IsMuted = true;
            p.PlaybackSession.PlaybackRate = 1.0;
        }
        catch
        {
            DisposePlayer(p);
            return;
        }

        // Evict any older parked instance for the same path.
        for (var i = Parked.Count - 1; i >= 0; i--)
        {
            if (!string.Equals(Parked[i].Path, key, StringComparison.OrdinalIgnoreCase)) continue;
            RecyclePlayer(Parked[i].Player);
            Parked.RemoveAt(i);
        }
        Parked.Add((key, p));
        while (Parked.Count > MaxParked)
        {
            RecyclePlayer(Parked[0].Player);
            Parked.RemoveAt(0);
        }
    }

    static void RecyclePlayer(MediaPlayer p)
    {
        try
        {
            p.Pause();
            (p.Source as IDisposable)?.Dispose();
            p.Source = null;
        }
        catch
        {
            DisposePlayer(p);
            return;
        }
        if (Idle.Count < MaxIdle) Idle.Push(p);
        else DisposePlayer(p);
    }

    static void DisposePlayer(MediaPlayer p)
    {
        try
        {
            p.Pause();
            (p.Source as IDisposable)?.Dispose();
            p.Source = null;
            p.Dispose();
        }
        catch { }
    }
}
