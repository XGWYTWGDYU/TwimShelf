// A collection beside the sidebar (a folder, 图片, 视频, 散装媒体, the recycle bin …), as the Mac app's
// MacMediaGridPage: the grid and nothing else. The title, the zoom, 选择 and the selection's actions
// are in the title bar. A plain grid of square tiles (Windows Photos has no pinch zoom either): the
// zoom steps the tile size, from the buttons, Ctrl+wheel or Ctrl+plus/minus.
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Search;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

/// One tile of a grid: a post's media (grouped) or one media.
public sealed class GridEntry(List<FeedItem> items)
{
    public List<FeedItem> Items { get; } = items;
    public FeedItem First => Items[0];
}

public sealed partial class GridPage : UserControl, IShellPage
{
    static readonly double[] Sides = [72, 100, 140, 190, 260, 360];
    readonly LibraryModel _library;
    readonly Place _place;
    readonly GridView _grid;
    readonly TextBlock _empty;
    List<FeedItem> _items = [];
    List<GridEntry> _entries = [];
    Dictionary<string, long> _trashedAt = [];
    int _level;
    int _revision = -1, _generation;
    string _counts = "";
    bool Bin => _place == Place.Trash;
    bool Grouped => Prefs.Instance.FeedGrouped;

    public event Action? ChromeChanged;
    public string Title => _place.Title;
    public string Subtitle => !Selecting ? _counts : SelectedEntries.Count == 0 ? L("grid.selectItems") : L("grid.selected", SelectedMedia.Count);
    // the page's buttons float over its top right corner (FloatingBar), not in the title bar
    readonly Border _bar = FloatingBar.Make();

