// 使用 Claude Code 吉祥物: the little Clawd over the content of a wide window, as in the other
// apps: at home in the bottom-right corner, wandering over the content without being in its way.
// Everything it does comes from the core (core/src/pet.rs: tl_pet_*); this only shows the
// rectangles it draws, thirty times a second, and tells it where the pointer is. Only the crab
// itself takes a click (the canvas has no background: everything else goes to what is below).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Controls;

public sealed partial class PetLayer : Canvas
{
    const int Capacity = 256;
    readonly double[] _buffer = new double[Capacity * 5];
    readonly double[] _last = new double[Capacity * 5];
    int _lastCount = -1;
    readonly List<Rectangle> _rects = [];
    readonly Dictionary<uint, SolidColorBrush> _brushes = [];
    readonly System.Diagnostics.Stopwatch _clock = new();
    readonly FrameworkElement _host;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;
    nint _pet;

    /// Over `host` (whose pointer moves it follows), shown while the mode is on and the window wide.
    public PetLayer(FrameworkElement host)
    {
        _host = host;
        Background = null;
        IsTabStop = false;
        host.AddHandler(PointerMovedEvent, new PointerEventHandler(OnPointer), true);
        host.AddHandler(PointerExitedEvent, new PointerEventHandler((_, _) => { if (_pet != 0) Native.tl_pet_pointer_gone(_pet); }), true);
        SizeChanged += (_, _) => Apply();
        Prefs.Instance.Changed += Apply;
        Unloaded += (_, _) => Stop();
        Loaded += (_, _) => Apply();
    }

    /// A window big enough to have room for it (the other apps' rule).
    static bool Fits(double w, double h) => w >= 700 && h >= 500;

    bool _shown = true;

    /// The window shown or hidden (开机自启 keeps TwimShelf running without it).
    public void SetShown(bool shown) { _shown = shown; Apply(); }

    void Apply()
    {
        if (_shown && Clawd.On && Fits(ActualWidth, ActualHeight)) Start(); else Stop();
        if (_pet != 0) Native.tl_pet_set_bounds(_pet, ActualWidth, ActualHeight, 18, 18);
    }

    void Start()
    {
        if (_pet == 0) _pet = Native.tl_pet_new((ulong)Random.Shared.NextInt64(1, int.MaxValue));
        if (_timer != null) return;
        _clock.Restart();
        _timer = DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(33);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    void Stop()
    {
        _timer?.Stop();
        _timer = null;
        if (_pet != 0) { Native.tl_pet_free(_pet); _pet = 0; }
        Children.Clear();
        _rects.Clear();
        _lastCount = -1;
    }

    unsafe void Tick()
    {
        if (_pet == 0) return;
        var dt = _clock.Elapsed.TotalSeconds;
        _clock.Restart();
        ulong n;
        fixed (double* b = _buffer) n = Native.tl_pet_tick(_pet, dt, b, Capacity);
        var count = (int)Math.Min(n, (ulong)Capacity);
        // nothing is redrawn when nothing changed (a resting crab)
        if (count == _lastCount && _buffer.AsSpan(0, count * 5).SequenceEqual(_last.AsSpan(0, count * 5))) return;
        _buffer.AsSpan(0, count * 5).CopyTo(_last);
        _lastCount = count;
        while (_rects.Count < count)
        {
            var r = new Rectangle();
            r.PointerPressed += OnPress;
            _rects.Add(r);
            Children.Add(r);
        }
        for (var i = 0; i < _rects.Count; i++)
        {
            var r = _rects[i];
            if (i >= count) { r.Visibility = Visibility.Collapsed; continue; }
            var o = i * 5;
            r.Visibility = Visibility.Visible;
            SetLeft(r, _buffer[o]);
            SetTop(r, _buffer[o + 1]);
            r.Width = _buffer[o + 2];
            r.Height = _buffer[o + 3];
            var argb = (uint)_buffer[o + 4];
            if (!_brushes.TryGetValue(argb, out var brush))
                _brushes[argb] = brush = new SolidColorBrush(Windows.UI.Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb));
            r.Fill = brush;
        }
    }

    void OnPointer(object sender, PointerRoutedEventArgs e)
    {
        if (_pet == 0 || e.Pointer.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Touch) return;
        var at = e.GetCurrentPoint(this).Position;
        if (at.X >= 0 && at.Y >= 0 && at.X <= ActualWidth && at.Y <= ActualHeight) Native.tl_pet_pointer(_pet, at.X, at.Y);
        else Native.tl_pet_pointer_gone(_pet);
    }

    void OnPress(object sender, PointerRoutedEventArgs e)
    {
        if (_pet == 0) return;
        var at = e.GetCurrentPoint(this).Position;
        if (Native.tl_pet_hit(_pet, at.X, at.Y)) { Native.tl_pet_tap(_pet, at.X, at.Y); e.Handled = true; }
    }
}
