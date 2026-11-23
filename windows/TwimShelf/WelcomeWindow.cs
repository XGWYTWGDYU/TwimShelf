// 8-page Welcome / Onboarding window for Windows (WinUI 3 / Fluent 2, Mica backdrop).
// Native WinUI window & Fluent controls; stage animations are pure animated SVG rendered in WebView2.
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using TwimShelf.Services;
using Windows.System;
using Windows.UI;
using static TwimShelf.Services.Strings;

namespace TwimShelf;

public sealed partial class WelcomeWindow : Window
{
    static WelcomeWindow? _current;

    /// Show once on first launch, or again when "Show welcome on next launch" was toggled in About.
    public static void ShowIfNeeded()
    {
        if (Prefs.Instance.WelcomeSeen && !Prefs.Instance.WelcomeNextLaunch) return;
        Prefs.Instance.WelcomeSeen = true;
        Prefs.Instance.WelcomeNextLaunch = false;
        Show();
    }

    /// Open (or focus) the Welcome window on demand (e.g. from Settings › About).
    public static void Show()
    {
        if (_current != null)
        {
            _current.Activate();
            return;
        }
        Prefs.Instance.WelcomeSeen = true;
        var w = new WelcomeWindow();
        _current = w;
        w.Closed += (_, _) => { if (_current == w) _current = null; };
        w.Activate();
    }

    sealed record PageSpec(string BadgeKey, string TitleKey, string BodyKey, string Glyph, Color Accent);

    static readonly PageSpec[] Pages =
    [
        new("welcome.p1.badge", "welcome.p1.title", "welcome.p1.body.desktop", "\uE8B1", C(0xF9, 0x73, 0x16)), // Shuffle / Orange
        new("welcome.p2.badge", "welcome.p2.title", "welcome.p2.body", "\uE8A3", C(0x00, 0x78, 0xD4)),         // ZoomIn / Fluent Blue
        new("welcome.p3.badge", "welcome.p3.title", "welcome.p3.body", "\uE896", C(0x06, 0xB6, 0xD4)),         // Download / Cyan
        new("welcome.p4.badge", "welcome.p4.title", "welcome.p4.body", "\uE734", C(0x8B, 0x5C, 0xF6)),         // Sparkle / Purple
        new("welcome.p5.badge", "welcome.p5.title", "welcome.p5.body", "\uE8EC", C(0x10, 0xB9, 0x81)),         // Tag / Emerald
        new("welcome.p6.badge", "welcome.p6.title", "welcome.p6.body", "\uE721", C(0x63, 0x66, 0xF1)),         // Search / Indigo
        new("welcome.p7.badge", "welcome.p7.title", "welcome.p7.body", "\uE895", C(0x14, 0xB8, 0xA6)),         // Sync / Teal
        new("welcome.p8.badge", "welcome.p8.title", "welcome.p8.body", "\uE7B8", C(0xF4, 0x3F, 0x5E)),         // Package / Rose
    ];

