// 浏览 card's menu, as the other apps': the author (only theirs, their profile), tagging (this media,
// the whole post, approve the AI's, retag with a model, where the tags came from), each tag (only it,
// search it, approve, rename, delete), folders, download again, and the deletions.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.AI;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

/// What 浏览 does for the menu's filter and search entries.
public sealed record CardMenuHost(Action<string, string> OnlyAuthor, Action<string> OnlyLabel, Action<string> AddTerm);

public static class CardMenu
{
    static Window W => MainWindow.Current!;
    static bool IsAi(TagView t) => (t.Origin & 2) != 0;
    static bool IsUser(TagView t) => (t.Origin & 1) != 0;
    static MediaRef Ref(FeedItem i) => new() { MediaId = i.MediaId, Path = i.Path, Kind = i.IsVideo ? "video" : "photo", Text = i.Text };

    public static MenuFlyout Build(FeedItem item, CardMenuHost host)
    {
        var lib = LibraryModel.Current;
        var I = FolderActions.Item;
        var m = new MenuFlyout();
        var loose = item.IsLoose();
        var groups = new List<List<MenuFlyoutItemBase>>();

        var authorKey = item.ScreenName ?? item.AuthorName;
        var authorDisplay = item.ScreenName != null ? "@" + item.ScreenName : item.AuthorName ?? L("common.unknownAuthor");
        var top = new List<MenuFlyoutItemBase>();
        if (!loose && authorKey != null) top.Add(I(L("card.menu.onlyAuthor", authorDisplay), "", () => host.OnlyAuthor(authorKey, authorDisplay)));
        if (!loose && item.ScreenName != null) top.Add(I(L("card.menu.openProfile", item.ScreenName), "", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://x.com/" + item.ScreenName))));
        groups.Add(top);

        var pending = item.Tags.Where(t => IsAi(t) && !IsUser(t)).ToList();
        var local = LocalModels.Instance;
        var models = local.Installed.Where(x => x.Vision).Select(x => (x.Id, Title: local.Title(x)))
            .Concat(lib.Ai.Models.All.Select(x => (x.Id, x.Title))).ToList();
        MenuFlyoutSubItem Retag(string text, string? glyph, string model)
        {
            var s = new MenuFlyoutSubItem { Text = text, Icon = glyph == null ? null : new FontIcon { Glyph = glyph } };
            s.Items.Add(I(L("card.menu.retagAdd"), "", () => lib.Ai.Tagger.Retag([Ref(item)], model)));
            s.Items.Add(I(L("card.menu.retagReplace"), "", () => lib.Ai.Tagger.Retag([Ref(item)], model, replaceOld: true)));
            return s;
        }
        var tagging = new List<MenuFlyoutItemBase> { I(L("card.menu.tagMedia"), "", () => _ = TagPicker.Show(item, false)) };
        if (!loose) tagging.Add(I(L("card.menu.tagPost"), "", () => _ = TagPicker.Show(item, true)));
        if (pending.Count > 0)
            tagging.Add(I(L("card.menu.approveAll"), "", async () =>
            {
                await TlCore.Run(() => { foreach (var t in pending) TlCore.AddTag(t.Label, item.MediaId); });
                _ = lib.Refresh();
            }));
        if (models.Count == 1) tagging.Add(Retag(L("card.menu.retag"), "", models[0].Id));
        else if (models.Count > 1)
        {
            var s = new MenuFlyoutSubItem { Text = L("card.menu.retag"), Icon = new FontIcon { Glyph = "" } };
            foreach (var (id, title) in models) s.Items.Add(Retag(title, id == lib.Ai.Models.ActiveTaggerId ? "" : "", id));
            tagging.Add(s);
        }
        if (item.Tags.Count > 0) tagging.Add(I(L("card.menu.sources"), "", () => _ = Sources(item)));
        groups.Add(tagging);

        async void DeleteTag(TagView t)
        {
            await TlCore.Run(() => TlCore.RemoveTag(t.Label, item.MediaId));
            _ = lib.Refresh();
            Dialogs.Toast(W, L("tag.deleted", t.Label), L("common.undo"), async () =>
            {
                // the same origin back (yours, AI, or endorsed)
                await TlCore.Run(() =>
                {
                    if (IsAi(t)) TlCore.AddTag(t.Label, item.MediaId, ai: true);
                    if (IsUser(t)) TlCore.AddTag(t.Label, item.MediaId);
                });
                _ = lib.Refresh();
            });
        }

        var perTag = new List<MenuFlyoutItemBase>();
        foreach (var t in item.Tags)
        {
            var s = new MenuFlyoutSubItem { Text = t.Label, Icon = TagStyle.MenuIcon(t) };
            s.Items.Add(I(L("card.menu.onlyTag"), "", () => host.OnlyLabel(t.Label)));
            s.Items.Add(I(L("card.menu.searchTag"), "", () => host.AddTerm(t.Label)));
            if (IsAi(t) && !IsUser(t)) s.Items.Add(I(L("card.menu.approve"), "", async () => { await TlCore.Run(() => TlCore.AddTag(t.Label, item.MediaId)); _ = lib.Refresh(); }));
            s.Items.Add(I(L("card.menu.renameTag"), "", () => _ = RenameTag(t.Label)));
            s.Items.Add(I(L("card.menu.deleteTag"), "", () => DeleteTag(t)));
            perTag.Add(s);
        }
        groups.Add(perTag);

        var inFolders = TlCore.MediaFolders(item.MediaId);
        var folders = new List<MenuFlyoutItemBase> { I(L("common.addToFolder"), "", () => _ = ToFolder(media: [item.MediaId])) };
        if (!loose) folders.Add(I(L("card.menu.postToFolder"), "", () => _ = ToFolder(posts: [item.PostId])));
        if (inFolders.Count > 0)
        {
            var s = new MenuFlyoutSubItem { Text = L("common.removeFromFolder"), Icon = new FontIcon { Glyph = "" } };
            foreach (var f in inFolders)
            {
                var fs = new MenuFlyoutSubItem { Text = f, Icon = new FontIcon { Glyph = "" } };
                fs.Items.Add(I(L("card.menu.removeMedia"), "", () => _ = MediaActions.Run(ActionKind.FolderRemove, [item.MediaId], folder: f, done: _ => L("common.removeFromFolder"))));
                if (!loose) fs.Items.Add(I(L("card.menu.removePost"), "", () => _ = MediaActions.Run(ActionKind.FolderRemove, posts: [item.PostId], folder: f, done: _ => L("common.removeFromFolder"))));
                s.Items.Add(fs);
            }
            folders.Add(s);
        }
        groups.Add(folders);

        var files = new List<MenuFlyoutItemBase>
        {
            I(L("windows.showInExplorer"), "", () => MediaActions.ShowInExplorer(item.Path)),
        };
        if (item.CanRedownload) files.Add(I(item.Bad == null ? L("card.menu.redownload") : L("card.menu.redownloadBad"), "", () => _ = Repair(item)));
        groups.Add(files);

        var delete = new List<MenuFlyoutItemBase>();
        if (item.Tags.Count > 0)
        {
            var s = new MenuFlyoutSubItem { Text = L("card.menu.deleteTag"), Icon = new FontIcon { Glyph = "" } };
            foreach (var t in item.Tags) s.Items.Add(I(t.Label, "", () => DeleteTag(t)));
            delete.Add(s);
        }
        delete.Add(I(L("card.menu.deleteMedia"), "", () => _ = MediaActions.Run(ActionKind.Trash, [item.MediaId], done: n => L("trash.moved", n))));
        if (!loose) delete.Add(I(L("card.menu.deletePost"), "", () => _ = MediaActions.Run(ActionKind.Trash, posts: [item.PostId], done: n => L("trash.moved", n))));
        groups.Add(delete);

        foreach (var g in groups.Where(g => g.Count > 0))
        {
            if (m.Items.Count > 0) m.Items.Add(new MenuFlyoutSeparator());
            foreach (var it in g) m.Items.Add(it);
        }
        return m;
    }

    static async Task ToFolder(List<string>? media = null, List<string>? posts = null)
    {
        var folder = await MediaActions.PickFolder();
        if (folder == null) return;
        await MediaActions.Run(ActionKind.FolderAdd, media, posts, folder, _ => L("tags.toFolder.done", folder));
    }

    static async Task RenameTag(string label)
    {
        var to = (await Dialogs.Prompt(W, L("card.menu.renameTag"), L("common.name"), label, primary: L("common.done")))?.Trim() ?? "";
        if (to.Length == 0 || to == label) return;
        await TlCore.Run(() => TlCore.RenameTag(label, to));
        await LibraryModel.Current.Refresh();
    }

    public static async Task Repair(FeedItem item)
    {
        Dialogs.Toast(W, L("common.redownloading"));
        string title;
        string? message;
        try
        {
            var r = await TlCore.Run(() => TlCore.Repair(item.MediaId));
            (title, message) = r switch
            {
                RepairResult.ReplacedNew => (L("repair.replacedNew.title"), L("repair.replacedNew.message")),
                RepairResult.FromPeers => (L("repair.fromPeers.title"), L("repair.fromPeers.message")),
                _ => (L("repair.fixed"), (string?)null),
            };
        }
        catch (Exception e) { (title, message) = (L("repair.failed"), e.Message); }
        await LibraryModel.Current.Refresh();
        if (message == null) Dialogs.Toast(W, title);
        else await Dialogs.Alert(W, title, message);
    }

    /// 标签来源: where each tag came from (you, AI and which models, or both).
    static async Task Sources(FeedItem item)
    {
        var lib = LibraryModel.Current;
        var panel = new StackPanel { Spacing = 10, MinWidth = 360 };
        foreach (var t in item.Tags)
        {
            var source = (t.Origin & 3) == 3 ? L("tag.source.both") : IsAi(t) ? "AI" : L("tag.source.me");
            if (t.Models.Count > 0) source += " · " + string.Join(L("list.separator"), t.Models.Select(x => lib.Ai.Models.Find(x)?.Title ?? x));
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
            row.Children.Add(new FontIcon { Glyph = IsAi(t) ? (IsUser(t) ? "" : "") : "", FontSize = 16 });
            row.Children.Add(new StackPanel { Children = { new TextBlock { Text = t.Label }, new TextBlock { Text = source, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] } } });
            panel.Children.Add(row);
        }
        panel.Children.Add(new TextBlock { Text = L("tag.sources.legend"), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] });
        await Dialogs.ShowAsync(W, new ContentDialog { Title = L("tag.sources.title"), Content = new ScrollViewer { Content = panel, MaxHeight = 480 }, CloseButtonText = L("common.ok") });
    }
}
