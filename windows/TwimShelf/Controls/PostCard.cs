// One card of 浏览: a post (or one media), its media to page through (arrows on hover, the wheel
// sideways, the counter at the top right), the author, the whole text (selectable), the link, and
// the tags in one row with the + at its end — the other apps' card, drawn with Fluent controls.
// A video plays muted and looping while it is on screen; every video in view plays.
using Microsoft.UI.Text;
using Windows.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using TwimShelf.Search;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public sealed partial class PostCard : UserControl
{
    public List<FeedItem> Media { get; private set; } = [];
    public int Page { get; private set; }
    public Action<FeedItem>? Open { get; set; }
    public Action<int>? PageChanged { get; set; }
    public CardMenuHost? Host { get; set; }
    public bool OnScreen { get; private set; }

    readonly Border _card;
    readonly Grid _mediaArea;
    readonly Image _image = new() { Stretch = Stretch.Uniform };
    readonly InlineVideo _video = new();
    readonly Button _prev, _next;
    readonly Border _counter;
    readonly TextBlock _counterText = new() { Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), FontSize = 12, FontWeight = FontWeights.SemiBold };
    readonly TextBlock _author = new() { TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 };
    readonly RichTextBlock _text = new() { IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0) };
    readonly HyperlinkButton _link = new() { Padding = new Thickness(0), Margin = new Thickness(0, 4, 0, 0) };
    readonly StackPanel _tags = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    readonly Grid _tagRow;
    readonly double _width;
    CancellationTokenSource? _loading;
    SearchMarks _marks = SearchMarks.None;

    public PostCard(double width)
    {
        _width = width;
        Width = width;
        _mediaArea = new Grid { Background = (Brush)Application.Current.Resources["ControlFillColorSecondaryBrush"] };
        _mediaArea.Children.Add(_image);
        _mediaArea.Children.Add(_video);
        _prev = Arrow("", HorizontalAlignment.Left, () => Turn(-1));
        _next = Arrow("", HorizontalAlignment.Right, () => Turn(1));
        _mediaArea.Children.Add(_prev);
        _mediaArea.Children.Add(_next);
        _counter = new Border
        {
            Child = _counterText,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x8A, 0, 0, 0)),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(8, 3, 8, 3),
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(10),
            IsHitTestVisible = false,
        };
        _mediaArea.Children.Add(_counter);
        _mediaArea.PointerEntered += (_, _) => ShowArrows(true);
        _mediaArea.PointerExited += (_, _) => ShowArrows(false);
        // a tap on the media opens the viewer; one on the page arrows only turns the page
        _mediaArea.Tapped += (_, e) => { if (!InsideButton(e.OriginalSource as DependencyObject)) Open?.Invoke(Media[Page]); };
        _mediaArea.PointerWheelChanged += OnWheel;
        _link.Click += (_, _) => { if (Media.Count > 0 && Media[0].Url is { } u) _ = Windows.System.Launcher.LaunchUriAsync(new Uri(u)); };

        var add = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 12 },
            Width = 28, Height = 28, Padding = new Thickness(0),
            CornerRadius = new CornerRadius(14),
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTipService.SetToolTip(add, L("card.addTag"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(add, L("card.addTag"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(add, "addTag");
        add.Click += (_, _) => _ = TagPicker.Show(Media[Page], false);
        _tagRow = new Grid { Margin = new Thickness(0, 10, 0, 0), ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        var tagScroll = new ScrollViewer
        {
            Content = _tags,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            HorizontalScrollMode = ScrollMode.Enabled,
            VerticalScrollMode = ScrollMode.Disabled,
            Height = 28,
            Margin = new Thickness(0, 0, 6, 0),
        };
        _tagRow.Children.Add(tagScroll);
        Grid.SetColumn(add, 1);
        _tagRow.Children.Add(add);

        var caption = new StackPanel { Padding = new Thickness(14, 12, 14, 12), Children = { _author, _text, _link, _tagRow } };
        _glass = Glass(caption);
        Grid.SetRow(_glass, 1);
        _card = new Border
        {
            CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
            Child = new Grid { RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition { Height = GridLength.Auto } }, Children = { _mediaArea, _glass } },
        };
        Content = _card;
        ActualThemeChanged += (_, _) => Tint();
        RightTapped += (_, e) =>
        {
            if (Media.Count == 0) return;
            var item = Media[Page];
            var menu = Host != null ? CardMenu.Build(item, Host) : MediaActions.Menu(item);
            menu.ShowAt(this, e.GetPosition(this));
            e.Handled = true;
        };
    }

    // ---- the caption's pane ------------------------------------------------------------------
    // As on the Mac card, the caption sits on a pane of its own with round top corners right under
    // the media, a light rim along its upper edge.
    public const double GlassRadius = 18;
    readonly Grid _glass;
    readonly Border _tint = new() { IsHitTestVisible = false };
    readonly Border _rim = new() { Height = 1, VerticalAlignment = VerticalAlignment.Top, IsHitTestVisible = false, Margin = new Thickness(GlassRadius * 0.6, 0, GlassRadius * 0.6, 0) };

    Grid Glass(UIElement content)
    {
        var g = new Grid { CornerRadius = new CornerRadius(GlassRadius, GlassRadius, 0, 0) };
        g.Children.Add(_tint);
        g.Children.Add(_rim);
        g.Children.Add(content);
        Tint();
        return g;
    }

    void Tint()
    {
        var dark = ActualTheme == ElementTheme.Dark;
        var c = dark ? Windows.UI.Color.FromArgb(255, 0x2B, 0x2B, 0x2B) : Windows.UI.Color.FromArgb(255, 0xFB, 0xFB, 0xFB);
        Windows.UI.Color A(double a) => Windows.UI.Color.FromArgb((byte)(a * 255), c.R, c.G, c.B);
        _tint.Background = new SolidColorBrush(A(0.96));
        var rim = Windows.UI.Color.FromArgb(255, 255, 255, 255);
        _rim.Background = new LinearGradientBrush
        {
            StartPoint = new Windows.Foundation.Point(0, 0),
            EndPoint = new Windows.Foundation.Point(1, 0),
            GradientStops =
            {
                new GradientStop { Color = Windows.UI.Color.FromArgb(0, 255, 255, 255), Offset = 0 },
                new GradientStop { Color = Windows.UI.Color.FromArgb((byte)(dark ? 70 : 150), rim.R, rim.G, rim.B), Offset = 0.5 },
                new GradientStop { Color = Windows.UI.Color.FromArgb(0, 255, 255, 255), Offset = 1 },
            },
        };
    }

    bool InsideButton(DependencyObject? d)
    {
        for (; d != null && d != _mediaArea; d = VisualTreeHelper.GetParent(d))
            if (d is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return true;
        return false;
    }

    static Button Arrow(string glyph, HorizontalAlignment side, Action click)
    {
        var b = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14, Foreground = new SolidColorBrush(Microsoft.UI.Colors.White) },
            Width = 36, Height = 36, Padding = new Thickness(0),
            CornerRadius = new CornerRadius(18),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(0x60, 0, 0, 0)),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(8),
            Visibility = Visibility.Collapsed,
        };
        var tip = L(side == HorizontalAlignment.Left ? "viewer.previous" : "viewer.next");
        ToolTipService.SetToolTip(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, side == HorizontalAlignment.Left ? "cardPrev" : "cardNext");
        b.Click += (_, _) => click();
        return b;
    }

    void ShowArrows(bool hover)
    {
        _prev.Visibility = hover && Page > 0 ? Visibility.Visible : Visibility.Collapsed;
        _next.Visibility = hover && Page < Media.Count - 1 ? Visibility.Visible : Visibility.Collapsed;
    }

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        var p = e.GetCurrentPoint(_mediaArea).Properties;
        if (!p.IsHorizontalMouseWheel || Media.Count < 2) return;
        Turn(p.MouseWheelDelta > 0 ? 1 : -1);
        e.Handled = true;
    }

    /// Height of the card's media for a width: the media's own shape (4:5 until known), kept within reason.
    public static double MediaHeight(FeedItem i, double width) => width / i.CardAspectRatio;

    public void Bind(List<FeedItem> media, int page, SearchMarks marks, bool highlighted)
    {
        Media = media;
        Page = Math.Clamp(page, 0, media.Count - 1);
        _marks = marks;
        var first = media[0];
        var loose = first.IsLoose();
        // author line
        _author.Inlines.Clear();
        if (loose)
        {
            _author.Inlines.Add(new Run { Text = first.Album ? L("place.album") : L("place.loose"), FontWeight = FontWeights.SemiBold, Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] });
        }
        else
        {
            AddMarked(_author.Inlines, first.AuthorName ?? L("common.unknownAuthor"), marks.Author, FontWeights.SemiBold, null);
            if (first.ScreenName != null) AddMarked(_author.Inlines, "  @" + first.ScreenName, marks.Author, FontWeights.Normal, (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"]);
        }
        // text
        _text.Blocks.Clear();
        var text = first.Text ?? "";
        _text.Visibility = text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (text.Length > 0)
        {
            var p = new Paragraph();
            AddMarked(p.Inlines, text, marks.Text, FontWeights.Normal, null);
            _text.Blocks.Add(p);
        }
        _link.Visibility = first.Url != null ? Visibility.Visible : Visibility.Collapsed;
        _link.Content = new TextBlock { Text = first.Url ?? "", TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12 };
        _card.BorderBrush = highlighted ? (Brush)Application.Current.Resources["AccentFillColorDefaultBrush"] : (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"];
        _card.BorderThickness = new Thickness(highlighted ? 3 : 1);
        ShowPage();
    }

    void AddMarked(InlineCollection inlines, string text, IReadOnlyList<string> terms, FontWeight weight, Brush? color)
    {
        var ranges = terms.Count == 0 ? [] : SearchMarks.Ranges(terms, text);
        var at = 0;
        Run R(string s) { var r = new Run { Text = s, FontWeight = weight }; if (color != null) r.Foreground = color; return r; }
        foreach (var (start, end) in ranges)
        {
            if (start > at) inlines.Add(R(text[at..start]));
            // marked: a highlight span (Runs have no background of their own)
            var h = new Span { FontWeight = FontWeights.Bold, Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] };
            h.Inlines.Add(new Run { Text = text[start..end] });
            inlines.Add(h);
            at = end;
        }
        if (at < text.Length) inlines.Add(R(text[at..]));
    }

    void ShowPage()
    {
        var item = Media[Page];
        _mediaArea.Height = MediaHeight(item, _width);
        _counter.Visibility = Media.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        _counterText.Text = $"{Page + 1}/{Media.Count}";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_counter, _counterText.Text);
        ShowArrows(_prev.Visibility == Visibility.Visible || _next.Visibility == Visibility.Visible);
        // tags of the page shown
        _tags.Children.Clear();
        foreach (var t in item.Tags) _tags.Children.Add(Chip(t));
        var loose = Media[0].IsLoose();
        _tagRow.Visibility = item.Tags.Count > 0 || !loose ? Visibility.Visible : Visibility.Collapsed;
        LoadMedia();
    }

    /// A tag as the other apps show it (TagStyle): pink with a sparkle for an AI's suggestion, blue
    /// with a tag for one the person added or approved.
    Border Chip(TagView t)
    {
        var dark = ActualTheme == ElementTheme.Dark;
        var color = new SolidColorBrush(TagStyle.Tint(t, dark));
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(TagStyle.Icon(t, 11, color));
        var label = new TextBlock { FontSize = 13, Foreground = color, FontWeight = FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
        AddMarked(label.Inlines, t.Label, _marks.Tags, FontWeights.Medium, color);
        row.Children.Add(label);
        return new Border
        {
            Child = row,
            Height = 28,
            Padding = new Thickness(10, 0, 10, 0),
            CornerRadius = new CornerRadius(14),
            Background = new SolidColorBrush(TagStyle.Fill(t, dark)),
        };
    }

    void Turn(int by)
    {
        var p = Math.Clamp(Page + by, 0, Media.Count - 1);
        if (p == Page) return;
        Page = p;
        PageChanged?.Invoke(p);
        ShowPage();
    }

    void LoadMedia()
    {
        _loading?.Cancel();
        var cancel = _loading = new CancellationTokenSource();
        var item = Media[Page];
        _image.Source = null;
        _video.Stop();
        if (item.IsVideo)
        {
            _ = Poster(item, cancel.Token);
            UpdateVideo();
            return;
        }
        _ = Photo(item, cancel.Token);
    }

    async Task Photo(FeedItem item, CancellationToken cancel)
    {
        var path = await Thumbnails.Displayable(item.Path, 2048);
        if (cancel.IsCancellationRequested) return;
        var px = (int)Math.Clamp(_width * (XamlRoot?.RasterizationScale ?? 1), 256, 2048);
        try
        {
            _image.Source = new BitmapImage { DecodePixelWidth = px, DecodePixelType = DecodePixelType.Physical, UriSource = new Uri(path) };
        }
        catch { }
    }

    async Task Poster(FeedItem item, CancellationToken cancel)
    {
        var src = await Thumbnails.VideoPoster(item.Path, (uint)Math.Min(1024, _width * 2), cancel).ConfigureAwait(true);
        if (!cancel.IsCancellationRequested && src != null) _image.Source = src;
    }

    /// The card is on screen (half or more) or left it: its video plays or stops.
    public void SetOnScreen(bool on)
    {
        if (on == OnScreen) return;
        OnScreen = on;
        UpdateVideo();
    }

    /// Its video plays or stops for where the card is now (and waits while the feed is scrolling).
    public void UpdateVideo()
    {
        if (Media.Count == 0) return;
        var item = Media[Page];
        // while the feed scrolls nothing starts, but what plays goes on (stopping it here also cut off
        // the player the viewer had just given back: closing the viewer lays the feed out again)
        if (item.IsVideo && OnScreen && !Viewer.IsOpen) { if (!InlineVideo.Held || _video.IsPlaying(item.Path)) _video.Play(item.Path); }
        else _video.Stop();
    }

    public void Recycle()
    {
        _loading?.Cancel();
        _image.Source = null;
        _video.Stop();
        OnScreen = false;
    }
}
