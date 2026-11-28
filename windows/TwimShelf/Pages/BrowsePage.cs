// 浏览: the library as cards — one per post (or one per media when not grouped) — in columns whose
// cards are as tall as their content, in a random order that 重新随机 deals again. Its search field
// and buttons float in a bar over the top of the cards (they scroll on beneath it; reading on down
// draws it into the top right corner, scrolling back up spreads it out again): 按添加时间排序,
// 按帖子分组, 下载帖子 and 重新随机 with nothing searched; 导出搜索结果 while searching. Every filter of
// 浏览 is a search.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Search;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class BrowsePage : UserControl, IShellPage
{
    readonly LibraryModel _library;
    readonly MasonryView _masonry = new();
    readonly TextBlock _empty;
    readonly ProgressRing _loading = new() { IsActive = true, Width = 40, Height = 40 };
    readonly CapsuleSearch _search = new() { MinWidth = 0 };
    readonly Grid _bar;
    const double BarSpace = 64; // the bar's height and the gap around it: where the first cards start
    readonly StackPanel _buttons = new() { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
    readonly FeedOrder _order = new();
    readonly Dictionary<string, int> _cardPages = [];
    TokenQuery _query = new();
    List<FeedItem> _items = [];
    List<List<FeedItem>>? _cards;
    bool _grouped = Prefs.Instance.FeedGrouped;
    int _revision = -1, _generation, _density;
    FeedItem? _pendingReveal;
    bool _clearedForReveal, _sizesWatched;
    Button? _downloadButton;

    public event Action? ChromeChanged;
    public string Title => L("place.browse");
    public string Subtitle => _library.Stats is { } s ? L("activity.stats", s.Posts, s.Photos, s.Videos) : "";

    public BrowsePage(LibraryModel library)
    {
        _library = library;
        var env = Environment.GetEnvironmentVariable("TL_SEARCH");
#if DEBUG
        if (env != null) _query = TokenQuery.Parse(env);
#endif
        _search.Folders = () => [.. (_library.Folders?.Folders ?? []).Select(f => (f.Name, f.Count))];
        _search.Changed += q => { _query = q; BuildButtons(); _ = Load(); };
        if (_query.Keys.Count > 0) _search.SetKeys(_query.Keys);
        _bar = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        _bar.Children.Add(_search);
        Grid.SetColumn(_buttons, 1);
        _buttons.Margin = new Thickness(6, 0, 0, 0);
        _bar.Children.Add(_buttons);
        _search.MaxWidth = double.PositiveInfinity;

        _masonry.Host = new CardMenuHost(
            OnlyAuthor: (key, _) => Search(new FeedFilter { Author = key }),
            OnlyLabel: label => Search(new FeedFilter { Labels = [label] }),
            AddTerm: term => _search.AddKey(TokenQuery.TermKey(term.ToLowerInvariant())));
        _masonry.PageOf = key => _cardPages.GetValueOrDefault(key);
        _masonry.PageChanged = (key, p) => _cardPages[key] = p;
        _masonry.Open = OpenViewer;
        _empty = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxWidth = 460,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        _loading.HorizontalAlignment = HorizontalAlignment.Center;
        _loading.VerticalAlignment = VerticalAlignment.Center;
        _masonry.TopPadding = BarSpace;
        var floating = new Border
        {
            Child = _bar,
            Padding = new Thickness(6),
            CornerRadius = new CornerRadius(23),
            BorderThickness = new Thickness(1),
            BorderBrush = (Brush)Application.Current.Resources["SurfaceStrokeColorFlyoutBrush"],
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(16, 8, 16, 0),
        };
        // the vertical wheel over the bar (even over search chips) still scrolls the cards beneath it
        floating.AddHandler(PointerWheelChangedEvent, new PointerEventHandler((_, e) =>
        {
            var p = e.GetCurrentPoint(floating).Properties;
            if (p.IsHorizontalMouseWheel || p.MouseWheelDelta == 0) return;
            var target = Math.Clamp(_masonry.Scroll.VerticalOffset - p.MouseWheelDelta, 0, _masonry.Scroll.ScrollableHeight);
            _masonry.Scroll.ChangeView(null, target, null, true);
            e.Handled = true;
        }), handledEventsToo: true);
        Content = new Grid { Children = { _masonry, _empty, _loading, floating } };
        WatchScrolling(floating);
        SizeChanged += (_, _) => UpdateColumns();
        _library.Changed += OnLibraryChanged;
        Prefs.Instance.Changed += OnPrefs;
        _library.RevealRequested += item => { _pendingReveal = item; RevealNow(); };
        _library.FilterRequested += f => Search(f, replacing: true);
        Viewer.Closed += () => _masonry.RefreshVideos();
        _density = Prefs.Instance.DensityPortrait * 3 + Prefs.Instance.DensityLandscape;
        BuildButtons();
        _ = Load();
    }

    // ---- the floating bar ------------------------------------------------------------------------

    const double BarWidest = 820, SearchCompact = 200;

    /// At the top the bar is long, in the middle; reading on (scrolling down) draws it narrower into
    /// the top right corner, out of the way; scrolling back up, or focusing its search field, spreads
    /// it out again. The width eases while the bar slides from the middle to the corner (both from
    /// its right edge, so the buttons stay put under the pointer at the corner).
    void WatchScrolling(Border bar)
    {
        var move = new TranslateTransform();
        bar.RenderTransform = move;
        var ease = new ExponentialEase { EasingMode = EasingMode.EaseOut, Exponent = 6 };
        Storyboard? running = null;
        double last = 0, travel = 0;
        var wide = true;

        (double Width, float Shift) Target()
        {
            var room = Math.Max(0, ActualWidth - 32);
            if (wide)
            {
                var w = Math.Min(BarWidest, room);
                return (w, -(float)((room - w) / 2));
            }
            _buttons.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            return (Math.Min(room, SearchCompact + _buttons.DesiredSize.Width + 6 + 14), 0);
        }
        void Place(bool animate)
        {
            var (w, shift) = Target();
            // a change of mind halfway: carry on from where it is now
            if (running != null) { var nowW = bar.ActualWidth; var nowX = move.X; running.Stop(); running = null; bar.Width = nowW; move.X = nowX; }
            if (!animate || double.IsNaN(bar.Width) || bar.ActualWidth <= 0)
            {
                bar.Width = w;
                move.X = shift;
                return;
            }
            var from = bar.ActualWidth;
            var anim = new DoubleAnimation
            {
                From = from, To = w, Duration = TimeSpan.FromMilliseconds(320),
                EasingFunction = ease, EnableDependentAnimation = true,
            };
            Storyboard.SetTarget(anim, bar);
            Storyboard.SetTargetProperty(anim, "Width");
            var slide = new DoubleAnimation { From = move.X, To = shift, Duration = anim.Duration, EasingFunction = ease };
            Storyboard.SetTarget(slide, move);
            Storyboard.SetTargetProperty(slide, "X");
            var sb = new Storyboard { Children = { anim, slide } };
            sb.Completed += (_, _) => { if (running != sb) return; running = null; sb.Stop(); bar.Width = w; move.X = shift; _search.Reposition(); };
            running = sb;
            sb.Begin();
        }
        void Set(bool w, bool animate = true)
        {
            if (w == wide) return;
            wide = w;
            _search.Compact = !w;
            Place(animate && !_masonry.IsLayingOut);
        }
        SizeChanged += (_, _) => { last = _masonry.Scroll.VerticalOffset; travel = 0; Place(false); };
        _buttons.SizeChanged += (_, _) => { if (running == null) Place(false); };
        _masonry.Scroll.ViewChanged += (_, _) =>
        {
            var y = _masonry.Scroll.VerticalOffset;
            var d = y - last;
            last = y;
            if (y < BarSpace || _search.HasFocus) { travel = 0; Set(true); return; }
            if (_masonry.IsLayingOut) return;
            // a little travel the same way first: small jitters of the wheel or touch don't flicker it
            travel = Math.Sign(d) == Math.Sign(travel) ? travel + d : d;
            if (travel > 24) Set(false);
            else if (travel < -40) Set(true);
        };
        _search.GotFocus += (_, _) => Set(true);
    }

    // ---- the bar's buttons --------------------------------------------------------------------

    void BuildButtons()
    {
        _buttons.Children.Clear();
        Button B(string glyph, string tip, Action click, bool on = false, string? id = null)
        {
            var b = new Button();
            b.Click += (_, _) => click();
            b.Content = new FontIcon { Glyph = glyph, FontSize = 14 };
            b.Width = 36;
            b.Height = 34;
            b.Padding = new Thickness(0);
            b.CornerRadius = new CornerRadius(17);
            ToolTipService.SetToolTip(b, tip);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, tip);
            if (id != null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(b, id);
            return b;
        }
        if (_query.Keys.Count > 0)
        {
            _buttons.Children.Add(B("", L("export.search.title"), () => _ = ExportSearch(), id: "searchExport"));
            return;
        }
        var sort = new ToggleButton { IsChecked = Prefs.Instance.FeedByAdded, Content = new FontIcon { Glyph = "", FontSize = 14 }, Width = 36, Height = 34, Padding = new Thickness(0), CornerRadius = new CornerRadius(17) };
        ToolTipService.SetToolTip(sort, L("feed.sortByAdded"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(sort, L("feed.sortByAdded"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(sort, "sortByAdded");
        sort.Click += (_, _) => { Prefs.Instance.FeedByAdded = sort.IsChecked == true; BuildButtons(); _ = Load(scrollTop: true); };
        _buttons.Children.Add(sort);
        var group = new ToggleButton { IsChecked = _grouped, Content = new FontIcon { Glyph = "", FontSize = 14 }, Width = 36, Height = 34, Padding = new Thickness(0), CornerRadius = new CornerRadius(17) };
        ToolTipService.SetToolTip(group, L("feed.groupByPost"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(group, L("feed.groupByPost"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(group, "groupByPost");
        group.Click += (_, _) => { _grouped = group.IsChecked == true; Prefs.Instance.FeedGrouped = _grouped; _ = Load(); };
        _buttons.Children.Add(group);
        _downloadButton = B("", L("common.downloadPosts"), QuickDownload, id: "quickDownload");
        _buttons.Children.Add(_downloadButton);
        if (!Prefs.Instance.FeedByAdded) _buttons.Children.Add(B("", L("feed.reshuffle"), Shuffle, id: "reshuffle"));
    }

    /// 下载帖子 (the button, or the taskbar's jump list).
    public void QuickDownload()
    {
        if (_downloadButton == null || _query.Keys.Count > 0) { _search.Clear(); BuildButtons(); }
        DispatcherQueue.TryEnqueue(() => Controls.QuickDownload.Show((FrameworkElement?)_downloadButton ?? _search, _library.Downloads,
            () => MainWindow.Current?.OpenSettingsPage("downloads")));
    }

    void Shuffle()
    {
        if (Prefs.Instance.FeedByAdded) return;
        _order.Reshuffle();
        _ = Load(scrollTop: true);
    }

    // ---- search, load -------------------------------------------------------------------------

    /// A filter as capsules, after what is searched already or in its place.
    void Search(FeedFilter f, bool replacing = false)
    {
        var keys = TokenQuery.Adding(TokenQuery.KeysFor(f), replacing ? [] : _query.Keys);
        _search.SetKeys(keys);
    }

    void OnLibraryChanged()
    {
        ChromeChanged?.Invoke();
        if (_library.Revision != _revision) _ = Load();
    }

    void OnPrefs()
    {
        _search.UpdateSearchIcon();
        var d = Prefs.Instance.DensityPortrait * 3 + Prefs.Instance.DensityLandscape;
        if (d != _density) { _density = d; UpdateColumns(); }
    }

    void UpdateColumns()
    {
        var w = ActualWidth;
        if (w <= 0) return;
        var cols = Prefs.Instance.FeedColumns(w, XamlRoot?.Size.Height ?? 800);
        _masonry.SidePadding = w > 700 ? 24 : 12;
        if (cols != _masonry.Columns) { _masonry.Columns = cols; _masonry.Layout(); }
    }

    /// 导出搜索结果: the result of the search as it is now, asked for again (what is shown may
    /// still be the previous search's while it loads).
    async Task ExportSearch()
    {
        var q = _query;
        List<FeedItem> items;
        try { items = q.IsContradictory ? [] : await _library.Feed(q.Request(Prefs.Instance.FeedByAdded, _grouped)); }
        catch (Exception e) { Dialogs.Toast(MainWindow.Current!, e.Message); return; }
        await SearchExport.Run(items, q.Terms);
    }

    async Task Load(bool scrollTop = false)
    {
        _revision = _library.Revision;
        var gen = ++_generation;
        var q = _query;
        List<FeedItem> items;
        try
        {
            // a contradiction (视频 -视频) finds nothing without asking the core
            items = q.IsContradictory ? [] : await _library.Feed(q.Request(Prefs.Instance.FeedByAdded, _grouped));
        }
        catch (Exception e) { Diagnostics.Log("feed: " + e); items = []; }
        if (gen != _generation) return;
        var newOrder = _cards == null || scrollTop;
        _items = Prefs.Instance.FeedByAdded ? items : _order.Apply(items);
        _cards = Group(_items);
        _loading.IsActive = false;
        _loading.Visibility = Visibility.Collapsed;
        _empty.Text = _query.Keys.Count == 0 ? L("feed.empty.library.app") : L("feed.empty.noMatch");
        _empty.Visibility = _cards.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        _masonry.Grouped = _grouped;
        _masonry.Marks = _query.Marks;
        UpdateColumns();
        _masonry.SetCards(_cards, keepOffset: !newOrder && !scrollTop && gen > 1);
        RevealNow();
        if (!_sizesWatched && items.Any(i => i.Width == 0))
        {
            _sizesWatched = true;
            _ = AfterSizes();
        }
    }

    /// A feed read while the core was still reading media sizes shows them once that has finished.
    async Task AfterSizes()
    {
        try { while (TlCore.MediaSizesFilling()) await Task.Delay(2000); }
        catch { return; }
        await Load();
    }

    List<List<FeedItem>> Group(List<FeedItem> items)
    {
        if (!_grouped) return [.. items.Select(i => new List<FeedItem> { i })];
        return Prefs.Instance.FeedByAdded ? FeedOrder.PostsInPlace(items) : _order.Posts(items);
    }

    /// The post asked for (在浏览中查看帖子) goes first, marked for a moment, and the list goes to the top.
    void RevealNow()
    {
        var item = _pendingReveal;
        var cards = _cards;
        if (item == null || cards == null) return;
        var i = cards.FindIndex(c => c.Any(m => m.PostId == item.PostId));
        if (i < 0)
        {
            // hidden by what narrows the list: that goes, once; a post that has gone just stops here
            if (_clearedForReveal) { _pendingReveal = null; _clearedForReveal = false; return; }
            _clearedForReveal = true;
            Search(new FeedFilter(), replacing: true);
            return;
        }
        _pendingReveal = null;
        _clearedForReveal = false;
        if (i > 0) _cards = [cards[i], .. cards.Take(i), .. cards.Skip(i + 1)];
        _masonry.Highlight = item.PostId;
        _masonry.SetCards(_cards);
        var t = DispatcherQueue.CreateTimer();
        t.Interval = TimeSpan.FromMilliseconds(1600);
        t.IsRepeating = false;
        t.Tick += (_, _) => { _masonry.Highlight = null; _masonry.Refresh(); };
        t.Start();
    }

    /// Every media in the order of the cards: turning the page goes on into the next post.
    void OpenViewer(FeedItem item)
    {
        var all = (_cards ?? []).SelectMany(c => c).ToList();
        var root = MainWindow.Current?.ViewerHost as UIElement;
        var initialRect = root != null ? _masonry.ViewerSourceFrame(item, root) : null;
        Viewer.Open(all, Math.Max(0, all.FindIndex(i => i.MediaId == item.MediaId)), new ViewerOpenOptions
        {
            CropSource = false,
            SourceCornerRadius = 8,
            SourceRect = current =>
            {
                if (root == null) return null;
                return _masonry.ViewerSourceFrame(current, root) ?? (current.MediaId == item.MediaId ? initialRect : null);
            },
            ActiveMediaChanged = id => _masonry.SetHiddenMedia(id),
            SyncBeforeClose = current => _masonry.SyncCardPageForMedia(current),
            PreviewImage = current => _masonry.PreviewImageFor(current.MediaId),
        });
    }

    public void Shown()
    {
        ChromeChanged?.Invoke();
        _masonry.RefreshVideos();
    }

    /// Another place is shown: the cards' videos stop (their players would go on in a page off the window).
    public void Hidden() => InlineVideo.StopAll();
}
