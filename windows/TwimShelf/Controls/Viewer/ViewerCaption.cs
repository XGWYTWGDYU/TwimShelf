// Expandable post caption over the bottom of the unified viewer (matching Apple PostCaptionView,
// Web Caption.tsx, and Flutter _Caption): author + @handle, body text truncated to 3 lines, click
// to expand into a scrollable selectable view with post date and "收起". Loose media or posts
// without author/text show nothing.
using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls.ViewerEngine;

public sealed partial class ViewerCaption : UserControl
{
    readonly StackPanel _root = new() { Spacing = 4, MaxWidth = 680, HorizontalAlignment = HorizontalAlignment.Left };
    readonly Border _plate = new()
    {
        CornerRadius = new CornerRadius(8),
        BorderThickness = new Thickness(1),
        Padding = new Thickness(12, 8, 12, 8),
        Shadow = new ThemeShadow(),
        Translation = new System.Numerics.Vector3(0, 0, 24),
        HorizontalAlignment = HorizontalAlignment.Left,
    };
    readonly TextBlock _author = new() { FontSize = 14, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
    readonly TextBlock _collapsed = new()
    {
        FontSize = 14,
        TextWrapping = TextWrapping.Wrap,
        MaxLines = 3,
        TextTrimming = TextTrimming.CharacterEllipsis,
        LineHeight = 20,
    };
    readonly ScrollViewer _expandedScroll = new()
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Visibility = Visibility.Collapsed,
    };
    readonly StackPanel _expandedBody = new() { Spacing = 6 };
    readonly TextBlock _expandedText = new()
    {
        FontSize = 14,
        TextWrapping = TextWrapping.Wrap,
        IsTextSelectionEnabled = true,
        LineHeight = 20,
    };
    readonly TextBlock _date = new()
    {
        FontSize = 12,
    };
    readonly TextBlock _toggleHint = new()
    {
        FontSize = 12,
        FontWeight = FontWeights.SemiBold,
        Visibility = Visibility.Collapsed,
    };

    string? _postId;
    bool _expanded;
    bool _hasText;
    double _maxExpandedHeight = 320;

    public bool IsExpanded => _expanded;
    public bool HasContent { get; private set; }

    public ViewerCaption()
    {
        _expandedBody.Children.Add(_expandedText);
        _expandedBody.Children.Add(_date);
        _expandedScroll.Content = _expandedBody;
        _root.Children.Add(_author);
        _root.Children.Add(_collapsed);
        _root.Children.Add(_expandedScroll);
        _root.Children.Add(_toggleHint);

        _plate.Child = _root;
        var wrap = new Grid { Background = new SolidColorBrush(Colors.Transparent), Children = { _plate } };
        wrap.Tapped += OnTapped;
        wrap.DoubleTapped += (_, e) => e.Handled = true;
        wrap.PointerPressed += (_, e) => e.Handled = true;
        wrap.PointerWheelChanged += (_, e) => { if (_expanded) e.Handled = true; };
        _collapsed.IsTextTrimmedChanged += (_, _) => UpdateHint();
        _collapsed.SizeChanged += (_, _) => UpdateHint();

        Content = wrap;
        Visibility = Visibility.Collapsed;
        Loaded += (_, _) => ApplyTheme();
        ActualThemeChanged += (_, _) => ApplyTheme();
        ApplyTheme();
    }

