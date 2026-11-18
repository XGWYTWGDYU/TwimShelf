// All folders as cover tiles, like the albums in Photos (the Mac app's MacFoldersOverview): as many
// columns as the width allows (tiles 170–240), each a square cover with the name and count beneath.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class FoldersPage : UserControl, IShellPage
{
    const double Margin_ = 20, Gap = 16, MinTile = 170, Caption = 44;
    readonly LibraryModel _library;
    readonly Action<string> _open;
    readonly GridView _grid;
    readonly TextBlock _empty;
    List<Folder> _folders = [];
    double _side = MinTile;

    public event Action? ChromeChanged;
    public string Title => L("place.folders");
    public string Subtitle => _folders.Count == 0 ? "" : L("folders.count", _folders.Count);
    // the page's button floats over its top right corner (FloatingBar), not in the title bar
    readonly Border _bar = FloatingBar.Make();

    public FoldersPage(LibraryModel library, Action<string> open)
    {
        _library = library;
        _open = open;
        _grid = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Padding = new Thickness(Margin_, FloatingBar.Space, Margin_, 24),
            ItemTemplate = (DataTemplate)Application.Current.Resources["FolderTileTemplate"],
        };
        _grid.ItemClick += (_, e) => _open(((Folder)e.ClickedItem).Name);
        _grid.ContainerContentChanging += OnContainer;
        _grid.SizeChanged += (_, _) => Layout();
        _grid.Loaded += (_, _) => Layout();
        _grid.RightTapped += (s, e) =>
        {
            if ((e.OriginalSource as FrameworkElement)?.DataContext is not Folder f) return;
            FolderActions.Menu(MainWindow.Current!, f.Name, onOpen: () => _open(f.Name)).ShowAt(_grid, e.GetPosition(_grid));
            e.Handled = true;
        };
        _empty = new TextBlock
        {
            Text = L("windows.folders.empty"),
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            MaxWidth = 420,
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        Content = new Grid { Children = { _grid, _empty, _bar } };
        var add = new AppBarButton { Icon = new FontIcon { Glyph = "" }, Label = L("common.newFolder") };
        add.Click += async (_, _) => { if (await FolderActions.Create(MainWindow.Current!) is { } n) _open(n); };
        var k = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = Windows.System.VirtualKey.N, Modifiers = Windows.System.VirtualKeyModifiers.Control | Windows.System.VirtualKeyModifiers.Shift };
        add.KeyboardAccelerators.Add(k);
        _bar.Child = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), PrimaryCommands = { add } };
        _library.Changed += Reload;
        Unloaded += (_, _) =>
        {
            _library.Changed -= Reload;
            _alive.Cancel();
            foreach (var c in _loads.Values) c.Dispose();
            _loads.Clear();
        };
        Reload();
    }

    void Reload()
    {
        _folders = _library.Folders?.Folders ?? [];
        _grid.ItemsSource = _folders;
        _empty.Visibility = _folders.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        ChromeChanged?.Invoke();
    }

    void Layout()
    {
        // tiles as wide as the columns that fit, so rows always fill the width
        var w = Math.Max(_grid.ActualWidth - 2 * Margin_ - 4, MinTile);
        var cols = Math.Max(1, (int)((w + Gap) / (MinTile + Gap)));
        var side = Math.Floor((w - Gap * (cols - 1)) / cols);
        // the panel through a cast that asks the object (As): a plain cast fails in the AOT build
        var wrap = _grid.ItemsPanelRoot is { } panel ? WinRT.CastExtensions.As<ItemsWrapGrid>(panel) : null;
        if (Math.Abs(side - _side) < 0.5 && wrap is { ItemWidth: > 0 }) return;
        _side = side;
        if (wrap != null)
        {
            wrap.ItemWidth = side + Gap;
            wrap.ItemHeight = side + Caption + Gap;
        }
        foreach (var f in _folders)
            if (CoverOf(_grid.ContainerFromItem(f)) is { } cover) cover.Width = cover.Height = _side;
    }

    static Grid? CoverOf(DependencyObject? container)
    {
        if (container == null) return null;
        try { return (WinRT.CastExtensions.As<Microsoft.UI.Xaml.Controls.Primitives.SelectorItem>(container).ContentTemplateRoot as StackPanel)?.Children[0] as Grid; }
        catch { return null; }
    }

    void OnContainer(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not StackPanel panel || args.Item is not Folder f) return;
        var cover = (Grid)panel.Children[0];
        cover.Width = cover.Height = _side;
        var image = (Image)cover.Children[0];
        var glyph = (FontIcon)cover.Children[1];
        ((TextBlock)panel.Children[1]).Text = f.Name;
        ((TextBlock)panel.Children[2]).Text = L("search.row.mediaCount", f.Count) + (f.Videos > 0 ? L("folders.videosSuffix", f.Videos) : "");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, f.Name);
        image.Source = null;
        if (_loads.Remove(image, out var old)) old.Cancel();
        glyph.Visibility = f.CoverPath == null ? Visibility.Visible : Visibility.Collapsed;
        if (args.InRecycleQueue || f.CoverPath == null || f.CoverId == null) return;
        var pixels = (int)(_side * (XamlRoot?.RasterizationScale ?? 1));
        var path = f.CoverPath;
        _ = Load(image, f.CoverId, path, f.CoverVideo, pixels, Cancel(image));
    }

    // Covers still loading when the page goes (or a tile shows another folder) are cancelled:
    // nothing is made for, or set on, a tile that left. Left loading, they went on in the page that
    // was gone, and 浏览 crashed (E_UNEXPECTED inside WinUI) soon after.
    readonly Dictionary<Image, CancellationTokenSource> _loads = [];
    readonly CancellationTokenSource _alive = new();

    CancellationToken Cancel(Image image)
    {
        var c = CancellationTokenSource.CreateLinkedTokenSource(_alive.Token);
        _loads[image] = c;
        return c.Token;
    }

    async Task Load(Image image, string id, string path, bool video, int pixels, CancellationToken cancel)
    {
        try
        {
            var src = await Thumbnails.Tile(id, path, video, pixels, cancel);
            if (src != null && !cancel.IsCancellationRequested) image.Source = src;
        }
        catch { }
    }
}
