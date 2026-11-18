// The small window before the library is open: the first time, where the data goes (one folder for
// everything the app keeps, as the Flutter app asked); then 正在打开资料库, or why it could not.
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf;

public sealed partial class StartWindow : Window
{
    readonly Grid _root = new() { Padding = new Thickness(40, 48, 40, 32) };

    public StartWindow()
    {
        Title = "TwimShelf";
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        Content = _root;
        _root.RequestedTheme = ElementTheme.Default;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        var scale = WindowScale.Of(AppWindow);
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(640 * scale), (int)(460 * scale)));
        // the start window's size is its own: made here (AppWindow.Presenter comes back in the AOT build
        // as the base presenter, and a cast to OverlappedPresenter fails)
        var op = OverlappedPresenter.Create();
        op.IsResizable = false;
        op.IsMaximizable = false;
        AppWindow.SetPresenter(op);
        // no icon in the caption (the taskbar has it)
        AppWindow.TitleBar.IconShowOptions = IconShowOptions.HideIconAndSystemMenu;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + (area.Height - AppWindow.Size.Height) / 2));
    }

    public void ShowOpening()
    {
        _root.Children.Clear();
        _root.Children.Add(new StackPanel
        {
            Spacing = 16, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Children = { new ProgressBar { IsIndeterminate = true, Width = 220 }, new TextBlock { Text = L("app.opening"), HorizontalAlignment = HorizontalAlignment.Center } },
        });
    }

    public void ShowFailed(string detail)
    {
        _root.Children.Clear();
        _root.Children.Add(new StackPanel
        {
            Spacing = 12, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock { Text = L("app.openFailed"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] },
                new TextBlock { Text = L("app.openFailed.message"), TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = detail, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
            },
        });
    }

    /// 数据文件夹: a suggestion in Documents, or another (new, empty, or a data folder already).
    public void AskForDataFolder(Action chosen)
    {
        var folder = DataHome.Suggested;
        var path = new TextBlock { Text = folder, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        var error = new InfoBar { Severity = InfoBarSeverity.Warning, IsClosable = false, IsOpen = false, Message = L("datahome.notEmpty") };
        var use = new Button { Content = L("datahome.useSuggested"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        var other = new Button { Content = L("datahome.chooseOther") };
        void Check()
        {
            var problem = DataHome.Problem(folder);
            if (problem != null) error.Message = L(problem);
            error.IsOpen = problem != null;
            use.IsEnabled = problem == null;
        }
        use.Click += (_, _) =>
        {
            if (DataHome.Problem(folder) != null) { Check(); return; }
            try { DataHome.Choose(folder); chosen(); }
            catch (Exception e) { error.Message = e.Message; error.IsOpen = true; }
        };
        other.Click += async (_, _) =>
        {
            var p = await Pickers.Folder(this);
            if (p == null) return;
            folder = p;
            path.Text = p;
            use.Content = L("datahome.useSuggested");
            Check();
        };
        Check();
        _root.Children.Clear();
        _root.Children.Add(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new TextBlock { Text = L("datahome.title"), Style = (Style)Application.Current.Resources["TitleTextBlockStyle"] },
                new TextBlock { Text = L("datahome.message"), TextWrapping = TextWrapping.Wrap, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
                new Border
                {
                    Padding = new Thickness(14, 10, 14, 10), CornerRadius = new CornerRadius(6),
                    Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                    BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
                    Child = path,
                },
                error,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { use, other } },
            },
        });
    }
}
