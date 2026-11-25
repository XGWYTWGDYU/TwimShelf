// 浏览's columns: each card goes to the shortest column, as the other apps place them, and only the
// cards near the screen exist. Where every card is comes from its data (media sizes, an estimate of
// its text) until the card has been laid out once, then from that layout (remembered per card). A
// card above the screen that turns out taller or shorter moves the scroll position with it, so what
// is on screen stays still. Nothing is laid out for the cards far away, however long the list.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Core;
using TwimShelf.Search;
using Windows.Foundation;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public sealed partial class MasonryView : UserControl
{
    public const double MainSpacing = 18, CrossSpacing = 14;
    public ScrollViewer Scroll { get; }
    readonly Canvas _canvas = new();
    readonly TextBlock _footerText = new() { Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
    readonly Grid _footer;

    List<List<FeedItem>> _cards = [];
    public int Columns { get; set; } = 3;
    public double TopPadding { get; set; } = 8;
    public double SidePadding { get; set; } = 24;
    public Func<string, int> PageOf { get; set; } = _ => 0;
    public Action<string, int>? PageChanged { get; set; }
    public Action<FeedItem>? Open { get; set; }
    public CardMenuHost? Host { get; set; }
    public SearchMarks Marks { get; set; } = SearchMarks.None;
    public string? Highlight { get; set; }
    public bool Grouped { get; set; } = true;

    // places (index → offset, extent, column) of the first cards; the rest are not placed yet
    readonly List<double> _offset = [], _extent = [];
    readonly List<int> _column = [];
    double[] _bottoms = [];
    readonly Dictionary<string, double> _measured = [];
    readonly Dictionary<int, PostCard> _live = [];
    readonly Stack<PostCard> _pool = new();
    // the cards on the canvas, kept here: asking a card for its Parent did not always say it was
    // there already, and adding it again threw "already the child of another element"
    readonly HashSet<PostCard> _placed = [];
    double _width = -1;
    bool _laying, _again;
    string? _hiddenMediaId;

    public MasonryView()
    {
        _footer = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
        var line = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"];
        _footer.Children.Add(new Border { Height = 1, Background = line, VerticalAlignment = VerticalAlignment.Center });
        var mid = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(12, 0, 12, 0) };
        mid.Children.Add(new FontIcon { Glyph = "", FontSize = 14, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        _footerText.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        mid.Children.Add(_footerText);
        Grid.SetColumn(mid, 1);
        _footer.Children.Add(mid);
        var right = new Border { Height = 1, Background = line, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(right, 2);
        _footer.Children.Add(right);
        _footer.Visibility = Visibility.Collapsed;
        _canvas.Children.Add(_footer);
        Scroll = new ScrollViewer { Content = _canvas, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Content = Scroll;
        // a card shown stays where it is when cards above it change height (measured unlike their
        // estimate): the scroll viewer's own anchoring, not ChangeView from here. Calling ChangeView
        // while a wheel scroll is animating ends the process (E_UNEXPECTED inside WinUI).
        Scroll.VerticalAnchorRatio = 0;
        // focusable, without a ring: it holds focus for a card scrolling away (KeepFocus)
        Scroll.IsTabStop = true;
        Scroll.UseSystemFocusVisuals = false;
        Scroll.ViewChanged += (_, _) =>
        {
            InlineVideo.Held = true;
            _settle ??= MakeSettle();
            _settle.Stop();
            _settle.Start();
            Layout();
        };
        Scroll.SizeChanged += (_, _) => Layout();
    }

    /// A new list (or the same cards in a new order): placed again from the top.
    public void SetCards(List<List<FeedItem>> cards, bool keepOffset = false)
    {
        // where the position stays (the library changed: a sync, a download), the cards on screen
        // whose media are still there stay too, at their new places: recycled and drawn again,
        // they all flashed with each change a sync brought
        var kept = new Dictionary<string, PostCard>();
        if (keepOffset)
            foreach (var (i, c) in _live)
                if (i < _cards.Count) kept[KeyOf(i)] = c;
        _cards = cards;
        Forget();
        _live.Clear();
        if (kept.Count > 0)
            for (var i = 0; i < cards.Count; i++)
                if (kept.Remove(KeyOf(i), out var c))
                {
                    _live[i] = c;
                    c.Bind(cards[i], PageOf(KeyOf(i)), Marks, Highlight == cards[i][0].PostId);
                }
        foreach (var c in kept.Values) Recycle(c);
        if (!keepOffset) Scroll.ChangeView(null, 0, null, true);
        _footerText.Text = L(Grouped ? "feed.end.posts" : "feed.end.media", cards.Count);
        Layout();
    }

    /// The cards shown keep their place but redraw (marks, highlight).
    public void Refresh()
    {
        foreach (var (i, c) in _live)
            if (i < _cards.Count) c.Bind(_cards[i], PageOf(_cards[i][0].MediaId), Marks, Highlight == _cards[i][0].PostId);
        Layout();
    }

    void Forget()
    {
        _offset.Clear();
        _extent.Clear();
        _column.Clear();
        _bottoms = new double[Math.Max(1, Columns)];
    }

    double CardWidth => _width;
    string KeyOf(int i) => _cards[i][0].MediaId;

    double HeightOf(int i)
    {
        var k = KeyOf(i);
        if (_measured.TryGetValue(k, out var h)) return h;
        return CardHeights.Estimate(_cards[i], PageOf(k), CardWidth);
    }

    void Truncate(int n)
    {
        if (n >= _offset.Count) return;
        _offset.RemoveRange(n, _offset.Count - n);
        _extent.RemoveRange(n, _extent.Count - n);
        _column.RemoveRange(n, _column.Count - n);
        _bottoms = new double[Math.Max(1, Columns)];
        var found = new bool[_bottoms.Length];
        var left = _bottoms.Length;
        for (var i = n - 1; i >= 0 && left > 0; i--)
        {
            var c = _column[i];
            if (found[c]) continue;
            found[c] = true;
            left--;
            _bottoms[c] = _offset[i] + _extent[i] + MainSpacing;
        }
    }

    /// Places cards until no further card could start before target.
    void PlaceUntil(double target)
    {
        while (_offset.Count < _cards.Count)
        {
            var c = 0;
            for (var j = 1; j < _bottoms.Length; j++) if (_bottoms[j] < _bottoms[c]) c = j;
            if (_bottoms[c] > target && _offset.Count > 0) break;
            var e = HeightOf(_offset.Count);
            _offset.Add(_bottoms[c]);
            _extent.Add(e);
            _column.Add(c);
            _bottoms[c] += e + MainSpacing;
        }
    }

    /// The first card reaching below y (starts are in order; ends are not, across columns).
    int FirstReaching(double y)
    {
        int lo = 0, hi = _offset.Count;
        while (lo < hi) { var mid = (lo + hi) >> 1; if (_offset[mid] < y) lo = mid + 1; else hi = mid; }
        var first = Math.Min(lo, _offset.Count - 1);
        var closed = new bool[_bottoms.Length];
        var left = _bottoms.Length;
        for (var i = lo - 1; i >= 0 && left > 0; i--)
        {
            var c = _column[i];
            if (closed[c]) continue;
            if (_offset[i] + _extent[i] > y) first = i;
            else { closed[c] = true; left--; }
        }
        return first;
    }

    int LastStartingBefore(double y)
    {
        int lo = 0, hi = _offset.Count;
        while (lo < hi) { var mid = (lo + hi) >> 1; if (_offset[mid] < y) lo = mid + 1; else hi = mid; }
        return lo - 1;
    }

    PostCard Card(int i)
    {
        if (_live.TryGetValue(i, out var c)) { c.SetWidth(_width); return c; }
        c = _pool.Count > 0 ? _pool.Pop() : MakeCard();
        c.SetWidth(_width);
        c.Bind(_cards[i], PageOf(KeyOf(i)), Marks, Highlight == _cards[i][0].PostId);
        c.SetMediaHidden(_hiddenMediaId != null && c.Media[c.Page].MediaId == _hiddenMediaId);
        c.Visibility = Visibility.Visible;
        if (_placed.Add(c)) _canvas.Children.Add(c);
        _live[i] = c;
        return c;
    }

    PostCard MakeCard()
    {
        var c = new PostCard(CardWidth) { CanBeScrollAnchor = true };
        c.Open = item => Open?.Invoke(item);
        c.PageChanged = p =>
        {
            var key = c.Media[0].MediaId;
            PageChanged?.Invoke(key, p);
            Layout();
        };
        c.Host = Host;
        return c;
    }

    void Unplace(PostCard c)
    {
        KeepFocus(c);
        c.Recycle();
        if (_placed.Remove(c)) _canvas.Children.Remove(c);
    }

    /// A card leaving with focus inside (a link or its text clicked) gives it to the feed itself
    /// first: left to WinUI, it went to the first focusable element, the search field, which then
    /// opened its suggestions in the middle of a scroll.
    void KeepFocus(PostCard c)
    {
        if (XamlRoot == null || FocusManager.GetFocusedElement(XamlRoot) is not DependencyObject f) return;
        for (var d = f; d != null; d = VisualTreeHelper.GetParent(d))
            if (ReferenceEquals(d, c)) { Scroll.Focus(FocusState.Programmatic); return; }
    }

    void Recycle(PostCard c)
    {
        KeepFocus(c);
        c.Recycle();
        c.Visibility = Visibility.Collapsed;
        if (!_pool.Contains(c)) _pool.Push(c);
    }

    public bool IsLayingOut => _laying;

    public void Layout()
    {
        if (_laying) { _again = true; return; }
        _laying = true;
        try
        {
            do
            {
                _again = false;
                LayoutOnce();
            } while (_again);
        }
        finally { _laying = false; }
    }

    void LayoutOnce()
    {
        var viewW = Scroll.ViewportWidth;
        if (viewW <= 0) return;
        Columns = Math.Max(1, Columns);
        var stride = (viewW - 2 * SidePadding + CrossSpacing) / Columns;
        var width = Math.Max(120, Math.Floor(stride - CrossSpacing));
        if (Math.Abs(width - _width) > 0.5 || _bottoms.Length != Columns)
        {
            _width = width;
            _measured.Clear();
            foreach (var c in _live.Values) c.SetWidth(width);
            Forget();
        }
        if (_cards.Count == 0)
        {
            _footer.Visibility = Visibility.Collapsed;
            _canvas.Height = 0;
            return;
        }
        var top = Scroll.VerticalOffset - TopPadding;
        var cache = Scroll.ViewportHeight;
        var start = Math.Max(0, top - cache);
        var end = top + Scroll.ViewportHeight + cache;


        int first = 0, last = 0;
        for (var pass = 0; pass < 8; pass++)
        {
            PlaceUntil(end);
            first = FirstReaching(start);
            last = Math.Max(first, LastStartingBefore(end));
            // keep exactly the cards first…last
            foreach (var k in _live.Keys.Where(k => k < first || k > last).ToList())
            {
                Recycle(_live[k]);
                _live.Remove(k);
            }
            int? changed = null;
            for (var i = first; i <= last && i < _cards.Count; i++)
            {
                var c = Card(i);
                c.Measure(new Windows.Foundation.Size(_width, double.PositiveInfinity));
                var h = c.DesiredSize.Height;
                _measured[KeyOf(i)] = h;
                if (i < _extent.Count && Math.Abs(h - _extent[i]) > 0.5) changed = Math.Min(changed ?? i, i);
            }
            if (changed == null) break;
            Truncate(changed.Value);
        }
        PlaceUntil(end);

        foreach (var (i, c) in _live)
        {
            if (i >= _offset.Count) continue;
            Canvas.SetLeft(c, SidePadding + _column[i] * stride);
            Canvas.SetTop(c, TopPadding + _offset[i]);
            var visibleTop = Math.Max(_offset[i], top);
            var visibleBottom = Math.Min(_offset[i] + _extent[i], top + Scroll.ViewportHeight);
            c.SetOnScreen(visibleBottom - visibleTop >= _extent[i] * 0.5);
        }

        var placed = _offset.Count;
        var tallest = Math.Max(0, _bottoms.Max() - MainSpacing);
        var all = placed >= _cards.Count;
        var extent = all ? tallest : tallest * _cards.Count / Math.Max(1, placed);
        _footer.Visibility = all ? Visibility.Visible : Visibility.Collapsed;
        if (all)
        {
            _footer.Width = viewW - 2 * SidePadding;
            Canvas.SetLeft(_footer, SidePadding);
            Canvas.SetTop(_footer, TopPadding + tallest + 16);
        }
        _canvas.Width = viewW;
        _canvas.Height = TopPadding + extent + (all ? 80 : 16);
    }

    Microsoft.UI.Dispatching.DispatcherQueueTimer? _settle;

    /// The scroll rested a moment: the videos in view start.
    Microsoft.UI.Dispatching.DispatcherQueueTimer MakeSettle()
    {
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(300);
        t.IsRepeating = false;
        t.Tick += (_, _) =>
        {
            InlineVideo.Held = false;
            foreach (var c in _live.Values) c.UpdateVideo();
        };
        return t;
    }

    /// The video cards stop or play again (the viewer opened or closed).
    public void RefreshVideos()
    {
        // what stopped starts again; what plays goes on (toggling them off and on restarted every
        // video, the one the viewer had just given back too)
        foreach (var c in _live.Values) c.UpdateVideo();
    }

    /// Hides or reveals the media inside whichever visible card currently displays `mediaId`.
    public void SetHiddenMedia(string? mediaId)
    {
        _hiddenMediaId = mediaId;
        foreach (var c in _live.Values)
            c.SetMediaHidden(mediaId != null && c.Media.Count > 0 && c.Media[c.Page].MediaId == mediaId);
    }

    /// If a visible multi-media card contains `item.MediaId` on another page, turns that card to
    /// `item`'s page so the viewer's zoom-close lands directly onto it.
    public void SyncCardPageForMedia(FeedItem item)
    {
        foreach (var c in _live.Values)
        {
            if (c.Media.Count <= 1) continue;
            if (c.Media.Any(m => m.MediaId == item.MediaId))
            {
                if (c.Media[c.Page].MediaId != item.MediaId && c.SetPageForMedia(item.MediaId))
                {
                    Layout();
                    UpdateLayout();
                }
                return;
            }
        }
    }

    /// Returns the fitted rect of the visible card currently showing `item.MediaId` in `relativeTo` coords.
    public Rect? ViewerSourceFrame(FeedItem item, UIElement relativeTo)
    {
        if (!Scroll.IsLoaded || Scroll.XamlRoot == null) return null;
        Rect visible;
        try
        {
            var pt = Scroll.TransformToVisual(relativeTo).TransformPoint(new Point(0, 0));
            visible = new Rect(pt.X, pt.Y, Scroll.ViewportWidth, Scroll.ViewportHeight);
        }
        catch { return null; }

        foreach (var c in _live.Values)
        {
            if (c.Media.Count > 0 && c.Media[c.Page].MediaId == item.MediaId)
                return c.ViewerSourceFrame(relativeTo, visible);
        }
        return null;
    }

    /// Returns the already-decoded card preview ImageSource for `mediaId` if currently mounted.
    public ImageSource? PreviewImageFor(string mediaId)
    {
        foreach (var c in _live.Values)
            if (c.Media.Count > 0 && c.Media[c.Page].MediaId == mediaId)
                return c.CurrentPreviewImage;
        return null;
    }
}

/// A card's height at a width, worked out from its data the way PostCard lays it out (as the other
/// apps' CardLayout): the text is not laid out, its lines are counted from character widths.
public static class CardHeights
{
    const double Sides = 28, Top = 12, Bottom = 12, Gap = 6, TagsGap = 10, Tags = 28, Author = 20, Small = 30, Body = 20;
    const double Narrow = 7.4, Wide = 14;

    public static double Estimate(List<FeedItem> media, int page, double width)
    {
        var first = media[0];
        var at = Math.Clamp(page, 0, media.Count - 1);
        var loose = first.IsLoose();
        var h = PostCard.MediaHeight(media[at], width) + Top + Author + 2;
        var text = first.Text ?? "";
        if (text.Length > 0) h += Gap + Lines(text, width - Sides - 3) * Body;
        if (first.Url != null) h += 4 + Small;
        if (media[at].Tags.Count > 0 || !loose) h += TagsGap + Tags;
        return h + Bottom;
    }

    static int Lines(string text, double width)
    {
        if (width <= 0) return 1;
        var n = 0;
        foreach (var p in text.Split('\n'))
        {
            double w = 0;
            foreach (var r in p.EnumerateRunes()) w += r.Value < 0x0500 ? Narrow : Wide;
            n += w == 0 ? 1 : (int)Math.Ceiling(w / (width * 0.96));
        }
        return n;
    }
}
