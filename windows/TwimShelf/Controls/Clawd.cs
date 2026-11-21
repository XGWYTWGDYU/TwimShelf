// 使用 Claude Code 吉祥物: the mascot's icons (ClawdIconData, made by scripts/gen_icons.py from the
// Clawd icons, MIT) as the other apps draw them: the crab in its own colours, what it holds in the
// text colour. Each becomes a little SVG that WinUI draws itself (SvgImageSource), one per icon
// and theme, made once.
using System.Globalization;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Services;
using Windows.Storage.Streams;

namespace TwimShelf.Controls;

public static class Clawd
{
    static readonly Dictionary<(string Name, bool Dark, int Pixels), SvgImageSource> Made = [];

    /// Whether the mode is on.
    public static bool On => Prefs.Instance.Mascot;

    static bool Dark => Theming.IsDark(MainWindow.Current);

    /// The icon's SVG: a 24×24 box, strokes and unfilled shapes in the theme's text colour.
    public static string Svg(string name, bool dark)
    {
        var text = dark ? "#FFFFFF" : "#1B1B1B";
        var ops = ClawdIconData.Icons.GetValueOrDefault(name) ?? [];
        // a square around the drawing itself (it leaves a margin in its 24-unit box): it fills a
        // sidebar's small icon slot as the other apps' icons do
        double x0 = 24, y0 = 24, x1 = 0, y1 = 0;
        foreach (var (_, _, d) in ops)
        {
            var n = d.Split(' ').Select(t => double.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : double.NaN).Where(v => !double.IsNaN(v)).ToArray();
            for (var i = 0; i + 1 < n.Length; i += 2) { x0 = Math.Min(x0, n[i]); x1 = Math.Max(x1, n[i]); y0 = Math.Min(y0, n[i + 1]); y1 = Math.Max(y1, n[i + 1]); }
        }
        var side = Math.Max(x1 - x0, y1 - y0) + 1;
        var box = x1 > x0 ? string.Create(CultureInfo.InvariantCulture, $"{(x0 + x1 - side) / 2:0.##} {(y0 + y1 - side) / 2:0.##} {side:0.##} {side:0.##}") : "0 0 24 24";
        var b = new StringBuilder($"<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{box}\" width=\"24\" height=\"24\">");
        foreach (var (fill, stroke, d) in ops)
        {
            if (stroke)
                b.Append($"<path d=\"{d}\" fill=\"none\" stroke=\"{text}\" stroke-width=\"0.7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>");
            else
                b.Append($"<path d=\"{d}\" fill=\"{(fill is { } f ? "#" + f.ToString("X6", CultureInfo.InvariantCulture) : text)}\"/>");
        }
        return b.Append("</svg>").ToString();
    }

    /// The icon as a picture `size` points across (drawn sharp for the screen's scale).
    public static ImageSource Source(string name, double size, double scale = 1)
    {
        var pixels = (int)Math.Ceiling(size * scale);
        var key = (name, Dark, pixels);
        if (Made.TryGetValue(key, out var made)) return made;
        var source = new SvgImageSource { RasterizePixelWidth = pixels, RasterizePixelHeight = pixels };
        Made[key] = source;
        _ = Load(source, Svg(name, key.Item2));
        return source;
    }

    static async Task Load(SvgImageSource source, string svg)
    {
        try
        {
            var stream = new InMemoryRandomAccessStream();
            using (var w = new DataWriter(stream))
            {
                w.WriteBytes(Encoding.UTF8.GetBytes(svg));
                await w.StoreAsync();
                w.DetachStream();
            }
            stream.Seek(0);
            await source.SetSourceAsync(stream);
        }
        catch (Exception e) { Diagnostics.Log("clawd icon: " + e.Message); }
    }

    /// For a sidebar item or a menu: an icon element.
    public static IconElement Icon(string name, double size = 20) =>
        new ImageIcon { Source = Source(name, size, 2), Width = size, Height = size };

    static readonly HashSet<Microsoft.UI.Dispatching.DispatcherQueueTimer> Pulsing = [];

    static double Overshoot(double x)
    {
        const double c = 1.70158;
        return 1 + (c + 1) * Math.Pow(x - 1, 3) + c * Math.Pow(x - 1, 2);
    }

    /// A press: Clawd pops up in the item's icon's place, stays a moment, shrinks away, and the
    /// icon grows back (the other apps' timing). Another press takes the item over and ends this one.
    public static void Pulse(NavigationViewItem item, string name, Func<IconElement> normal)
    {
        const double popIn = 0.24, hold = 0.7, shrink = 0.12, regrow = 0.2;
        var scale = new ScaleTransform();
        IconElement shown = Icon(name);
        void Pose(double size, double opacity)
        {
            scale.ScaleX = scale.ScaleY = size;
            shown.Opacity = opacity;
        }
        void Dress()
        {
            shown.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            shown.RenderTransform = scale;
        }
        Dress();
        Pose(0.45, 0);
        item.Icon = shown;
        var back = false;
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var timer = item.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(16);
        timer.IsRepeating = true;
        timer.Tick += (t, _) =>
        {
            if (!ReferenceEquals(item.Icon, shown)) { t.Stop(); Pulsing.Remove(t); return; }
            var s = clock.Elapsed.TotalSeconds;
            if (s < popIn) { var x = s / popIn; Pose(0.45 + 0.55 * Overshoot(x), Math.Min(1, x * 2.5)); }
            else if (s < hold) Pose(1, 1);
            else if (s < hold + shrink) { var x = (s - hold) / shrink; Pose(1 - 0.45 * x, 1 - x); }
            else if (s < hold + shrink + regrow)
            {
                if (!back)
                {
                    back = true;
                    shown = normal();
                    Dress();
                    Pose(0.55, 0);
                    item.Icon = shown;
                }
                var x = (s - hold - shrink) / regrow;
                Pose(0.55 + 0.45 * Overshoot(x), Math.Min(1, x * 2.5));
            }
            else
            {
                t.Stop();
                Pulsing.Remove(t);
                item.Icon = normal();
            }
        };
        Pulsing.Add(timer);
        timer.Start();
    }

    /// For a card's header or a page: a picture.
    public static Image Picture(string name, double size) =>
        new() { Source = Source(name, size, 2), Width = size, Height = size, Stretch = Stretch.Uniform };

    /// The mode's icon of a place (the other apps' choice), if it has one.
    public static string? For(Models.Place p) => p.Id switch
    {
        "browse" => "home",
        "photos" => "image",
        "videos" => "video",
        "folders" => "folder",
        "settings" => "settings",
        _ => p.Folder != null ? "folder" : null,
    };

    /// The mode's icon of a kind of device (a sync peer), if it has one.
    public static string? ForDevice(string? kind) => kind switch
    {
        "iphone" or "android-phone" => "mobile",
        "ipad" or "android-tablet" => "tablet",
        "mac" or "windows" or "linux" => "laptop",
        _ => null,
    };

    /// The license of the icons (the switch's notice refers to it), as written.
    public const string License = """
        Clawd Icons
        https://github.com/TangfanOVO/clawd-icons

        MIT License

        Copyright (c) 2026 唐幡 (TangfanOVO)
        Copyright (c) 2026 Marcio Granzotto Rodrigues (Clawd base artwork)

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """;
}
