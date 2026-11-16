// A video in a card: muted and looping while on screen, through Windows' own player (Media
// Foundation: H.264/AAC MP4, the videos X serves). Players are kept for the next videos rather than
// made and dropped with each scroll; the poster shows until the first frame.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace TwimShelf.Controls;

public sealed partial class InlineVideo : Grid
{
    static readonly Stack<MediaPlayer> Idle = new();
    static readonly HashSet<InlineVideo> Playing = [];
    readonly MediaPlayerElement _element = new() { Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, AreTransportControlsEnabled = false, IsHitTestVisible = false };
    MediaPlayer? _player;
    string? _path;

    public InlineVideo()
    {
        Children.Add(_element);
        _element.Visibility = Visibility.Collapsed;
        IsHitTestVisible = false;
        // a card taken out of the page (the feed lays out anew) stops its video: it went on unseen,
        // and the viewer could have taken that one instead of the card on screen
        Unloaded += (_, _) => { if (_lentFrom != this) Stop(); };
    }

    /// While the feed scrolls, no player starts: a fast scroll would start and stop one for every
    /// video card passing by (Media Foundation, on the UI thread); they start once it rests.
    public static bool Held;

    // ---- the card and the viewer as one video -----------------------------------------------------
    // Opening a playing card's video, the viewer takes over the card's own player (the same object,
    // at the same moment: no second start); closing, it gives it back, and the card goes on from where
    // the viewer was. A video the viewer showed with a player of its own leaves its position here,
    // and its card (or the viewer, coming back to it) starts from there.
    static InlineVideo? _lentFrom;
    static readonly Dictionary<string, TimeSpan> Positions = new(StringComparer.OrdinalIgnoreCase);

    /// The viewer opens this video: the card's player playing it, taken off the card (null when no
    /// card plays it now).
    public static MediaPlayer? Lend(string path)
    {
        var v = Playing.FirstOrDefault(x => x._player != null && x.IsLoaded && x.XamlRoot != null && string.Equals(x._path, path, StringComparison.OrdinalIgnoreCase));
        if (v?._player is not { } p) return null;
        p.PlaybackSession.PositionChanged -= v.FirstFrame;
        Playing.Remove(v);
        v._element.SetMediaPlayer(null);
        v._element.Visibility = Visibility.Collapsed;
        v._player = null;
        v._path = null;
        v._lentPath = path;
        _lentFrom = v;
        Services.Diagnostics.Log($"video: lent to the viewer at {p.PlaybackSession.Position.TotalSeconds:0.00} s");
        return p;
    }
    string? _lentPath;

    /// Where a video was left (by the viewer), once: the next player of it starts there.
    public static TimeSpan? TakePosition(string path) => Positions.Remove(path, out var t) ? t : null;

    /// The viewer is done with a player of path: back to the card it came from when the viewer
    /// closes on it (still playing, now muted), else its position is kept and the player goes.
    public static void Return(MediaPlayer p, string path, bool closing)
    {
        var at = p.PlaybackSession.Position;
        var v = _lentFrom;
        if (closing && v != null && string.Equals(v._lentPath, path, StringComparison.OrdinalIgnoreCase) && v.XamlRoot != null)
        {
            _lentFrom = null;
            v._lentPath = null;
            v.Stop();
            p.IsMuted = true;
            p.IsLoopingEnabled = true;
            p.PlaybackSession.PlaybackRate = 1;
            v._player = p;
            v._path = path;
            Playing.Add(v);
            v._element.SetMediaPlayer(p);
            v._element.Visibility = Visibility.Visible;
            p.Play();
            Services.Diagnostics.Log($"video: back on the card at {at.TotalSeconds:0.00} s (same player)");
            return;
        }
        if (at > TimeSpan.Zero) Positions[path] = at;
        Services.Diagnostics.Log($"video: viewer left {System.IO.Path.GetFileName(path)} at {at.TotalSeconds:0.00} s");
        p.Pause();
        (p.Source as IDisposable)?.Dispose();
        p.Source = null;
        p.Dispose();
    }

    public bool IsPlaying(string path) => _player != null && string.Equals(_path, path, StringComparison.OrdinalIgnoreCase);

    public void Play(string path)
    {
        if (_player != null && _path == path) return;
        Stop();
        _path = path;
        var p = Idle.Count > 0 ? Idle.Pop() : new MediaPlayer { IsMuted = true, IsLoopingEnabled = true, AutoPlay = true, RealTimePlayback = false };
        p.IsMuted = true;
        p.IsLoopingEnabled = true;
        _player = p;
        Playing.Add(this);
        // the viewer left this video somewhere: the card goes on from there
        if (TakePosition(path) is { } from)
        {
            void Opened(MediaPlayer m, object _) { m.MediaOpened -= Opened; m.PlaybackSession.Position = from; }
            p.MediaOpened += Opened;
            Services.Diagnostics.Log($"video: card starts at {from.TotalSeconds:0.00} s");
        }
        p.Source = MediaSource.CreateFromUri(new Uri(path));
        _element.SetMediaPlayer(p);
        p.PlaybackSession.PositionChanged += FirstFrame;
        p.Play();
    }

    void FirstFrame(MediaPlaybackSession s, object _)
    {
        if (s.Position <= TimeSpan.Zero) return;
        s.PositionChanged -= FirstFrame;
        DispatcherQueue.TryEnqueue(() => { if (_player?.PlaybackSession == s) _element.Visibility = Visibility.Visible; });
    }

    public void Stop()
    {
        var p = _player;
        if (p == null) return;
        _player = null;
        _path = null;
        Playing.Remove(this);
        p.PlaybackSession.PositionChanged -= FirstFrame;
        _element.Visibility = Visibility.Collapsed;
        _element.SetMediaPlayer(null);
        p.Pause();
        (p.Source as IDisposable)?.Dispose();
        p.Source = null;
        Idle.Push(p);
    }

    /// The viewer opens: every card's video stops (and plays again when it closes).
    public static void StopAll()
    {
        foreach (var v in Playing.ToList()) v.Stop();
    }
}
