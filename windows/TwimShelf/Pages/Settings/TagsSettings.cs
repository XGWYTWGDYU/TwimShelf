// 标签: every tag as a Fluent 2 card (matching Mac TagCardsView and Web TagsPage): its name, how
// many media carry it, and a 3-color bar splitting those media into yours, both, and the AI's.
// The top-right arrow shows only that tag in Browse; the ellipsis button or right-click opens
// the rest (add all to folder, rename or merge, delete). Virtualized GridView handles long lists.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class TagsSettings : SettingsSubpage
{
    const double MarginX = 36, Gap = 12, MinCard = 215, CardHeight = 154;

    static readonly SolidColorBrush MineBrush = new(Windows.UI.Color.FromArgb(255, 59, 130, 246));
    static readonly SolidColorBrush AiBrush = new(Windows.UI.Color.FromArgb(255, 168, 85, 247));
    static readonly SolidColorBrush BothBrush = new(Windows.UI.Color.FromArgb(255, 34, 197, 94));

    readonly LibraryModel _library;
    readonly GridView _grid;
    readonly TextBox _filter = new() { PlaceholderText = L("tags.filter"), MinWidth = 160 };
    readonly DropDownButton _sortBtn = new();
    readonly TextBlock _sortText = new() { VerticalAlignment = VerticalAlignment.Center };
    readonly MenuFlyoutItem _deleteAiItem;
    readonly Segmented _show = new();
    readonly TextBlock _summary;
    readonly ProgressRing _loading = new() { IsActive = true, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    readonly StackPanel _empty;
    readonly FontIcon _emptyIcon;
    readonly TextBlock _emptyTitle;
    readonly TextBlock _emptyMsg;

    readonly Dictionary<Button, TagCount> _cardTags = [];
    readonly HashSet<Button> _wiredButtons = [];

    List<TagCount>? _tags;
    int _revision = -1;
    double _cardW;

    public override string Title => L("common.tags");

    public TagsSettings(LibraryModel library)
    {
        _library = library;
        TakeBody();

        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_filter, "tagFilter");
        _filter.TextChanged += (_, _) => ApplyFilter();

        _sortBtn.Content = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 6,
            Children = { new FontIcon { Glyph = "\uE8CB", FontSize = 13 }, _sortText },
        };
        RebuildSortMenu();

        _deleteAiItem = FolderActions.Item(L("tags.deleteAIEllipsis"), "\uE74D", () => _ = DeleteAi());
        _deleteAiItem.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        var moreMenu = new MenuFlyout { Items = { _deleteAiItem } };
        var moreBtn = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 14 }, Flyout = moreMenu };
        ToolTipService.SetToolTip(moreBtn, L("grid.more"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(moreBtn, L("grid.more"));

        var row1 = new Grid { ColumnSpacing = 8 };
        row1.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row1.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row1.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_filter, 0);
        Grid.SetColumn(_sortBtn, 1);
        Grid.SetColumn(moreBtn, 2);
        row1.Children.Add(_filter);
        row1.Children.Add(_sortBtn);
        row1.Children.Add(moreBtn);

        foreach (var label in new[] { L("search.kw.all.word"), L("search.kw.mine.word"), L("search.kw.ai.word"), L("search.kw.common.word") })
            _show.Items.Add(new SegmentedItem { Content = label });
        _show.SelectedIndex = 0;
        _show.SelectionChanged += (_, _) => ApplyFilter();

        var legend = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 12,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                LegendItem(L("search.kw.mine.word"), MineBrush),
                LegendItem("AI", AiBrush),
                LegendItem(L("search.kw.common.word"), BothBrush),
            },
        };

        var row2 = new Grid { ColumnSpacing = 12, Margin = new Thickness(0, 10, 0, 0) };
        row2.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row2.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row2.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_show, 0);
        Grid.SetColumn(legend, 2);
        row2.Children.Add(_show);
        row2.Children.Add(legend);

        _summary = new TextBlock
        {
            Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 8, 0, 0),
        };

        var toolbar = new StackPanel
        {
            Margin = new Thickness(MarginX, 8, MarginX, 12),
            Children = { row1, row2, _summary },
        };

        _grid = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = false,
            Padding = new Thickness(MarginX, 4, MarginX - Gap, 24),
            ItemTemplate = (DataTemplate)Application.Current.Resources["TagCardTemplate"],
        };
        _grid.ItemContainerStyle = new Style(typeof(GridViewItem))
        {
            Setters =
            {
                new Setter(FrameworkElement.MarginProperty, new Thickness(0, 0, Gap, Gap)),
                new Setter(Control.PaddingProperty, new Thickness(0)),
                new Setter(FrameworkElement.MinWidthProperty, 0.0),
                new Setter(FrameworkElement.MinHeightProperty, 0.0),
                new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch),
                new Setter(Control.VerticalContentAlignmentProperty, VerticalAlignment.Stretch),
            },
        };
        _grid.ContainerContentChanging += OnContainer;
        _grid.SizeChanged += (_, _) => Layout();
        _grid.Loaded += (_, _) => Layout();
        _grid.RightTapped += (_, e) =>
        {
            if ((e.OriginalSource as FrameworkElement)?.DataContext is not TagCount t) return;
            TagMenu(t).ShowAt(_grid, e.GetPosition(_grid));
            e.Handled = true;
        };

        _emptyIcon = new FontIcon
        {
            Glyph = "\uE8EC",
            FontSize = 34,
            Foreground = (Brush)Application.Current.Resources["TextFillColorTertiaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _emptyTitle = new TextBlock
        {
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _emptyMsg = new TextBlock
        {
            Style = (Style)Application.Current.Resources["BodyTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        _empty = new StackPanel
        {
            Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
            Children = { _emptyIcon, _emptyTitle, _emptyMsg },
        };

        var bodyHost = new Grid { Children = { _grid, _loading, _empty } };
        var root = new Grid
        {
            RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition() },
            Children = { toolbar, bodyHost },
        };
        Grid.SetRow(toolbar, 0);
        Grid.SetRow(bodyHost, 1);
        Content = root;

        _ = Load();
    }

    static StackPanel LegendItem(string name, Brush brush) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 5,
        VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            new Ellipse { Width = 8, Height = 8, Fill = brush, VerticalAlignment = VerticalAlignment.Center },
            new TextBlock
            {
                Text = name,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            },
        },
    };

    static long Common(TagCount t) => Math.Max(0, t.User + t.Ai - t.Count);

    static List<TagCount> Sorted(List<TagCount> tags, int order)
    {
        int By(long a, long b, TagCount x, TagCount y) => a != b ? b.CompareTo(a) : string.CompareOrdinal(x.Label, y.Label);
        var l = tags.ToList();
        l.Sort((x, y) => order switch
        {
            1 => By(x.User, y.User, x, y),
            2 => By(x.Ai, y.Ai, x, y),
            3 => string.CompareOrdinal(x.Label, y.Label),
            _ => By(x.Count, y.Count, x, y),
        });
        return l;
    }

    static string OrderTitle(int o) => o switch { 1 => L("tags.sort.mine"), 2 => L("tags.sort.ai"), 3 => L("common.name"), _ => L("tags.sort.count") };

    void RebuildSortMenu()
    {
        var order = Prefs.Instance.TagSort;
        _sortText.Text = L("tags.sortBy") + OrderTitle(order);
        var menu = new MenuFlyout();
        for (var o = 0; o < 4; o++)
        {
            var oo = o;
            var it = new ToggleMenuFlyoutItem { Text = OrderTitle(o), IsChecked = o == order };
            it.Click += (_, _) => { Prefs.Instance.TagSort = oo; RebuildSortMenu(); ApplyFilter(); };
            menu.Items.Add(it);
        }
        _sortBtn.Flyout = menu;
    }

    async Task Load()
    {
        _revision = _library.Revision;
        _tags = await TlCore.Run(TlCore.AllTags);
        ApplyFilter();
    }

    public override void Build()
    {
        RebuildSortMenu();
        if (_tags == null || _revision != _library.Revision) _ = Load();
        else ApplyFilter();
    }

    void ApplyFilter()
    {
        if (_tags == null)
        {
            _loading.IsActive = true;
            _loading.Visibility = Visibility.Visible;
            _empty.Visibility = Visibility.Collapsed;
            _grid.ItemsSource = null;
            _summary.Text = "";
            _deleteAiItem.IsEnabled = false;
            return;
        }
        _loading.IsActive = false;
        _loading.Visibility = Visibility.Collapsed;

        var aiTotal = _tags.Sum(t => t.Ai);
        _deleteAiItem.IsEnabled = aiTotal > 0;

        var q = _filter.Text.Trim();
        var scope = _show.SelectedIndex;
        IEnumerable<TagCount> items = _tags;
        if (q.Length > 0) items = items.Where(t => t.Label.Contains(q, StringComparison.OrdinalIgnoreCase));
        items = scope switch
        {
            1 => items.Where(t => t.User > 0),
            2 => items.Where(t => t.Ai > 0),
            3 => items.Where(t => Common(t) > 0),
            _ => items,
        };
        var visible = Sorted(items.ToList(), Prefs.Instance.TagSort);

        _summary.Text = _tags.Count == 0
            ? ""
            : L("tags.total", _tags.Count)
              + (visible.Count == _tags.Count ? "" : L("tags.shown", visible.Count))
              + L("tags.hint.mac");

        if (_tags.Count == 0)
        {
            _grid.ItemsSource = null;
            _emptyIcon.Glyph = "\uE8EC";
            _emptyTitle.Text = L("tags.none");
            _emptyMsg.Text = L("tags.none.message");
            _empty.Visibility = Visibility.Visible;
            return;
        }
        if (visible.Count == 0)
        {
            _grid.ItemsSource = null;
            _emptyIcon.Glyph = "\uE721";
            _emptyTitle.Text = L("tags.noMatch");
            _emptyMsg.Text = L("tags.noMatch.message");
            _empty.Visibility = Visibility.Visible;
            return;
        }
        _empty.Visibility = Visibility.Collapsed;
        _grid.ItemsSource = visible;
        Layout();
    }

    void Layout()
    {
        var w = Math.Max(_grid.ActualWidth - 2 * MarginX - 4, MinCard);
        var cols = Math.Max(1, (int)((w + Gap) / (MinCard + Gap)));
        var cardW = Math.Floor((w - Gap * (cols - 1)) / cols);
        var wrap = _grid.ItemsPanelRoot is { } panel ? WinRT.CastExtensions.As<ItemsWrapGrid>(panel) : null;
        if (Math.Abs(cardW - _cardW) < 0.5 && wrap is { ItemWidth: > 0 }) return;
        _cardW = cardW;
        if (wrap != null)
        {
            wrap.ItemWidth = cardW + Gap;
            wrap.ItemHeight = CardHeight + Gap;
        }
    }

    MenuFlyout TagMenu(TagCount t)
    {
        var m = new MenuFlyout();
        m.Items.Add(FolderActions.Item(L("tags.onlyInBrowse", t.Label), "\uE8A7", () => ShowInBrowse(t.Label)));
        m.Items.Add(FolderActions.Item(L("tags.allToFolder", t.Count), "\uE8F4", () => _ = ToFolder(t)));
        m.Items.Add(new MenuFlyoutSeparator());
        m.Items.Add(FolderActions.Item(L("tags.renameOrMerge"), "\uE8AC", () => _ = Rename(t)));
        var del = FolderActions.Item(L("tags.deleteEllipsis"), "\uE74D", () => _ = Delete(t));
        del.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        m.Items.Add(del);
        return m;
    }

    void ShowInBrowse(string label) => _library.ShowInBrowse(new FeedFilter { Labels = [label] });

    void OnContainer(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.ItemContainer.ContentTemplateRoot is not Border card || args.Item is not TagCount t) return;
        var root = (Grid)card.Child;
        var head = (Grid)root.Children[0];
        var labelText = (TextBlock)head.Children[0];
        var actions = (StackPanel)head.Children[1];
        var moreBtn = (Button)actions.Children[0];
        var browseBtn = (Button)actions.Children[1];
        var countRow = (StackPanel)root.Children[1];
        var countText = (TextBlock)countRow.Children[0];
        var unitText = (TextBlock)countRow.Children[1];
        var barHost = (Grid)((Border)root.Children[2]).Child;
        var statsRow = (StackPanel)root.Children[3];

        labelText.Text = t.Label;
        countText.Text = t.Count.ToString("N0");
        unitText.Text = L("tags.itemsUnit");

        var common = Common(t);
        var onlyMine = Math.Max(0, t.User - common);
        var onlyAi = Math.Max(0, t.Ai - common);

        // Proportion bar: up to 3 rounded segments (yours blue, both green, AI purple)
        barHost.ColumnDefinitions.Clear();
        barHost.Children.Clear();
        (long n, Brush brush)[] segs = [(onlyMine, MineBrush), (common, BothBrush), (onlyAi, AiBrush)];
        var col = 0;
        foreach (var (n, brush) in segs)
        {
            if (n <= 0) continue;
            barHost.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(n, GridUnitType.Star), MinWidth = 5 });
            var seg = new Border { Background = brush, CornerRadius = new CornerRadius(3.5) };
            Grid.SetColumn(seg, col++);
            barHost.Children.Add(seg);
        }

        // Bottom dot counts
        statsRow.Children.Clear();
        if (t.User > 0) statsRow.Children.Add(StatItem(L("search.kw.mine.word"), t.User, MineBrush));
        if (t.Ai > 0) statsRow.Children.Add(StatItem("AI", t.Ai, AiBrush));
        if (common > 0) statsRow.Children.Add(StatItem(L("search.kw.common.word"), common, BothBrush));

        // More button opens the tag menu on click (zero MenuFlyout allocation during scroll)
        _cardTags[moreBtn] = t;
        if (_wiredButtons.Add(moreBtn))
            moreBtn.Click += (s, _) => { if (s is Button b && _cardTags.TryGetValue(b, out var tag)) TagMenu(tag).ShowAt(b); };
        ToolTipService.SetToolTip(moreBtn, L("grid.more"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(moreBtn, L("grid.more"));

        // Top-right jump-to-Browse arrow (wired once per recycled template)
        _cardTags[browseBtn] = t;
        if (_wiredButtons.Add(browseBtn))
            browseBtn.Click += (s, _) => { if (s is Button b && _cardTags.TryGetValue(b, out var tag)) ShowInBrowse(tag.Label); };
        var browseTip = L("tags.onlyInBrowse", t.Label);
        ToolTipService.SetToolTip(browseBtn, browseTip);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(browseBtn, browseTip);

        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(card, "tag-" + t.Label);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, L("tags.cell.spoken", t.Label, t.Count, t.User, t.Ai));
    }

    static StackPanel StatItem(string name, long n, Brush brush) => new()
    {
        Orientation = Orientation.Horizontal,
        Spacing = 4,
        VerticalAlignment = VerticalAlignment.Center,
        Children =
        {
            new Ellipse { Width = 7, Height = 7, Fill = brush, VerticalAlignment = VerticalAlignment.Center },
            new TextBlock
            {
                Text = $"{name} {n}",
                FontSize = 12,
                Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                VerticalAlignment = VerticalAlignment.Center,
            },
        },
    };

    async Task Reload()
    {
        await _library.Refresh();
        await Load();
    }

    async Task Rename(TagCount t)
    {
        var to = (await Dialogs.Prompt(W, L("tags.rename.title", t.Label), L("common.name"), t.Label, $"{L("tags.rename.countMessage", t.Count)}\n{L("tags.rename.message")}", L("common.done")))?.Trim().ToLowerInvariant();
        if (string.IsNullOrEmpty(to) || to == t.Label) return;
        await TlCore.Run(() => TlCore.RenameTag(t.Label, to));
        Dialogs.Toast(W, L("tags.renamed"));
        await Reload();
    }

    async Task ToFolder(TagCount t)
    {
        var folder = (await Dialogs.Prompt(W, L("tags.toFolder.title", t.Label, t.Count), L("common.folderName"), t.Label, L("tags.toFolder.message"), L("common.addToFolder")))?.Trim();
        if (string.IsNullOrEmpty(folder)) return;
        var create = !(_library.Folders?.Folders.Any(f => f.Name == folder) ?? false);
        var n = await TlCore.Run(() => { if (create) TlCore.CreateFolder(folder); return TlCore.TagToFolder(t.Label, folder); });
        Dialogs.Toast(W, n < t.Count ? L("tags.toFolder.partly", n) : L("tags.toFolder.done", folder));
        await Reload();
    }

    async Task Delete(TagCount t)
    {
        if (!await Dialogs.Confirm(W, L("tags.delete.title", t.Label), L("tags.delete.message", t.Count), L("common.delete"), destructive: true)) return;
        await TlCore.Run(() => TlCore.DeleteTag(t.Label));
        await Reload();
    }

    async Task DeleteAi()
    {
        var ai = _tags?.Sum(t => t.Ai) ?? 0;
        if (ai <= 0) { Dialogs.Toast(W, L("tags.noAI")); return; }
        if (!await Dialogs.Confirm(W, L("tags.deleteAI.title", ai), L("tags.deleteAI.message"), L("tags.deleteAI.confirm"), destructive: true)) return;
        await TlCore.Run(TlCore.RemoveAiTags);
        await Reload();
    }
}
