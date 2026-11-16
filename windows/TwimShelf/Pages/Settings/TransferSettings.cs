// 导入与备份: old-format ZIPs (a folder per post), ZIPs of loose media, .tlpack export packs (into a
// folder or none), the import records with their details, and a backup of the whole library.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class TransferSettings(LibraryModel library) : SettingsSubpage
{
    public override string Title => L("common.importAndBackup");

    public override void Build()
    {
        Clear();
        Header(L("common.import"));
        Action(L("settings.import.legacy"), L("mac.import.legacy.detail"), "", () => _ = Import(".zip", (p, f) => TlCore.ImportLegacyZip(p, f)));
        Action(L("settings.import.loose"), L("mac.import.loose.detail"), "", () => _ = Import(".zip", (p, f) => TlCore.ImportLooseZip(p, f)));
        Action(L("settings.import.pack"), L("mac.import.pack.detail"), "", () => _ = Import(".tlpack", (p, f) => TlCore.ImportPack(p, f)));
        Nav(L("common.importRecords"), null, "", () => new ImportRecordsSettings(), "importRecords");
        Footer(L("settings.import.footer"));

        Header(L("common.backup"));
        Action(L("settings.backup.button"), L("mac.backup.detail"), "\uE7B8", () => _ = Backup());
        Footer(L("settings.backup.footer"));
    }

    /// 导入到文件夹？ an existing one, a new one named after the file by default, or none.
    async Task<string?> AskFolder(string suggested)
    {
        // the default shows as the name itself (picking a folder above clears it)
        var name = new TextBox { Header = L("common.newFolder"), PlaceholderText = suggested, Text = suggested };
        name.Loaded += (_, _) => { name.Focus(FocusState.Programmatic); name.SelectAll(); };
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 280 };
        list.Items.Add(new ListViewItem { Content = L("share.noFolder"), Tag = "" });
        foreach (var f in library.Folders?.Folders ?? []) list.Items.Add(new ListViewItem { Content = f.Name, Tag = f.Name });
        var d = new ContentDialog
        {
            Title = L("common.importToFolder"),
            Content = new StackPanel { Spacing = 10, Width = 380, Children = { list, name } },
            PrimaryButtonText = L("share.import"),
            CloseButtonText = L("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };
        list.SelectionChanged += (_, _) => { if (list.SelectedItem != null) name.Text = ""; };
        name.TextChanged += (_, _) => { if (name.Text.Length > 0) list.SelectedItem = null; };
        if (await Dialogs.ShowAsync(W, d) != ContentDialogResult.Primary) return null;
        if (name.Text.Trim().Length > 0) return name.Text.Trim();
        if (list.SelectedItem is ListViewItem { Tag: string t }) return t;
        return suggested;
    }

    async Task Import(string ext, Func<string, string, ImportReport> run)
    {
        var path = await Pickers.OpenFile(W, ext);
        if (path == null) return;
        var folder = await AskFolder(Path.GetFileNameWithoutExtension(path));
        if (folder == null) return;
        if (folder.Length > 0) { try { await TlCore.Run(() => TlCore.CreateFolder(folder)); } catch { /* it is there already */ } }
        ImportReport report;
        try
        {
            report = await Dialogs.Progress(W, L("common.importing"), () => run(path, folder),
                () => TlCore.ImportStatus() is { FoldersTotal: > 0 } p ? L("activity.importProgress", p.FoldersDone, p.FoldersTotal, p.FilesDone) : null, TlCore.CancelImport);
        }
        catch (Exception e) { await Dialogs.Alert(W, L("common.notDone"), e.Message); return; }
        await library.Refresh();
        // stopped part way (cancelled, a disk that filled up): said so, with what did arrive
        if (report.Incomplete is { } why) await Dialogs.Alert(W, L("common.notDone"), why + "\n\n" + report.Summary());
        else await Dialogs.Alert(W, L("import.done"), report.Summary());
    }

    async Task Backup()
    {
        var dir = await Pickers.Folder(W);
        if (dir == null) return;
        var out_ = Path.Combine(dir, L("settings.backup.fileName", DateTime.Now.ToString("yyyy-MM-dd HH.mm")) + ".tlpack");
        ExportReport r;
        try
        {
            r = await Dialogs.Progress(W, L("settings.backup.running"), () => TlCore.ExportBackup(out_),
                () => TlCore.ExportStatus() is { Total: > 0 } p ? L("settings.backup.progress", p.Done, p.Total, Format.Bytes(p.Bytes)) : null, () => TlCore.CancelExport());
        }
        catch (Exception e) { await Dialogs.Alert(W, L("common.notDone"), e.Message); return; }
        await Dialogs.Alert(W, r.Skipped.Count == 0 ? L("settings.backup.done") : L("settings.backup.doneIncomplete"),
            L("settings.backup.result", r.Posts, r.Media, r.Trashed, Format.Bytes(r.Bytes), out_) + (r.Skipped.Count == 0 ? "" : L("settings.backup.skipped", r.Skipped.Count)));
    }
}

/// 导入记录: every import, newest first, with how many of its files did not import normally.
public sealed partial class ImportRecordsSettings : SettingsSubpage
{
    public override string Title => L("common.importRecords");

    static string FileNameOf(string path) => path.Split('/', '\\').LastOrDefault(p => p.Length > 0) ?? path;

    public override void Build()
    {
        Clear();
        List<(string File, DateTime Date, string Source, long Issues)> list;
        try { list = TlCore.ImportReports(); } catch { list = []; }
        if (list.Count == 0) Card(L("import.history.none"));
        foreach (var r in list)
        {
            var file = r.File;
            var c = Card($"{r.Date:g} · {FileNameOf(r.Source)}", r.Issues == 0 ? L("mac.importHistory.ok") : L("import.issuesCount", r.Issues), r.Issues == 0 ? "" : "");
            c.IsClickEnabled = true;
            c.ActionIcon = new FontIcon { Glyph = "" };
            c.Click += async (_, _) =>
            {
                try
                {
                    var rep = await TlCore.Run(() => TlCore.ImportReport(file));
                    Host?.Push(new ImportReportSettings(file, rep));
                }
                catch { }
            };
        }
        Footer(L("import.history.footer"));
        if (list.Count > 0)
            Action(L("import.deleteAll"), null, "", async () =>
            {
                if (await Delete([.. list.Select(r => r.File)], L("mac.importHistory.all", list.Count))) Build();
            }, danger: true);
    }

    /// Deletes records after asking; the app's own copies of their sources go too, never a file elsewhere.
    public static async Task<bool> Delete(List<string> files, string what)
    {
        if (!await Dialogs.Confirm(W, L("mac.importHistory.deleteTitle", what), L("import.deleteAll.message"), L("common.delete"), destructive: true)) return false;
        try
        {
            var r = await TlCore.Run(() => TlCore.DeleteImportReports(files, ShareInbox.OwnedRoots()));
            await Dialogs.Alert(W, L("mac.importHistory.deleted", r.Reports), r.Sources > 0 ? L("import.deleted.sources", r.Sources, Format.Bytes(r.Bytes)) : L("import.deleted.freed", Format.Bytes(r.Bytes)));
            return true;
        }
        catch (Exception e) { Dialogs.Toast(W, e.Message); return false; }
    }
}

/// 导入详情: what did not import normally, by kind; the problem files can be exported unchanged.
public sealed partial class ImportReportSettings(string file, ImportReport report) : SettingsSubpage
{
    public override string Title => L("import.details");

    static string Category(string c) => ImportSummary.Category(c);

    public override void Build()
    {
        Clear();
        if (report.Source != null) Footer(L("import.source") + Path.GetFileName(report.Source.TrimEnd('/', '\\')));
        if (report.Issues.Count > 0)
        {
            Action(L("import.export"), L("import.export.footer"), "", async () =>
            {
                var out_ = await Pickers.SaveFile(W, L("import.problemsZip"), ("ZIP", ".zip"));
                if (out_ == null) return;
                try { await TlCore.Run(() => TlCore.ExportImportIssues(file, out_)); Dialogs.Toast(W, L("export.done")); }
                catch (Exception e) { Dialogs.Toast(W, e.Message); }
            });
        }
        foreach (var g in report.Issues.GroupBy(i => i.Category))
        {
            var ex = new SettingsExpander { Header = L("format.nameDetail", Category(g.Key), g.Count()), HeaderIcon = Icon("") };
            foreach (var i in g.Take(500))
                ex.Items.Add(new SettingsCard { Header = new TextBlock { Text = i.Path, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }, Description = i.Reason + (i.SameAs == null ? "" : L("import.matches") + i.SameAs) });
            Add(ex);
            if (g.Count() > 500) Footer(L("import.first500"));
        }
        Action(L("import.delete"), L("import.delete.footer"), "", async () =>
        {
            if (await ImportRecordsSettings.Delete([file], L("mac.importHistory.this"))) Host?.Pop();
        }, danger: true);
    }
}

/// The import alert's text, as the Mac app's: what was read, what the library gained (merged posts
/// and media it had already do not count), each kind of problem, the folder, and a backup's extras.
public static class ImportSummary
{
    static readonly string[] Order = ["not_media", "unsupported", "unreadable", "ignored_location", "unsafe_path", "duplicate", "in_bin", "post_not_imported", "post_hidden", "post_merged", "post_text_truncated"];

    public static string Category(string c) => Order.Contains(c) ? L("import.cat." + c) : L("sidebar.other");

    public static string Summary(this ImportReport r)
    {
        var t = L("import.summary.read", r.Entries, r.Sidecars, r.SystemFiles);
        t += L("import.summary.added", r.Posts - r.MergedPosts - r.PostsWithoutMedia, r.NewMedia);
        foreach (var g in r.Issues.GroupBy(i => i.Category).OrderBy(g => Array.IndexOf(Order, g.Key) is var i and >= 0 ? i : Order.Length))
            t += L("import.summary.issue", Category(g.Key), g.Count());
        if (r.Folder != null) t += L("import.summary.folder", r.Folder, r.FolderAdded);
        if (r.ToBin > 0) t += L("import.summary.toBin", r.ToBin);
        if (r.RenamesRestored + r.FoldersRestored > 0) t += L("import.summary.restored", r.RenamesRestored, r.FoldersRestored);
        t += r.Issues.Count == 0 ? L("import.summary.allOK") : L("import.summary.canView");
        return t;
    }
}