    public void ApplyTheme()
    {
        var primary = new SolidColorBrush(Colors.White);
        var secondary = new SolidColorBrush(Windows.UI.Color.FromArgb(0xB3, 255, 255, 255));
        var hint = new SolidColorBrush(Windows.UI.Color.FromArgb(0xCC, 255, 255, 255));
        _author.Foreground = primary;
        _collapsed.Foreground = primary;
        _expandedText.Foreground = primary;
        _date.Foreground = secondary;
        _toggleHint.Foreground = hint;
        // Explicit dark Acrylic so the card never picks up light-mode white Acrylic over the dark viewer.
        _plate.Background = new AcrylicBrush
        {
            TintColor = Windows.UI.Color.FromArgb(0xFF, 0x20, 0x20, 0x20),
            TintOpacity = 0.68,
            TintLuminosityOpacity = 0.74,
            FallbackColor = Windows.UI.Color.FromArgb(0xE0, 0x24, 0x24, 0x24),
        };
        _plate.BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x28, 255, 255, 255));
    }

    public static bool Shows(FeedItem? item)
    {
        if (item == null || item.IsLoose()) return false;
        return !string.IsNullOrEmpty(item.Text) || !string.IsNullOrEmpty(item.AuthorName) || !string.IsNullOrEmpty(item.ScreenName);
    }

    public void SetMaxExpandedHeight(double height)
    {
        _maxExpandedHeight = Math.Max(120, height);
        _expandedScroll.MaxHeight = _maxExpandedHeight;
    }

    public void SetItem(FeedItem? item)
    {
        if (!Shows(item))
        {
            _postId = null;
            _expanded = false;
            HasContent = false;
            Visibility = Visibility.Collapsed;
            return;
        }
        HasContent = true;
        Visibility = Visibility.Visible;

        var samePost = _postId != null && _postId == item!.PostId;
        _postId = item!.PostId;
        if (!samePost) _expanded = false;

        var authorParts = new List<string>(2);
        if (!string.IsNullOrEmpty(item.AuthorName)) authorParts.Add(item.AuthorName);
        if (!string.IsNullOrEmpty(item.ScreenName)) authorParts.Add("@" + item.ScreenName);
        _author.Text = string.Join("  ", authorParts);
        _author.Visibility = authorParts.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        var text = item.Text ?? "";
        _hasText = text.Length > 0;
        _collapsed.Text = text;
        _expandedText.Text = text;

        var dateStr = FormatDate(item.CreatedAt);
        _date.Text = dateStr ?? "";
        _date.Visibility = string.IsNullOrEmpty(dateStr) ? Visibility.Collapsed : Visibility.Visible;

        ApplyExpandedState();
    }

    public void Collapse()
    {
        if (!_expanded) return;
        _expanded = false;
        ApplyExpandedState();
    }

    void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        e.Handled = true;
        if (!_hasText) return;
        if (_expanded || _collapsed.IsTextTrimmed || !string.IsNullOrEmpty(_date.Text))
        {
            _expanded = !_expanded;
            ApplyExpandedState();
        }
    }

    void ApplyExpandedState()
    {
        _collapsed.Visibility = _hasText && !_expanded ? Visibility.Visible : Visibility.Collapsed;
        _expandedScroll.Visibility = _hasText && _expanded ? Visibility.Visible : Visibility.Collapsed;
        _expandedScroll.MaxHeight = _maxExpandedHeight;
        UpdateHint();
    }

    void UpdateHint()
    {
        if (!_hasText)
        {
            _toggleHint.Visibility = Visibility.Collapsed;
            return;
        }
        if (_expanded)
        {
            _toggleHint.Text = L("caption.less");
            _toggleHint.Visibility = Visibility.Visible;
        }
        else if (_collapsed.IsTextTrimmed)
        {
            _toggleHint.Text = L("caption.more");
            _toggleHint.Visibility = Visibility.Visible;
        }
        else
        {
            _toggleHint.Visibility = Visibility.Collapsed;
        }
    }

    [GeneratedRegex(@"^\w{3} (\w{3}) (\d{1,2}) (\d\d:\d\d:\d\d) ([+-]\d{4}) (\d{4})$")]
    private static partial Regex TwitterDateRegex();

    static string? FormatDate(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        var s = raw.Trim();
        DateTimeOffset dto;
        var m = TwitterDateRegex().Match(s);
        if (m.Success)
        {
            var reformatted = $"{m.Groups[1].Value} {m.Groups[2].Value} {m.Groups[5].Value} {m.Groups[3].Value} {m.Groups[4].Value}";
            if (!DateTimeOffset.TryParseExact(reformatted, "MMM d yyyy HH:mm:ss zzz", CultureInfo.InvariantCulture, DateTimeStyles.None, out dto))
                return null;
        }
        else if (double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var num) && num > 1e9)
        {
            var ms = num > 1e12 ? (long)num : (long)(num * 1000.0);
            dto = DateTimeOffset.FromUnixTimeMilliseconds(ms);
        }
        else if (!DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out dto))
        {
            return null;
        }
        return dto.ToLocalTime().ToString("f", CultureInfo.CurrentCulture);
    }
}
