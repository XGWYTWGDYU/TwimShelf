// Media dragged onto the window, from Explorer or another app: a hint over the window while they
// are held over it, and on release they go to the share page (ShareInbox.ImportDropped copies them
// into the inbox; nothing reaches the library before 导入), as the Flutter app's DropImport.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Models;
using TwimShelf.Services;
using Windows.ApplicationModel.DataTransfer;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class DropImport
{
    public static void Attach(Window window, Grid root, LibraryModel library)
    {
        var hint = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(24, 14, 24, 14),
            CornerRadius = new CornerRadius(26),
            Background = (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"],
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 10,
                Children =
                {
                    new FontIcon { Glyph = "", FontSize = 18, Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"] },
                    new TextBlock { Text = L("drop.hint"), FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = (Brush)Application.Current.Resources["TextOnAccentFillColorPrimaryBrush"] },
                },
            },
        };
        var overlay = new Grid
        {
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x52, 0, 0, 0)),
            IsHitTestVisible = false,
            Visibility = Visibility.Collapsed,
            Children = { hint },
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(overlay, "dropHint");
        Grid.SetRowSpan(overlay, Math.Max(1, root.RowDefinitions.Count));
        root.Children.Add(overlay);
        // a background, so a drag over an empty spot reaches the root too
        root.Background ??= new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        root.AllowDrop = true;

        root.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = L("drop.hint");
            e.Handled = true;
            overlay.Visibility = Visibility.Visible;
        };
        root.DragLeave += (_, _) => overlay.Visibility = Visibility.Collapsed;
        root.Drop += async (_, e) =>
        {
            overlay.Visibility = Visibility.Collapsed;
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            var deferral = e.GetDeferral();
            List<string> paths;
            try { paths = [.. (await e.DataView.GetStorageItemsAsync()).Select(i => i.Path).Where(p => !string.IsNullOrEmpty(p))]; }
            catch (Exception x) { Diagnostics.Log("drop: " + x.Message); deferral.Complete(); return; }
            deferral.Complete();
            Diagnostics.Log($"drop: {paths.Count} item(s)");
            if (paths.Count == 0) return;
            try { await library.Shares.ImportDropped(paths); }
            catch (Exception x)
            {
                Diagnostics.Log("drop failed: " + x.Message);
                Dialogs.Toast(window, L("share.failed", x.Message));
            }
        };
    }
}
