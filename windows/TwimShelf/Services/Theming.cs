// Light or dark is the system's, followed as it changes (no choice of its own, no accent of its
// own on Windows): the window's caption buttons match it.
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Windows.UI;

namespace TwimShelf.Services;

public static class Theming
{
    public static Color ToColor(long argb) => Color.FromArgb((byte)(argb >> 24), (byte)(argb >> 16), (byte)(argb >> 8), (byte)argb);

    /// Whether the window is drawn dark now.
    public static bool IsDark(Window? w) => w?.Content is FrameworkElement root
        ? root.ActualTheme == ElementTheme.Dark
        : Application.Current.RequestedTheme == ApplicationTheme.Dark;

    /// The window's caption buttons to match its light or dark.
    public static void Apply(Window w)
    {
        var tb = w.AppWindow.TitleBar;
        var dark = IsDark(w);
        tb.ButtonForegroundColor = dark ? Colors.White : Colors.Black;
        tb.ButtonHoverForegroundColor = dark ? Colors.White : Colors.Black;
        tb.ButtonHoverBackgroundColor = dark ? Color.FromArgb(0x18, 255, 255, 255) : Color.FromArgb(0x18, 0, 0, 0);
        tb.ButtonBackgroundColor = Colors.Transparent;
        tb.ButtonInactiveBackgroundColor = Colors.Transparent;
    }
}
