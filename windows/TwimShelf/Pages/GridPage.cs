// A collection beside the sidebar (a folder, 图片, 视频, 散装媒体, the recycle bin …), as the Mac
// app's MacMediaGridPage: the GPU-accelerated zoomable grid (`ZoomGridView`) and the page's floating
// action bar. Zoom smoothly with the buttons, Ctrl+wheel / touchpad pinch, touchscreen pinch, or
// Ctrl+plus/minus.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using TwimShelf.Controls.ZoomGrid;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Search;
using TwimShelf.Services;
using Windows.Foundation;
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
    readonly LibraryModel _library;
    readonly Place _place;
    readonly ZoomGridView _grid;
    readonly TextBlock _empty;
    List<FeedItem> _items = [];
    List<GridEntry> _entries = [];
    Dictionary<string, long> _trashedAt = [];
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
        _grid = new ZoomGridView(FloatingBar.Space)
        {
            InitialLevel = Prefs.Instance.GridLevel,
            KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden,
        };
        _grid.TileOpened += OnTileOpened;
        _grid.TileContextRequested += OnTileContextRequested;
        _grid.SelectionChanged += () => { BuildCommands(); ChromeChanged?.Invoke(); };
        _grid.SettledAtLevel += level =>
        {
            Prefs.Instance.GridLevel = level;
            BuildCommands();
        };
        _grid.ZoomStateChanged += BuildCommands;
        // (no shortcut tips: WinUI would float "Ctrl+-" over the grid on hover)
        KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.Add, () => _grid.Step(-1)));
        KeyboardAccelerators.Add(Accelerator((Windows.System.VirtualKey)187, () => _grid.Step(-1)));
        KeyboardAccelerators.Add(Accelerator(Windows.System.VirtualKey.Subtract, () => _grid.Step(1)));
        KeyboardAccelerators.Add(Accelerator((Windows.System.VirtualKey)189, () => _grid.Step(1)));

        _empty = new TextBlock
        {
            Text = Bin ? L("grid.trashEmpty") : L("grid.empty"),
            Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"],
            Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Visibility = Visibility.Collapsed,
        };
        Content = new Microsoft.UI.Xaml.Controls.Grid { Children = { _grid, _empty, _bar } };
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
        _empty.Visibility = _entries.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var videos = _items.Count(i => i.IsVideo);
        var photos = _items.Count - videos;
        var parts = new List<string>();
        if (photos > 0) parts.Add(L("grid.photos", photos));
        if (videos > 0) parts.Add(L("grid.videos", videos));
        _counts = string.Join(L("list.separator"), parts);
        _grid.SetTiles([.. _entries.Select(e => new ZoomGridTile(e.First, e.Items.Count))], _counts);
        BuildCommands();
        ChromeChanged?.Invoke();
    }

    // ---- open, menus ----------------------------------------------------------------------------

    void OnTileOpened(int index)
    {
        if (Selecting || index < 0 || index >= _entries.Count) return;
        var e = _entries[index];
        // ← → goes through every media of the grid, starting here
        var all = Grouped ? _entries.SelectMany(x => x.Items).ToList() : _items;
        var root = MainWindow.Current?.Content as UIElement;

        string? CoverIdFor(string mediaId) =>
            _entries.FirstOrDefault(entry => entry.Items.Any(m => m.MediaId == mediaId))?.First.MediaId;

        var initialRect = root != null ? _grid.ViewerSourceFrame(e.First.MediaId, root) : null;
        Viewer.Open(all, Math.Max(0, all.FindIndex(i => i.MediaId == e.First.MediaId)), new ViewerOpenOptions
        {
            Place = _place,
            CropSource = true,
            SourceCornerRadius = GridConfig.CornerRadius,
            SourceRect = item =>
            {
                if (root == null) return null;
                var coverId = CoverIdFor(item.MediaId);
                if (coverId != null && _grid.ViewerSourceFrame(coverId, root) is { } r) return r;
                return item.MediaId == e.First.MediaId ? initialRect : null;
            },
            ActiveMediaChanged = id => _grid.SetHiddenMedia(id == null ? null : CoverIdFor(id)),
            SquarePreviewPath = item => Thumbnails.PeekCachedTilePath(item),
        });
    }

    void OnTileContextRequested(int index, Point point)
    {
        if (index < 0 || index >= _entries.Count) return;
        var item = _entries[index];
        var m = Selecting ? SelectionMenu(item) : EntryMenu(item);
        m.ShowAt(_grid, point);
    }

    MenuFlyout SelectionMenu(GridEntry e)
    {
        var m = new MenuFlyout();
        var id = e.First.MediaId;
        var on = _grid.Selected.Contains(id);
        m.Items.Add(FolderActions.Item(on ? L("common.deselect") : L("common.select"), null, () => _grid.SetSelected(id, !on)));
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
        m.Items.Add(I(L("common.select"), "\uE762", () => { SetSelecting(true); _grid.SetSelected(e.First.MediaId, true); }));
        if (Bin)
        {
            var n = ids.Count > 1 ? L("grid.countSuffix", ids.Count) : "";
            m.Items.Add(I(L("common.restore") + n, "\uE7A7", () => _ = Restore(ids)));
            m.Items.Add(new MenuFlyoutSeparator());
            m.Items.Add(I(L("common.deletePermanently") + n + "…", "\uE74D", () => _ = MediaActions.Purge(ids)));
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

    bool Selecting => _grid.Selecting;
    List<GridEntry> SelectedEntries => [.. _entries.Where(e => _grid.Selected.Contains(e.First.MediaId))];
    List<FeedItem> SelectedMedia => [.. SelectedEntries.SelectMany(e => e.Items)];

    void SetSelecting(bool on)
    {
        if (Selecting == on) return;
        _grid.Selecting = on;
        BuildCommands();
        ChromeChanged?.Invoke();
    }

    // ---- floating action bar ------------------------------------------------------------------

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
            bar.PrimaryCommands.Add(B("\uE8B3", all ? L("grid.deselectAll") : L("grid.selectAll"), () => _grid.SelectAll(!all)));
            if (Bin)
            {
                bar.PrimaryCommands.Add(B("\uE7A7", L("common.restore"), () => _ = Restore([.. SelectedMedia.Select(i => i.MediaId)]), any));
                bar.PrimaryCommands.Add(B("\uE74D", L("common.deletePermanently"), async () => { await MediaActions.Purge([.. SelectedMedia.Select(i => i.MediaId)]); SetSelecting(false); }, any));
            }
            else
            {
                bar.PrimaryCommands.Add(B("\uE8F4", L("common.addToFolder"), async () => { await MediaActions.AddToFolder(SelectedMedia); SetSelecting(false); }, any));
                if (_place.Folder is { } folder)
                    bar.PrimaryCommands.Add(B("\uE8F6", L("common.removeFromFolder"), async () =>
                    {
                        var ids = SelectedMedia.Select(i => i.MediaId).ToList();
                        SetSelecting(false);
                        await MediaActions.Run(ActionKind.FolderRemove, ids, folder: folder, done: n => L("folder.removed", n, folder));
                    }, any));
                bar.PrimaryCommands.Add(B("\uE74D", L("grid.moveToTrash"), async () =>
                {
                    var ids = SelectedMedia.Select(i => i.MediaId).ToList();
                    if (!await Dialogs.Confirm(MainWindow.Current!, L("grid.trashConfirm.title"), L("grid.trashConfirm", ids.Count), L("grid.moveToTrash"), destructive: true)) return;
                    SetSelecting(false);
                    await MediaActions.Run(ActionKind.Trash, ids, done: n => L("trash.moved", n));
                }, any));
            }
            var done = new AppBarButton { Label = L("common.done"), Icon = new FontIcon { Glyph = "\uE73E" } };
            done.Click += (_, _) => SetSelecting(false);
            bar.PrimaryCommands.Add(new AppBarSeparator());
            bar.PrimaryCommands.Add(done);
        }
        else
        {
            bar.PrimaryCommands.Add(B("\uE71F", L("grid.zoomOut"), () => _grid.Step(1), _grid.CanZoomOut, iconOnly: true));
            bar.PrimaryCommands.Add(B("\uE8A3", L("grid.zoomIn"), () => _grid.Step(-1), _grid.CanZoomIn, iconOnly: true));
            bar.PrimaryCommands.Add(B("\uE762", L("common.select"), () => SetSelecting(true), _entries.Count > 0));
            if (!Bin && _place.Filter != null)
                bar.PrimaryCommands.Add(B("\uE8A1", L("grid.revealMedia"), () => _library.ShowInBrowse(_place.Filter!)));
            // the menu only has a folder's or the bin's own actions
            if (!Bin && _place.Folder == null) { _bar.Child = bar; return; }
            var more = new AppBarButton { Icon = new FontIcon { Glyph = "\uE712" }, Label = L("grid.more"), LabelPosition = CommandBarLabelPosition.Collapsed, Flyout = MoreMenu() };
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
            m.Items.Add(I(L("trash.restoreAll"), "\uE7A7", () => _ = Restore(null)));
            m.Items.Add(I(L("trash.emptyEllipsis"), "\uE74D", () => _ = MediaActions.Purge(null)));
            return m;
        }
        if (_place.Folder is { } folder)
        {
            m.Items.Add(I(L("folder.exportZip"), "\uEDE1", () => _ = ExportZip(folder)));
            m.Items.Add(I(L("folder.renameEllipsis"), "\uE8AC", async () => { if (await FolderActions.Rename(MainWindow.Current!, folder) is { } n) MainWindow.Current!.Go(Place.OfFolder(n)); }));
            m.Items.Add(I(L("folder.deleteEllipsis"), "\uE74D", () => _ = FolderActions.Delete(MainWindow.Current!, folder)));
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

    public void Hidden()
    {
        _library.Changed -= OnLibraryChanged;
        _grid.Dispose();
    }
}
