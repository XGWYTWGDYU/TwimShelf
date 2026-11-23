// How a tag shows who added it, as in the other apps: an AI's tag not yet approved in pink with a
// four-pointed sparkle (Gemini's star), one the person added or approved in blue with a tag. The
// sparkle is drawn (Segoe Fluent Icons has none).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using Windows.Foundation;
using Windows.UI;

namespace TwimShelf.Controls;

public static class TagStyle
{
    /// An AI's tag the person has not added or approved.
    public static bool Suggested(TagView t) => (t.Origin & 2) != 0 && (t.Origin & 1) == 0;

    public static Color Tint(TagView t, bool dark) => Suggested(t)
        ? (dark ? Color.FromArgb(255, 0xF4, 0x72, 0xB6) : Color.FromArgb(255, 0xD0, 0x2A, 0x84))
        : (dark ? Color.FromArgb(255, 0x60, 0xB0, 0xFF) : Color.FromArgb(255, 0x00, 0x5F, 0xD0));

    /// The dot of a tag on a card (Finder's look): blue mine, purple an AI's, green an AI's I approved.
    public static Color Dot(TagView t, bool dark)
    {
        bool mine = (t.Origin & 1) != 0, ai = (t.Origin & 2) != 0;
        return mine && ai ? (dark ? Color.FromArgb(255, 0x30, 0xD1, 0x58) : Color.FromArgb(255, 0x24, 0xA1, 0x48))
            : ai ? (dark ? Color.FromArgb(255, 0xBF, 0x5A, 0xF2) : Color.FromArgb(255, 0xAF, 0x52, 0xDE))
            : (dark ? Color.FromArgb(255, 0x0A, 0x84, 0xFF) : Color.FromArgb(255, 0x00, 0x7A, 0xFF));
    }

    /// The box a tag (and the "+") sits in: neutral, faint, with a hairline edge.
    public static void Box(Control c, bool dark)
    {
        c.Background = new SolidColorBrush(dark ? Color.FromArgb(0x12, 255, 255, 255) : Color.FromArgb(0x09, 0, 0, 0));
        c.BorderBrush = new SolidColorBrush(dark ? Color.FromArgb(0x1F, 255, 255, 255) : Color.FromArgb(0x1C, 0, 0, 0));
    }
    public static void Box(Border b, bool dark)
    {
        b.Background = new SolidColorBrush(dark ? Color.FromArgb(0x12, 255, 255, 255) : Color.FromArgb(0x09, 0, 0, 0));
        b.BorderBrush = new SolidColorBrush(dark ? Color.FromArgb(0x1F, 255, 255, 255) : Color.FromArgb(0x1C, 0, 0, 0));
    }

    /// The capsule behind it: the tint, faint.
    public static Color Fill(TagView t, bool dark)
    {
        var c = Tint(t, dark);
        return Color.FromArgb((byte)(dark ? 0x30 : 0x22), c.R, c.G, c.B);
    }

    /// The icon before the label, `size` across.
    public static FrameworkElement Icon(TagView t, double size, Brush brush) => Suggested(t)
        ? new Microsoft.UI.Xaml.Shapes.Path { Data = Sparkle(), Fill = brush, Width = size, Height = size, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center }
        : new FontIcon { Glyph = "", FontSize = size, Foreground = brush, VerticalAlignment = VerticalAlignment.Center };

    /// The same for a menu item: the tag's dot.
    public static IconElement MenuIcon(TagView t) => new PathIcon
    {
        Data = new EllipseGeometry { Center = new Point(8, 8), RadiusX = 4, RadiusY = 4 },
        Foreground = new SolidColorBrush(Dot(t, Application.Current.RequestedTheme == ApplicationTheme.Dark)),
    };

    /// The star alone, for a settings card or a menu item.
    public static PathIcon MenuIconSparkle() => new() { Data = Sparkle(18), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

    /// A four-pointed star with curved sides in a box `box` across (24 by default) (a new geometry each time: one
    /// geometry can't be shared between elements).
    public static Geometry Sparkle(double box = 24)
    {
        var k = box / 24;
        Point P(double x, double y) => new(x * k, y * k);
        var f = new PathFigure { StartPoint = P(12, 0), IsClosed = true, IsFilled = true };
        void Curve(double cx, double cy, double x, double y) =>
            f.Segments.Add(new QuadraticBezierSegment { Point1 = P(cx, cy), Point2 = P(x, y) });
        Curve(13, 11, 24, 12);
        Curve(13, 13, 12, 24);
        Curve(11, 13, 0, 12);
        Curve(11, 11, 12, 0);
        var g = new PathGeometry();
        g.Figures.Add(f);
        return g;
    }
}
