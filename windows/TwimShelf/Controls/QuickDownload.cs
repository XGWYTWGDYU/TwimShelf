// The quick download button's card (a flyout under it), as the other apps: links typed or pasted
// (a double click brings in the post links on the clipboard), Ctrl+Enter or 下载 to start; the
// download page's method and folder apply. What is typed stays when the card closes unused.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class QuickDownload
{
    static string _draft = "";

    public static void Show(FrameworkElement anchor, DownloadService downloads, Action openSettings)
    {
        var links = new TextBox
        {
            Text = _draft,
            PlaceholderText = L("mac.quick.placeholder"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            Height = 140,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(links, ScrollBarVisibility.Auto);
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"] };
        var start = new Button { Content = L("common.download"), Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = _draft.Trim().Length > 0 };
        var settings = new HyperlinkButton { Content = L("mac.quick.settings"), Padding = new Thickness(0) };
        var bottom = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        bottom.Children.Add(settings);
        Grid.SetColumn(start, 1);
        bottom.Children.Add(start);
        var panel = new StackPanel
        {
            Width = 360,
            Spacing = 10,
            Children =
            {
                new TextBlock { Text = L("common.downloadPosts"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] },
                new TextBlock { Text = L("mac.quick.footer"), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] },
                links, error, bottom,
            },
        };
        var flyout = new Flyout { Content = panel, Placement = FlyoutPlacementMode.BottomEdgeAlignedRight };
        var starting = false;
        links.TextChanged += (_, _) => { _draft = links.Text; start.IsEnabled = links.Text.Trim().Length > 0 && !starting; error.Visibility = Visibility.Collapsed; };
        links.DoubleTapped += async (_, _) =>
        {
            try
            {
                var data = Windows.ApplicationModel.DataTransfer.Clipboard.GetContent();
                if (!data.Contains(Windows.ApplicationModel.DataTransfer.StandardDataFormats.Text)) return;
                var text = await data.GetTextAsync();
                var have = links.Text.Split((char[])[' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries).ToList();
                var fresh = SharedLinks.Parse(text).Where(l => !have.Contains(l)).ToList();
                if (fresh.Count == 0) return;
                links.Text = string.Join('\n', have.Concat(fresh));
                links.SelectionStart = links.Text.Length;
            }
            catch { }
        };
        async void Go()
        {
            if (links.Text.Trim().Length == 0 || starting) return;
            starting = true;
            start.IsEnabled = false;
            string? problem = null;
            try
            {
                await downloads.StartLinks(links.Text.Split((char[])[' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries));
                _draft = "";
            }
            catch (DownloadServiceException e) { problem = L(e.MessageKey); }
            catch { problem = L("common.couldNotStartDownload"); }
            starting = false;
            if (problem == null) flyout.Hide();
            else
            {
                error.Text = problem;
                error.Visibility = Visibility.Visible;
                start.IsEnabled = true;
            }
        }
        start.Click += (_, _) => Go();
        var enter = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.Enter, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        enter.Invoked += (_, e) => { e.Handled = true; Go(); };
        links.KeyboardAccelerators.Add(enter);
        settings.Click += (_, _) => { flyout.Hide(); openSettings(); };
        flyout.Opened += (_, _) => links.Focus(FocusState.Programmatic);
        flyout.ShowAt(anchor);
    }

    /// The links typed in the card (settings › 下载帖子 takes them over).
    public static string TakeDraft()
    {
        var d = _draft;
        _draft = "";
        return d;
    }
}