    int _index;
    bool _webReady;
    readonly Grid _root = new();
    readonly Grid _dragBar = new() { Height = 44, Padding = new Thickness(24, 0, 144, 0) };
    readonly Border _stepPill = new()
    {
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(10, 3, 10, 3),
        HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly TextBlock _stepText = new() { FontSize = 11.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _skipBtn = new()
    {
        MinWidth = 76,
        Padding = new Thickness(14, 7, 14, 7),
        CornerRadius = new CornerRadius(6),
        VerticalAlignment = VerticalAlignment.Center,
    };
    readonly Border _stageCard = new()
    {
        Height = 294,
        Margin = new Thickness(28, 2, 28, 0),
    };
    readonly WebView2 _webView = new()
    {
        DefaultBackgroundColor = Colors.Transparent,
        HorizontalAlignment = HorizontalAlignment.Stretch,
        VerticalAlignment = VerticalAlignment.Stretch,
    };
    readonly Border _badgePill = new()
    {
        CornerRadius = new CornerRadius(6),
        Padding = new Thickness(11, 4, 11, 4),
        HorizontalAlignment = HorizontalAlignment.Center,
    };
    readonly FontIcon _badgeIcon = new() { FontSize = 11 };
    readonly TextBlock _badgeText = new() { FontSize = 11.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    readonly TextBlock _titleText = new()
    {
        FontSize = 21.5,
        FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(28, 8, 28, 0),
    };
    readonly TextBlock _bodyText = new()
    {
        FontSize = 13.5,
        TextAlignment = TextAlignment.Center,
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 548,
        LineHeight = 20,
        Margin = new Thickness(28, 6, 28, 0),
    };
    readonly Button _backBtn = new() { MinWidth = 88, Padding = new Thickness(14, 7, 14, 7), CornerRadius = new CornerRadius(6) };
    readonly StackPanel _dots = new() { Orientation = Orientation.Horizontal, Spacing = 7, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly Button _nextBtn = new() { MinWidth = 100, Padding = new Thickness(16, 7, 16, 7), CornerRadius = new CornerRadius(6) };

    bool Dark => Theming.IsDark(this);

    WelcomeWindow()
    {
        Title = L("welcome.windowTitle");
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;

        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);

        var op = OverlappedPresenter.Create();
        op.IsResizable = false;
        op.IsMaximizable = false;
        AppWindow.SetPresenter(op);
        AppWindow.TitleBar.IconShowOptions = IconShowOptions.HideIconAndSystemMenu;

        var scale = WindowScale.Of(AppWindow);
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(700 * scale), (int)(564 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(
            area.X + (area.Width - AppWindow.Size.Width) / 2,
            area.Y + (area.Height - AppWindow.Size.Height) / 2));

        BuildLayout();
        Content = _root;
        SetTitleBar(_dragBar);
        Theming.Apply(this);

        _root.ActualThemeChanged += (_, _) =>
        {
            Theming.Apply(this);
            RenderPage();
        };
        _root.KeyDown += OnKeyDown;
        Closed += (_, _) =>
        {
            _stageCard.Child = null;
            try { _webView.Close(); } catch { }
        };

        RenderPage();
        _ = InitWebView();
    }

    async Task InitWebView()
    {
        try
        {
            var udf = Path.Combine(Path.GetTempPath(), "TwimShelf-WebView2");
            var env = await CoreWebView2Environment.CreateWithOptionsAsync(null, udf, null);
            await _webView.EnsureCoreWebView2Async(env);
            if (_webView.CoreWebView2 is { } core)
            {
                core.Settings.AreDefaultContextMenusEnabled = false;
                core.Settings.AreDevToolsEnabled = false;
                core.Settings.IsZoomControlEnabled = false;
                core.Settings.IsStatusBarEnabled = false;
                core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            }
            _webReady = true;
            RenderStageSvg();
        }
        catch (Exception ex)
        {
            Diagnostics.Log("welcome webview2: " + ex.Message);
        }
    }

    void BuildLayout()
    {
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // Top drag bar: step pill on left (clear of Windows caption buttons on right)
        _stepPill.Child = _stepText;
        _dragBar.Children.Add(_stepPill);
        Grid.SetRow(_dragBar, 0);
        _root.Children.Add(_dragBar);

        // Center content: SVG Stage + Badge + Title + Body
        var center = new StackPanel { Orientation = Orientation.Vertical };
        _stageCard.Child = _webView;
        center.Children.Add(_stageCard);

        var badgeRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        badgeRow.Children.Add(_badgeIcon);
        badgeRow.Children.Add(_badgeText);
        _badgePill.Child = badgeRow;
        _badgePill.Margin = new Thickness(0, 16, 0, 0);
        center.Children.Add(_badgePill);
        center.Children.Add(_titleText);
        center.Children.Add(_bodyText);

        Grid.SetRow(center, 1);
        _root.Children.Add(center);

        // Footer: Back | Dots | Next/Done
        var footer = new Grid { Padding = new Thickness(28, 10, 28, 20) };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var backContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        backContent.Children.Add(new FontIcon { Glyph = "\uE72B", FontSize = 11 });
        backContent.Children.Add(new TextBlock { Text = L("welcome.back"), VerticalAlignment = VerticalAlignment.Center });
        _backBtn.Content = backContent;
        _backBtn.HorizontalAlignment = HorizontalAlignment.Left;
        _backBtn.Click += (_, _) => Go(-1);
        Grid.SetColumn(_backBtn, 0);
        footer.Children.Add(_backBtn);

        _nextBtn.Click += (_, _) => { if (_index >= Pages.Length - 1) Close(); else Go(1); };

        Grid.SetColumn(_dots, 1);
        footer.Children.Add(_dots);

        _skipBtn.Content = L("welcome.skip");
        _skipBtn.Click += (_, _) => Close();
        var rightActions = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
        };
        rightActions.Children.Add(_skipBtn);
        rightActions.Children.Add(_nextBtn);
        Grid.SetColumn(rightActions, 2);
        footer.Children.Add(rightActions);

        Grid.SetRow(footer, 2);
        _root.Children.Add(footer);
    }

    void OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        switch (e.Key)
        {
            case VirtualKey.Left:
                Go(-1);
                e.Handled = true;
                break;
            case VirtualKey.Right:
            case VirtualKey.Space:
            case VirtualKey.Enter:
                if (_index >= Pages.Length - 1) Close(); else Go(1);
                e.Handled = true;
                break;
            case VirtualKey.Escape:
                Close();
                e.Handled = true;
                break;
        }
    }

    void Go(int delta)
    {
        var next = Math.Clamp(_index + delta, 0, Pages.Length - 1);
        if (next == _index) return;
        _index = next;
        RenderPage();
    }

    void RenderPage()
    {
        var page = Pages[_index];
        var accent = page.Accent;
        var dark = Dark;
        var isLast = _index == Pages.Length - 1;

        _stepText.Text = L("welcome.step", _index + 1, Pages.Length);
        _stepText.Foreground = BrushOf(dark ? A(Colors.White, 0xAA) : A(Colors.Black, 0x99));
        _stepPill.Background = BrushOf(dark ? A(Colors.White, 0x12) : A(Colors.Black, 0x0A));

        _skipBtn.Visibility = isLast ? Visibility.Collapsed : Visibility.Visible;

        // Badge + copy
        _badgePill.Background = BrushOf(A(accent, (byte)(dark ? 0x33 : 0x1E)));
        _badgeIcon.Glyph = page.Glyph;
        _badgeIcon.Foreground = BrushOf(accent);
        _badgeText.Text = L(page.BadgeKey);
        _badgeText.Foreground = BrushOf(accent);

        _titleText.Text = L(page.TitleKey);
        _titleText.Foreground = BrushOf(dark ? Colors.White : C(0x18, 0x18, 0x1B));
        _bodyText.Text = L(page.BodyKey);
        _bodyText.Foreground = BrushOf(dark ? A(Colors.White, 0xB8) : C(0x52, 0x52, 0x5B));

        // Back button
        _backBtn.IsEnabled = _index > 0;
        _backBtn.Opacity = _index > 0 ? 1 : 0;

        // Next/Done button: preserve accent color across Normal / PointerOver / Pressed states
        var nextRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        nextRow.Children.Add(new TextBlock
        {
            Text = isLast ? L("welcome.done") : L("welcome.next"),
            Foreground = BrushOf(Colors.White),
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        });
        nextRow.Children.Add(new FontIcon { Glyph = isLast ? "\uE73E" : "\uE72A", FontSize = 11, Foreground = BrushOf(Colors.White) });
        _nextBtn.Content = nextRow;

        var hover = Blend(accent, dark ? Colors.White : Colors.Black, 0.14);
        var pressed = Blend(accent, Colors.Black, 0.24);
        _nextBtn.Background = BrushOf(accent);
        _nextBtn.BorderBrush = BrushOf(Colors.Transparent);
        _nextBtn.Resources["ButtonBackground"] = BrushOf(accent);
        _nextBtn.Resources["ButtonBackgroundPointerOver"] = BrushOf(hover);
        _nextBtn.Resources["ButtonBackgroundPressed"] = BrushOf(pressed);
        _nextBtn.Resources["ButtonForeground"] = BrushOf(Colors.White);
        _nextBtn.Resources["ButtonForegroundPointerOver"] = BrushOf(Colors.White);
        _nextBtn.Resources["ButtonForegroundPressed"] = BrushOf(Colors.White);
        _nextBtn.Resources["ButtonBorderBrush"] = BrushOf(Colors.Transparent);
        _nextBtn.Resources["ButtonBorderBrushPointerOver"] = BrushOf(Colors.Transparent);
        _nextBtn.Resources["ButtonBorderBrushPressed"] = BrushOf(Colors.Transparent);

        // Dots
        _dots.Children.Clear();
        for (var i = 0; i < Pages.Length; i++)
        {
            var idx = i;
            var active = i == _index;
            var dot = new Button
            {
                Width = active ? 24 : 8,
                Height = 8,
                MinWidth = 0,
                MinHeight = 0,
                Padding = new Thickness(0),
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(0),
                Background = BrushOf(active ? accent : (dark ? A(Colors.White, 0x30) : A(Colors.Black, 0x24))),
            };
            dot.Resources["ButtonBackground"] = BrushOf(active ? accent : (dark ? A(Colors.White, 0x30) : A(Colors.Black, 0x24)));
            dot.Resources["ButtonBackgroundPointerOver"] = BrushOf(active ? accent : (dark ? A(Colors.White, 0x50) : A(Colors.Black, 0x3C)));
            dot.Resources["ButtonBackgroundPressed"] = BrushOf(active ? accent : (dark ? A(Colors.White, 0x60) : A(Colors.Black, 0x48)));
            dot.Click += (_, _) => { _index = idx; RenderPage(); };
            _dots.Children.Add(dot);
        }

        RenderStageSvg();
    }

    void RenderStageSvg()
    {
        if (!_webReady || _webView.CoreWebView2 == null) return;
        _webView.NavigateToString(WelcomeSvg.Html(_index, Dark));
    }

    static SolidColorBrush BrushOf(Color c) => new(c);
    static Color C(byte r, byte g, byte b) => Color.FromArgb(0xFF, r, g, b);
    static Color A(Color c, byte a) => Color.FromArgb(a, c.R, c.G, c.B);
    static Color Blend(Color bg, Color fg, double t) => Color.FromArgb(
        0xFF,
        (byte)(bg.R + (fg.R - bg.R) * t),
        (byte)(bg.G + (fg.G - bg.G) * t),
        (byte)(bg.B + (fg.B - bg.B) * t));
}
