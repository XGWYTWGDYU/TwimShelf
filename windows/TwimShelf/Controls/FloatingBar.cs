// A page's own buttons, floating over its top right corner on translucent glass (as 浏览's search
// bar, and as Material 3 Expressive's floating toolbars): inside the page, not in the title bar.
// The page leaves its first row clear of it (Space).
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TwimShelf.Controls;

public static class FloatingBar
{
    /// The height the bar takes at the top, with its gap: where a page's content starts.
    public const double Space = 60;

    public static Border Make() => new()
    {
        Padding = new Thickness(4, 0, 4, 0),
        CornerRadius = new CornerRadius(22),
        BorderThickness = new Thickness(1),
        BorderBrush = (Brush)Application.Current.Resources["SurfaceStrokeColorFlyoutBrush"],
        Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Top,
        Margin = new Thickness(0, 8, 20, 0),
    };
}
