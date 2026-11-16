// Making, renaming (a taken name merges, asked first) and deleting folders, from the sidebar, the
// folders page and the grids, as the Mac app's MacFolderActions.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class FolderActions
{
    public static async Task<string?> Create(Window w)
    {
        var input = await Dialogs.Prompt(w, L("common.newFolder"), L("common.name"), primary: L("common.create"));
        var n = input?.Trim() ?? "";
        if (n.Length == 0) return null;
        try
        {
            await TlCore.Run(() => TlCore.CreateFolder(n));
            await LibraryModel.Current.Refresh();
            return n;
        }
        catch (Exception e)
        {
            await Dialogs.Alert(w, L("common.couldNotCreate"), e.Message);
            return null;
        }
    }

    public static async Task<string?> Rename(Window w, string name)
    {
        var input = await Dialogs.Prompt(w, L("folder.rename.title"), L("common.name"), name, primary: L("common.rename"));
        var n = input?.Trim() ?? "";
        if (n.Length == 0 || n == name) return null;
        var taken = (await TlCore.Run(TlCore.Folders)).Any(f => f.Name == n);
        if (taken && !await Dialogs.Confirm(w, L("folder.merge.title", n), L("folder.merge.message", n, name, name), L("folder.merge"))) return null;
        try
        {
            await TlCore.Run(() => TlCore.RenameFolder(name, n));
            await LibraryModel.Current.Refresh();
            return n;
        }
        catch (Exception e)
        {
            await Dialogs.Alert(w, L("common.couldNotRename"), e.Message);
            return null;
        }
    }

    public static async Task<bool> Delete(Window w, string name)
    {
        if (!await Dialogs.Confirm(w, L("folder.delete.title", name), L("folder.delete.message"), L("folder.delete.confirm"), destructive: true)) return false;
        try { await TlCore.Run(() => TlCore.DeleteFolder(name)); } catch { }
        await LibraryModel.Current.Refresh();
        return true;
    }

    /// A folder's menu (sidebar, folders page): rename, delete, new folder.
    public static MenuFlyout Menu(Window w, string name, Action<string>? onRenamed = null, Action? onOpen = null)
    {
        var m = new MenuFlyout();
        if (onOpen != null)
        {
            m.Items.Add(Item(L("common.open"), "", onOpen));
            m.Items.Add(new MenuFlyoutSeparator());
        }
        m.Items.Add(Item(L("folder.renameShort"), "", async () => { if (await Rename(w, name) is { } n) onRenamed?.Invoke(n); }));
        m.Items.Add(Item(L("folder.deleteNamed", name), "", async () => await Delete(w, name)));
        m.Items.Add(new MenuFlyoutSeparator());
        m.Items.Add(Item(L("common.newFolderEllipsis"), "", async () => await Create(w)));
        return m;
    }

    public static MenuFlyout NewMenu(Window w)
    {
        var m = new MenuFlyout();
        m.Items.Add(Item(L("common.newFolderEllipsis"), "", async () => await Create(w)));
        return m;
    }

    public static MenuFlyoutItem Item(string text, string? glyph, Action click, bool enabled = true)
    {
        var i = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph != null) i.Icon = new FontIcon { Glyph = glyph };
        i.Click += (_, _) => click();
        return i;
    }
}