    public GridPage(LibraryModel library, Place place)
    {
        _library = library;
        _place = place;
        _level = Array.IndexOf(Sides, Prefs.Instance.GridTile) is var i and >= 0 ? i : 2;
        _grid = new GridView
        {
            SelectionMode = ListViewSelectionMode.None,
            IsItemClickEnabled = true,
            Padding = new Thickness(16, FloatingBar.Space, 16, 24),
            ItemTemplate = (DataTemplate)Application.Current.Resources["GridTileTemplate"],
            CanDragItems = false,
        };
        // the width decides the columns (ApplySize); the panel exists once the grid has loaded
        _grid.SizeChanged += (_, _) => ApplySize();
        _grid.Loaded += (_, _) => ApplySize();
        _grid.ItemClick += (_, e) => Open((GridEntry)e.ClickedItem);
        _grid.SelectionChanged += (_, _) => { BuildCommands(); ChromeChanged?.Invoke(); };
        _grid.ContainerContentChanging += OnContainer;
        _grid.RightTapped += OnRightTapped;
        _grid.PointerWheelChanged += OnWheel;
        // (no shortcut tips: WinUI would float "Ctrl+-" over the grid on hover)
        _grid.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        _grid.KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.Add, () => Zoom(1)));
        _grid.KeyboardAccelerators.Add(Accelerator((Windows.System.VirtualKey)187, () => Zoom(1)));
        _grid.KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.Subtract, () => Zoom(-1)));
        _grid.KeyboardAccelerators.Add(Accelerator((Windows.System.VirtualKey)189, () => Zoom(-1)));
        _empty = new TextBlock
        {
            Text = Bin ? L("grid.trashEmpty") : L("grid.empty"),
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        Content = new Grid { Children = { _grid, _freeze, _empty, _bar } };
        ApplySize();
        BuildCommands();
        _library.Changed += OnLibraryChanged;
        Unloaded += (_, _) => _library.Changed -= OnLibraryChanged;
        _ = Reload();
        // media past the retention period leave the bin
        if (Bin) _ = Task.Run(() => { try { if (TlCore.ExpireTrash() > 0) DispatcherQueue.TryEnqueue(() => _ = _library.Refresh()); } catch { } });
    }

    static KeyboardAccelerator Accelerator(Windows.System.VirtualKey key, Action a)
    {
        var k = new KeyboardAccelerator { Key = key, Modifiers = Windows.System.VirtualKeyModifiers.Control };
        k.Invoked += (_, e) => { e.Handled = true; a(); };
        return k;
    }

    void OnLibraryChanged()
    {
        if (_library.Revision != _revision) _ = Reload();
    }

    async Task Reload()
    {
        _revision = _library.Revision;
        var gen = ++_generation;
        List<FeedItem> items;
        Dictionary<string, long> dates = [];
        try
        {
            if (Bin)
            {
                var t = await TlCore.Run(TlCore.TrashList);
                foreach (var i in t) dates[i.MediaId] = i.TrashedAtMs;
                items = [.. t.Select(x => new FeedItem { MediaId = x.MediaId, PostId = x.PostId, Ordinal = x.Ordinal, Kind = x.Kind, Path = x.Path, Text = x.Text, AuthorName = x.AuthorName, ScreenName = x.ScreenName, Url = x.Url, Tags = x.Tags })];
            }
            else items = await _library.Feed(new FeedRequest { Filter = _place.Filter! });
        }
        catch (Exception e) { Diagnostics.Log("grid: " + e); items = []; }
        if (gen != _generation) return;
        _items = items;
        _trashedAt = dates;
        Rebuild();
    }

    void Rebuild()
    {
        _entries = Grouped ? [.. FeedOrder.PostsInPlace(_items).Select(p => new GridEntry(p))] : [.. _items.Select(i => new GridEntry([i]))];
        _grid.ItemsSource = _entries;
        _empty.Visibility = _entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var videos = _items.Count(i => i.IsVideo);
        var photos = _items.Count - videos;
        var parts = new List<string>();
        if (photos > 0) parts.Add(L("grid.photos", photos));
        if (videos > 0) parts.Add(L("grid.videos", videos));
        _counts = string.Join(L("list.separator"), parts);
        BuildCommands();
        ChromeChanged?.Invoke();
    }

    // ---- tiles ------------------------------------------------------------------------------

    /// The zoom level's size: the most a tile is. Tiles fill the width exactly, so they are a
    /// little smaller (`_tile`), as many columns as fit at this size.
    double Side => Sides[_level];
    double _tile = Sides[2];

    /// Columns that fill the width: as many as fit at the zoom level's size, then each one
    /// stretched so no gap is left at the right. The panel is reached with a cast that asks the
    /// object itself (As): a plain cast fails in the AOT build (the panel comes back as its base).
    void ApplySize()
    {
        var width = _grid.ActualWidth - _grid.Padding.Left - _grid.Padding.Right - 2;
        if (width <= 0) return;
        var columns = Math.Max(1, (int)Math.Floor(width / (Side + 4)));
        var cell = Math.Floor(width / columns);
        _tile = cell - 4;
        if (_grid.ItemsPanelRoot is { } panel && WinRT.CastExtensions.As<ItemsWrapGrid>(panel) is { } wrap)
        {
            wrap.ItemWidth = cell;
            wrap.ItemHeight = cell;
        }
        foreach (var e in _entries)
            if (TileOf(_grid.ContainerFromItem(e)) is { } g) g.Width = g.Height = _tile;
    }

    /// A container's tile. The container is reached with a cast that asks the object (As): in the
    /// AOT build it can come back as its base type, a plain `is GridViewItem` is false, and zooming
    /// then left every tile at its old size.
    static Grid? TileOf(DependencyObject? container)
    {
        if (container == null) return null;
        try { return WinRT.CastExtensions.As<Microsoft.UI.Xaml.Controls.Primitives.SelectorItem>(container).ContentTemplateRoot as Grid; }
        catch { return null; }
    }

    void OnContainer(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not Grid tile || args.Item is not GridEntry e) return;
        tile.Width = tile.Height = _tile;
        args.ItemContainer.Margin = new Thickness(2);
        var image = (Image)tile.Children[0];
        var video = (Border)tile.Children[1];
        var count = (Border)tile.Children[2];
        if (args.InRecycleQueue)
        {
            (tile.Tag as CancellationTokenSource)?.Cancel();
            image.Source = null;
            return;
        }
        video.Visibility = e.First.IsVideo ? Visibility.Visible : Visibility.Collapsed;
        count.Visibility = e.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        ((TextBlock)count.Child).Text = e.Items.Count.ToString();
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, e.First.Text ?? e.First.AuthorName ?? e.First.MediaId);
        image.Source = null;
        Fill(tile, e);
    }

    /// The tile's picture at its current size (again after a zoom: a bigger one needs more pixels).
    void Fill(Grid tile, GridEntry e)
    {
        var image = (Image)tile.Children[0];
        (tile.Tag as CancellationTokenSource)?.Cancel();
        var cancel = new CancellationTokenSource();
        tile.Tag = cancel;
        var scale = XamlRoot?.RasterizationScale ?? 1;
        _ = Load(image, e.First, (int)(_tile * scale), cancel.Token);
    }

    int _loads; // pictures on their way (a zoom's cover waits for them)

    async Task Load(Image image, FeedItem item, int pixels, CancellationToken cancel)
    {
        _loads++;
        try
        {
            var src = await Thumbnails.Tile(item.MediaId, item.Path, item.IsVideo, pixels, cancel);
            if (!cancel.IsCancellationRequested && src != null) image.Source = src;
        }
        catch { }
        finally { _loads--; }
    }

    // A zoom changes every tile's size, and the grid then makes all its tiles anew: for a frame or
    // two every tile is empty (white) until its picture is back. What was shown is pictured first
    // and laid over the grid, and fades once the new tiles have their pictures.
    readonly Image _freeze = new() { Stretch = Stretch.Fill, IsHitTestVisible = false, Visibility = Visibility.Collapsed, HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
    int _freezeGeneration;
    bool _freezing;

    async void Zoom(int by)
    {
        var l = Math.Clamp(_level + by, 0, Sides.Length - 1);
        if (l == _level || _freezing) return;
        var gen = ++_freezeGeneration;
        // (zooming again while the picture is still up, as with the wheel: it stays, it is not taken again)
        if (_freeze.Visibility != Visibility.Visible || _freeze.Opacity < 1)
        {
            _freezing = true;
            try
            {
                var shot = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
                // at half size: it is up for a fifth of a second, and pictured faster so
                await shot.RenderAsync(_grid, (int)(_grid.ActualWidth / 2), (int)(_grid.ActualHeight / 2));
                _freeze.Source = shot;
                _freeze.Width = _grid.ActualWidth;
                _freeze.Height = _grid.ActualHeight;
                _freeze.Opacity = 1;
                _freeze.Visibility = Visibility.Visible;
            }
            catch { }
            finally { _freezing = false; }
            if (gen != _freezeGeneration) return;
        }
        ZoomTo(l);
        // until the tiles in view have their pictures (half a second at most), then a short fade
        for (var waited = 0; waited < 700 && !TilesFilled(); waited += 16) await Task.Delay(16);
        // the grid draws its new tiles over the next frames: a few of them go by before the fade
        await Frames(6);
        for (var waited = 0; waited < 300 && !TilesFilled(); waited += 16) await Task.Delay(16);
        if (gen != _freezeGeneration) return;
        for (var o = 0.75; o > 0; o -= 0.25) { _freeze.Opacity = o; await Task.Delay(16); if (gen != _freezeGeneration) return; }
        _freeze.Visibility = Visibility.Collapsed;
        _freeze.Source = null;
    }

    /// After a zoom: a tile whose picture has fewer pixels than it now shows (smaller ones keep
    /// theirs, scaled down: replacing a picture blanks the tile until the new one is decoded).
    bool NeedsMore(Grid tile)
    {
        if (tile.Children[0] is not Image { Source: Microsoft.UI.Xaml.Media.Imaging.BitmapImage b }) return true;
        var want = _tile * (XamlRoot?.RasterizationScale ?? 1);
        return b.DecodePixelWidth > 0 && b.DecodePixelWidth < want * 0.9;
    }

    static Task Frames(int n)
    {
        var done = new TaskCompletionSource();
        var left = n;
        void Tick(object? s, object e) { if (--left > 0) return; Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= Tick; done.TrySetResult(); }
        Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += Tick;
        return done.Task;
    }

    /// The tiles on screen all show a decoded picture (asked of the tiles there, not by index: the
    /// grid's visible range is only updated a layout or two after a zoom).
    bool TilesFilled() => EmptyTiles() == 0 && _loads == 0;

    int EmptyTiles()
    {
        if (_grid.ItemsPanelRoot is not { } panel) return 0;
        var view = new Windows.Foundation.Rect(0, 0, _grid.ActualWidth, _grid.ActualHeight);
        var empty = 0;
        foreach (var child in panel.Children)
        {
            if (TileOf(child) is not { } g || g.Children[0] is not Image im) continue;
            Windows.Foundation.Rect r;
            try { r = g.TransformToVisual(_grid).TransformBounds(new Windows.Foundation.Rect(0, 0, g.ActualWidth, g.ActualHeight)); } catch { continue; }
            r.Intersect(view);
            if (r.IsEmpty || r.Width < 1 || r.Height < 1) continue;
            if (im.Source == null || im.Source is Microsoft.UI.Xaml.Media.Imaging.BitmapImage { PixelWidth: 0 }) empty++;
        }
        return empty;
    }

    void ZoomTo(int l)
    {
        _level = l;
        Prefs.Instance.GridTile = Side;
        // the same items stay in view: the first one shown before is the first one shown after
        var wrap = _grid.ItemsPanelRoot is { } panel ? WinRT.CastExtensions.As<ItemsWrapGrid>(panel) : null;
        var first = wrap?.FirstVisibleIndex ?? -1;
        ApplySize();
        _grid.UpdateLayout();
        if (first >= 0 && first < _entries.Count) _grid.ScrollIntoView(_entries[first], ScrollIntoViewAlignment.Leading);
        _grid.UpdateLayout();
        if (wrap != null)
            for (var i = Math.Max(0, wrap.FirstCacheIndex); i <= wrap.LastCacheIndex && i < _entries.Count; i++)
                if (TileOf(_grid.ContainerFromIndex(i)) is { } g && NeedsMore(g)) Fill(g, _entries[i]);
        BuildCommands();
    }

    void OnWheel(object sender, PointerRoutedEventArgs e)
    {
        if (!e.KeyModifiers.HasFlag(Windows.System.VirtualKeyModifiers.Control)) return;
        var d = e.GetCurrentPoint(_grid).Properties.MouseWheelDelta;
        Zoom(d > 0 ? 1 : -1);
        e.Handled = true;
    }

    // ---- open, menus ----------------------------------------------------------------------------

    void Open(GridEntry e)
    {
        if (Selecting) return;
        // ← → goes through every media of the grid, starting here
        var all = Grouped ? _entries.SelectMany(x => x.Items).ToList() : _items;
        Viewer.Open(all, Math.Max(0, all.FindIndex(i => i.MediaId == e.First.MediaId)), _place);
    }

    void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        var item = (e.OriginalSource as FrameworkElement)?.DataContext as GridEntry;
        if (item == null) return;
        var m = Selecting ? SelectionMenu(item) : EntryMenu(item);
        m.ShowAt(_grid, e.GetPosition(_grid));
        e.Handled = true;
    }

    MenuFlyout SelectionMenu(GridEntry e)
    {
        var m = new MenuFlyout();
        var on = _grid.SelectedItems.Contains(e);
        m.Items.Add(FolderActions.Item(on ? L("common.deselect") : L("common.select"), null, () =>
        {
            if (on) _grid.SelectedItems.Remove(e); else _grid.SelectedItems.Add(e);
        }));
        return m;
    }

    MenuFlyout EntryMenu(GridEntry e)
    {
        var I = FolderActions.Item;
        var ids = e.Items.Select(i => i.MediaId).ToList();
        var m = new MenuFlyout();
        if (Bin && DaysLeft(e) is { } left)
        {
            m.Items.Add(new MenuFlyoutItem { Text = left, IsEnabled = false });
            m.Items.Add(new MenuFlyoutSeparator());
        }
        m.Items.Add(I(L("common.select"), "", () => { SetSelecting(true); _grid.SelectedItems.Add(e); }));
        if (Bin)
        {
            var n = ids.Count > 1 ? L("grid.countSuffix", ids.Count) : "";
            m.Items.Add(I(L("common.restore") + n, "", () => _ = Restore(ids)));
            m.Items.Add(new MenuFlyoutSeparator());
            m.Items.Add(I(L("common.deletePermanently") + n + "…", "", () => _ = MediaActions.Purge(ids)));
            return m;
        }
        // the shared media menu, then this grid's own
        var shared = MediaActions.Menu(e.First, _place);
        m.Items.Add(new MenuFlyoutSeparator());
        while (shared.Items.Count > 0) { var it = shared.Items[0]; shared.Items.RemoveAt(0); m.Items.Add(it); }
        return m;
    }

    string? DaysLeft(GridEntry e)
    {
        var keep = TlCore.TrashKeepDays();
        var times = e.Items.Select(i => _trashedAt.GetValueOrDefault(i.MediaId)).Where(t => t > 0).ToList();
        if (times.Count == 0) return null;
        if (keep == 0) return L("trash.keepForever");
        var d = keep - (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - times.Min()) / 86_400_000.0;
        return d < 1 ? L("trash.deletingSoon") : L("trash.daysLeft", (int)Math.Ceiling(d));
    }

    async Task Restore(List<string>? ids)
    {
        var snapshot = await TlCore.Run(() => TlCore.BinSnapshot(ids));
        SetSelecting(false);
        await MediaActions.Run(ActionKind.Restore, snapshot: snapshot, done: n => L("trash.restored", n));
    }

    // ---- selection ----------------------------------------------------------------------------

    bool Selecting => _grid.SelectionMode == ListViewSelectionMode.Multiple;
    List<GridEntry> SelectedEntries => [.. _grid.SelectedItems.OfType<GridEntry>()];
    List<FeedItem> SelectedMedia => [.. SelectedEntries.SelectMany(e => e.Items)];

    void SetSelecting(bool on)
    {
        if (Selecting == on) return;
        _grid.SelectionMode = on ? ListViewSelectionMode.Multiple : ListViewSelectionMode.None;
        _grid.IsItemClickEnabled = !on;
        BuildCommands();
        ChromeChanged?.Invoke();
    }

    // ---- title bar --------------------------------------------------------------------------------

    void BuildCommands()
    {
        var bar = new CommandBar { DefaultLabelPosition = CommandBarDefaultLabelPosition.Right, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), IsDynamicOverflowEnabled = false, OverflowButtonVisibility = CommandBarOverflowButtonVisibility.Collapsed, VerticalAlignment = VerticalAlignment.Center };
        AppBarButton B(string glyph, string label, Action a, bool enabled = true, bool iconOnly = false)
        {
            var b = new AppBarButton { Icon = new FontIcon { Glyph = glyph }, Label = label, IsEnabled = enabled };
            if (iconOnly) b.LabelPosition = CommandBarLabelPosition.Collapsed;
            ToolTipService.SetToolTip(b, label);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, label);
            b.Click += (_, _) => a();
            return b;
        }
        if (Selecting)
        {
            var any = SelectedEntries.Count > 0;
            var all = _entries.Count > 0 && SelectedEntries.Count == _entries.Count;
            bar.PrimaryCommands.Add(B("", all ? L("grid.deselectAll") : L("grid.selectAll"), () => { if (all) _grid.DeselectRange(new Microsoft.UI.Xaml.Data.ItemIndexRange(0, (uint)_entries.Count)); else _grid.SelectAll(); }));
            if (Bin)
            {
                bar.PrimaryCommands.Add(B("", L("common.restore"), () => _ = Restore([.. SelectedMedia.Select(i => i.MediaId)]), any));
                bar.PrimaryCommands.Add(B("", L("common.deletePermanently"), async () => { await MediaActions.Purge([.. SelectedMedia.Select(i => i.MediaId)]); SetSelecting(false); }, any));
            }
            else
            {
                bar.PrimaryCommands.Add(B("", L("common.addToFolder"), async () => { await MediaActions.AddToFolder(SelectedMedia); SetSelecting(false); }, any));
                if (_place.Folder is { } folder)
                    bar.PrimaryCommands.Add(B("", L("common.removeFromFolder"), async () =>
                    {
                        var ids = SelectedMedia.Select(i => i.MediaId).ToList();
                        SetSelecting(false);
                        await MediaActions.Run(ActionKind.FolderRemove, ids, folder: folder, done: n => L("folder.removed", n, folder));
                    }, any));
                bar.PrimaryCommands.Add(B("", L("grid.moveToTrash"), async () =>
                {
                    var ids = SelectedMedia.Select(i => i.MediaId).ToList();
                    if (!await Dialogs.Confirm(MainWindow.Current!, L("grid.trashConfirm.title"), L("grid.trashConfirm", ids.Count), L("grid.moveToTrash"), destructive: true)) return;
                    SetSelecting(false);
                    await MediaActions.Run(ActionKind.Trash, ids, done: n => L("trash.moved", n));
                }, any));
            }
            var done = new AppBarButton { Label = L("common.done"), Icon = new FontIcon { Glyph = "" } };
            done.Click += (_, _) => SetSelecting(false);
            bar.PrimaryCommands.Add(new AppBarSeparator());
            bar.PrimaryCommands.Add(done);
        }
        else
        {
            bar.PrimaryCommands.Add(B("", L("grid.zoomOut"), () => Zoom(-1), _level > 0, iconOnly: true));
            bar.PrimaryCommands.Add(B("", L("grid.zoomIn"), () => Zoom(1), _level < Sides.Length - 1, iconOnly: true));
            bar.PrimaryCommands.Add(B("", L("common.select"), () => SetSelecting(true), _entries.Count > 0));
            if (!Bin && _place.Filter != null)
                bar.PrimaryCommands.Add(B("", L("grid.revealMedia"), () => _library.ShowInBrowse(_place.Filter!)));
            // the menu only has a folder's or the bin's own actions
            if (!Bin && _place.Folder == null) { _bar.Child = bar; return; }
            var more = new AppBarButton { Icon = new FontIcon { Glyph = "" }, Label = L("grid.more"), LabelPosition = CommandBarLabelPosition.Collapsed, Flyout = MoreMenu() };
            ToolTipService.SetToolTip(more, L("grid.more"));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, L("grid.more"));
            bar.PrimaryCommands.Add(more);
        }
        _bar.Child = bar;
    }

    MenuFlyout MoreMenu()
    {
        var I = FolderActions.Item;
        var m = new MenuFlyout();
        if (Bin)
        {
            var keep = TlCore.TrashKeepDays();
            var retention = new MenuFlyoutSubItem { Text = L("trash.autoDeleteMac", KeepTitle(keep)) };
            foreach (var days in new long[] { 7, 30, 90, 365, 0 })
            {
                var it = new ToggleMenuFlyoutItem { Text = days == 0 ? L("trash.neverShort") : KeepTitle(days), IsChecked = days == keep };
                it.Click += async (_, _) =>
                {
                    await TlCore.Run(() => { TlCore.SetTrashKeepDays((uint)days); TlCore.ExpireTrash(); });
                    BuildCommands();
                    ChromeChanged?.Invoke();
                    _ = _library.Refresh();
                };
                retention.Items.Add(it);
            }
            m.Items.Add(retention);
            m.Items.Add(new MenuFlyoutSeparator());
            m.Items.Add(I(L("trash.restoreAll"), "", () => _ = Restore(null)));
            m.Items.Add(I(L("trash.emptyEllipsis"), "", () => _ = MediaActions.Purge(null)));
            return m;
        }
        if (_place.Folder is { } folder)
        {
            m.Items.Add(I(L("folder.exportZip"), "", () => _ = ExportZip(folder)));
            m.Items.Add(I(L("folder.renameEllipsis"), "", async () => { if (await FolderActions.Rename(MainWindow.Current!, folder) is { } n) MainWindow.Current!.Go(Place.OfFolder(n)); }));
            m.Items.Add(I(L("folder.deleteEllipsis"), "", () => _ = FolderActions.Delete(MainWindow.Current!, folder)));
        }
        return m;
    }

    static string KeepTitle(long days) => days switch { 0 => L("trash.neverShort"), 7 or 30 or 90 or 365 => L("trash.keep." + days), _ => L("trash.keep.days", days) };

    async Task ExportZip(string name)
    {
        var w = MainWindow.Current!;
        var path = await Pickers.SaveFile(w, string.Concat(name.Split(Path.GetInvalidFileNameChars())) + ".zip", ("ZIP", ".zip"));
        if (path == null) return;
        try
        {
            var r = await Dialogs.Progress(w, L("export.running", _items.Count), () => TlCore.ExportMedia(TlCore.MediaIds(name), path, new ExportOptions { Tags = false, Folders = false, MediaOnly = true }),
                () => TlCore.ExportStatus() is { Total: > 0 } p ? L("settings.backup.progress", p.Done, p.Total, Format.Bytes(p.Bytes)) : null, () => TlCore.CancelExport());
            var more = Format.Skipped(r);
            await Dialogs.Alert(w, more.Length == 0 ? L("export.done") : L("export.doneIncomplete"), L("export.summaryMedia", r.Media, Format.Bytes(r.Bytes)) + (more.Length == 0 ? "" : "\n\n" + more));
        }
        catch (Exception e) { await Dialogs.Alert(w, L("common.notDone"), e.Message); }
    }

    public void Hidden() => _library.Changed -= OnLibraryChanged;
}
