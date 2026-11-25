// What can be done to media, the same from every grid and card (the other apps' context menus):
// show its post in 浏览, tags, folders, the bin. Every change can be undone from the message it leaves.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class MediaActions
{
    static Window W => MainWindow.Current!;

    public static bool IsLoose(this FeedItem i) => i.PostId.StartsWith("loose:");

    /// The menu of one media (in a grid or on a card); folder: the folder the grid shows.
    public static MenuFlyout Menu(FeedItem item, Place? place = null, IList<FeedItem>? post = null)
    {
        var lib = LibraryModel.Current;
        var m = new MenuFlyout();
        var I = FolderActions.Item;
        if (place == Place.Trash)
        {
            m.Items.Add(I(L("common.restore"), "", () => _ = Run(ActionKind.Restore, media: [item.MediaId], done: n => L("trash.restored", n))));
            m.Items.Add(I(L("common.deletePermanently"), "", () => _ = Purge([item.MediaId])));
            return m;
        }
        // where it is in 浏览: a loose media on its own, a post's media with its post (as the other apps)
        m.Items.Add(I(item.IsLoose() ? L("grid.revealMedia") : L("grid.revealPost"), "", () => lib.Reveal(item)));
        m.Items.Add(I(L("card.menu.tagMedia"), "", () => _ = TagPicker.Show(item, wholePost: false)));
        if (!item.IsLoose()) m.Items.Add(I(L("card.menu.tagPost"), "", () => _ = TagPicker.Show(item, wholePost: true)));
        m.Items.Add(I(L("common.addToFolder"), "", () => _ = AddToFolder([item])));
        if (place?.Folder is { } folder)
            m.Items.Add(I(L("card.menu.removeMedia"), "", () => _ = Run(ActionKind.FolderRemove, media: [item.MediaId], folder: folder, done: _ => L("common.removeFromFolder"))));
        // (no "show in Explorer": the library's own files are not for moving or deleting by hand)
        m.Items.Add(new MenuFlyoutSeparator());
        m.Items.Add(I(L("grid.trashMedia"), "", () => _ = Run(ActionKind.Trash, media: [item.MediaId], done: n => L("trash.moved", n))));
        if (!item.IsLoose()) m.Items.Add(I(L("grid.trashPost"), "", () => _ = Run(ActionKind.Trash, posts: [item.PostId], done: n => L("trash.moved", n))));
        return m;
    }

    public static void ShowInExplorer(string path)
    {
        // (Explorer finds nothing with the `/` the core's relative paths bring)
        try { System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{Path.GetFullPath(path)}\""); } catch { }
    }

    /// Runs an action and leaves a message with 撤销.
    public static async Task<ActionReceipt?> Run(ActionKind kind, IEnumerable<string>? media = null, IEnumerable<string>? posts = null, string? folder = null, Func<int, string>? done = null, BinSnapshot? snapshot = null)
    {
        var lib = LibraryModel.Current;
        ActionReceipt receipt;
        var m = media?.ToList() ?? [];
        var p = posts?.ToList() ?? [];
        try { receipt = await TlCore.Run(() => TlCore.Action(kind, m, p, folder, null, snapshot)); }
        catch (Exception e) { Dialogs.Toast(W, e.Message); return null; }
        _ = lib.Refresh();
        if (done != null)
            Dialogs.Toast(W, done(receipt.Changes.Count), L("common.undo"), async () =>
            {
                var n = await TlCore.Run(() => TlCore.Undo(receipt));
                _ = lib.Refresh();
                Dialogs.Toast(W, L("undo.done", n));
            });
        return receipt;
    }

    /// 永久删除, asked first; what the person sees now is what the confirmation is about.
    public static async Task Purge(IReadOnlyCollection<string>? media)
    {
        var snapshot = await TlCore.Run(() => TlCore.BinSnapshot(media));
        if (snapshot.Entries.Count == 0) return;
        var count = media?.Count ?? snapshot.Entries.Count;
        if (!await Dialogs.Confirm(W, media == null ? L("trash.emptyTitle") : L("trash.purgeTitle"), L("trash.purgeMessage", L("trash.moved", count)), L("common.deletePermanently"), destructive: true)) return;
        var r = await TlCore.Run(() => TlCore.Action(ActionKind.Purge, media ?? [], null, null, null, snapshot));
        await LibraryModel.Current.Refresh();
        Dialogs.Toast(W, L("trash.purged", r.Changes.Count) + (r.Changes.Count < snapshot.Entries.Count ? L("trash.purged.skipped") : ""));
    }

    /// Chooses a folder, or names a new one (made here); null when cancelled.
    public static async Task<string?> PickFolder()
    {
        var folders = LibraryModel.Current.Folders?.Folders ?? [];
        var box = new TextBox { PlaceholderText = L("common.newFolder") };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 320 };
        foreach (var f in folders)
        {
            var row = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
            row.Children.Add(new FontIcon { Glyph = "", FontSize = 16, Margin = new Thickness(0, 0, 12, 0) });
            var name = new TextBlock { Text = f.Name, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(name, 1);
            row.Children.Add(name);
            var c = new TextBlock { Text = f.Count.ToString("N0"), Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
            Grid.SetColumn(c, 2);
            row.Children.Add(c);
            list.Items.Add(new ListViewItem { Content = row, Tag = f.Name });
        }
        var d = new ContentDialog
        {
            Title = L("common.addToFolder"),
            Content = new StackPanel
            {
                Spacing = 8, Width = 380,
                // (no "each whole post goes in" line: only the chosen media do, as in the Apple app's grids)
                Children = { box, list },
            },
            PrimaryButtonText = L("common.ok"),
            CloseButtonText = L("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        string? chosen = null;
        void Update()
        {
            var typed = box.Text.Trim();
            chosen = typed.Length > 0 ? typed : (list.SelectedItem as ListViewItem)?.Tag as string;
            d.IsPrimaryButtonEnabled = chosen != null;
            d.PrimaryButtonText = typed.Length > 0 && folders.All(f => f.Name != typed) ? L("folderPicker.new", typed) : L("common.ok");
        }
        box.TextChanged += (_, _) => { if (box.Text.Length > 0) list.SelectedItem = null; Update(); };
        list.SelectionChanged += (_, _) => { if (list.SelectedItem != null) box.Text = ""; Update(); };
        list.IsItemClickEnabled = true;
        var picked = false; // a folder clicked in the list (it closes the dialog itself)
        list.ItemClick += (_, e) =>
        {
            // the event names the row's content, not the ListViewItem around it
            var item = e.ClickedItem as ListViewItem ?? list.Items.OfType<ListViewItem>().FirstOrDefault(i => ReferenceEquals(i.Content, e.ClickedItem));
            if (item?.Tag is not string name) return;
            chosen = name;
            picked = true;
            d.Hide();
        };
        var r = await Dialogs.ShowAsync(W, d);
        // 取消 and Esc are a cancel, whatever was typed or selected
        if (r != ContentDialogResult.Primary && !picked) return null;
        if (chosen == null) return null;
        if (folders.All(f => f.Name != chosen))
        {
            var n = chosen;
            try { await TlCore.Run(() => TlCore.CreateFolder(n)); } catch { }
        }
        return chosen;
    }

    /// Puts the chosen media into a folder: those media only, as the Apple app's grids do (a whole
    /// post has its own item on a card).
    public static async Task AddToFolder(IReadOnlyList<FeedItem> items)
    {
        var folder = await PickFolder();
        if (folder == null) return;
        await Run(ActionKind.FolderAdd, items.Select(i => i.MediaId).Distinct().ToList(), null, folder, _ => L("tags.toFolder.done", folder));
    }
}
