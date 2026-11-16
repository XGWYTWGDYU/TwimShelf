// 标签: every tag with how many media carry it (yours and the AI's), in one of the other apps' orders;
// rename or merge one, put its media into a folder, delete it; delete all AI tags. A long list: the
// cards are made only for the rows on screen.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class TagsSettings : SettingsSubpage
{
    readonly LibraryModel _library;
    readonly ListView _list;
    List<TagCount>? _tags;

    public override string Title => L("common.tags");

    public TagsSettings(LibraryModel library)
    {
        _library = library;
        _list = new ListView
        {
            SelectionMode = ListViewSelectionMode.None,
            ItemTemplate = (DataTemplate)Application.Current.Resources["TagRowTemplate"],
        };
        _list.ItemContainerStyle = new Style(typeof(ListViewItem)) { Setters = { new Setter(ListViewItem.PaddingProperty, new Thickness(0)), new Setter(ListViewItem.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch), new Setter(FrameworkElement.MinHeightProperty, 0.0) } };
        _list.ContainerContentChanging += OnContainer;
        // the list scrolls itself (the page's own scroll would make every row at once)
        Content = new Grid { RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition() }, Children = { TakeBody() } };
        var grid = (Grid)Content;
        Grid.SetRow(_list, 1);
        _list.Margin = new Thickness(36, 0, 36, 24);
        _list.MaxWidth = 1000;
        grid.Children.Add(_list);
        _ = Load();
    }

    async Task Load()
    {
        _tags = await TlCore.Run(TlCore.AllTags);
        Build();
    }

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

    public override void Build()
    {
        Clear();
        Body.Margin = new Thickness(36, 8, 36, 8);
        var order = Prefs.Instance.TagSort;
        var sort = new DropDownButton { Content = OrderTitle(order) };
        var menu = new MenuFlyout();
        for (var o = 0; o < 4; o++)
        {
            var oo = o;
            var it = new ToggleMenuFlyoutItem { Text = OrderTitle(o), IsChecked = o == order };
            it.Click += (_, _) => { Prefs.Instance.TagSort = oo; Build(); };
            menu.Items.Add(it);
        }
        sort.Flyout = menu;
        var deleteAi = new Button { Content = L("tags.deleteAIEllipsis") };
        deleteAi.Click += (_, _) => _ = DeleteAi();
        Card(L("tags.sort"), null, "", new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { sort, deleteAi } });
        if (_tags == null) { _list.ItemsSource = null; Add(new ProgressRing { IsActive = true }); return; }
        if (_tags.Count == 0) { Card(L("tags.none"), L("tags.none.message"), ""); _list.ItemsSource = null; return; }
        _list.ItemsSource = Sorted(_tags, order);
    }

    void OnContainer(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not SettingsCard card || args.Item is not TagCount t) return;
        card.Header = t.Label;
        card.Description = L("tags.cell.detail", t.Count, t.User, t.Ai);
        // mine (or approved): a tag; only an AI's: its sparkle, as on the cards
        card.HeaderIcon = t.User > 0 ? new FontIcon { Glyph = "" } : TagStyle.MenuIconSparkle();
        var more = (Button)card.Content;
        var m = new MenuFlyout();
        m.Items.Add(FolderActions.Item(L("tags.renameOrMerge"), "", () => _ = Rename(t)));
        m.Items.Add(FolderActions.Item(L("common.addToFolder"), "", () => _ = ToFolder(t)));
        m.Items.Add(FolderActions.Item(L("tags.deleteEllipsis"), "", () => _ = Delete(t)));
        more.Flyout = m;
        ToolTipService.SetToolTip(more, L("grid.more"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, L("grid.more"));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(card, "tag-" + t.Label);
    }

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
        var folder = (await Dialogs.Prompt(W, L("tags.toFolder.title", t.Label, t.Count), L("common.folderName"), "", L("tags.toFolder.message"), L("common.addToFolder")))?.Trim();
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
        var ai = _tags?.Count(t => t.Ai > 0) ?? 0;
        if (!await Dialogs.Confirm(W, L("tags.deleteAI.title", ai), L("tags.deleteAI.message"), L("tags.deleteAI.confirm"), destructive: true)) return;
        await TlCore.Run(TlCore.RemoveAiTags);
        await Reload();
    }
}
