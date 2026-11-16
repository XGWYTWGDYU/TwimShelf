// 导出搜索结果 (the button beside the search field): the media of the current result as a .tlpack
// (with their posts, and tags and folder memberships if chosen) or a plain zip of the media, saved
// where the person chooses; then what was exported and what was left out.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;
using TwimShelf.Core;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class SearchExport
{
    static bool Pref(string key, bool fallback) => Prefs.Instance.Raw(key) is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;

    public static async Task Run(IReadOnlyList<FeedItem> items, IReadOnlyList<string> terms)
    {
        var w = MainWindow.Current!;
        var ids = items.Select(i => i.MediaId).ToList();
        bool tags = Pref("export.tags", true), folders = Pref("export.folders", true), mediaOnly = Pref("export.mediaOnly", false);
        var count = new TextBlock { TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"] };
        ToggleSwitch tagsSwitch = new(), foldersSwitch = new(), mediaSwitch = new() { IsOn = mediaOnly };
        void Update()
        {
            count.Text = ids.Count == 0 ? L("export.search.none") : mediaOnly ? L("export.search.countMedia", ids.Count) : L("export.search.countWithPosts", ids.Count);
            // with 以纯媒体导出 on, these two show as off and cannot be changed
            tagsSwitch.IsOn = tags && !mediaOnly;
            foldersSwitch.IsOn = folders && !mediaOnly;
            tagsSwitch.IsEnabled = foldersSwitch.IsEnabled = !mediaOnly;
        }
        Update();
        tagsSwitch.Toggled += (_, _) => { if (!mediaOnly) { tags = tagsSwitch.IsOn; Prefs.Instance.Set("export.tags", tags, false); } };
        foldersSwitch.Toggled += (_, _) => { if (!mediaOnly) { folders = foldersSwitch.IsOn; Prefs.Instance.Set("export.folders", folders, false); } };
        mediaSwitch.Toggled += (_, _) => { mediaOnly = mediaSwitch.IsOn; Prefs.Instance.Set("export.mediaOnly", mediaOnly, false); Update(); };
        var panel = new StackPanel
        {
            Spacing = 4, Width = 440,
            Children =
            {
                count,
                new SettingsCard { Header = L("export.option.tags"), Description = L("export.option.tags.detail"), Content = tagsSwitch },
                new SettingsCard { Header = L("export.option.folders"), Description = L("export.option.folders.detail"), Content = foldersSwitch },
                new SettingsCard { Header = L("export.option.mediaOnly"), Description = L("export.option.mediaOnly.detail"), Content = mediaSwitch },
            },
        };
        var d = new ContentDialog
        {
            Title = L("export.search.title"),
            Content = panel,
            PrimaryButtonText = L("export.go"),
            CloseButtonText = L("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = ids.Count > 0,
        };
        if (await Dialogs.ShowAsync(w, d) != ContentDialogResult.Primary) return;
        var options = mediaOnly ? new ExportOptions { Tags = false, Folders = false, MediaOnly = true } : new ExportOptions { Tags = tags, Folders = folders };
        await ToFile(ids, options, FileName(terms) + (mediaOnly ? ".zip" : ".tlpack"));
    }

    /// "<app> 猫咪搜索结果": only the words searched for; what no system accepts in a file name goes.
    public static string FileName(IReadOnlyList<string> terms)
    {
        var bad = "\\/:*?\"<>|";
        var words = string.Join(' ', terms.Select(t => new string([.. t.Select(c => bad.Contains(c) || c < 0x20 ? ' ' : c)]).Trim()).Where(t => t.Length > 0));
        return words.Length == 0 ? L("export.search.fileNameAll") : L("export.search.fileName", words);
    }

    public static async Task ToFile(List<string> ids, ExportOptions options, string name)
    {
        var w = MainWindow.Current!;
        var ext = Path.GetExtension(name);
        var path = await Pickers.SaveFile(w, name, (ext == ".zip" ? "ZIP" : "TwimShelf", ext));
        if (path == null) return;
        try
        {
            var r = await Dialogs.Progress(w, L("export.running", ids.Count), () => TlCore.ExportMedia(ids, path, options),
                () => TlCore.ExportStatus() is { Total: > 0 } p ? L("settings.backup.progress", p.Done, p.Total, Format.Bytes(p.Bytes)) : null, () => TlCore.CancelExport());
            var more = Format.Skipped(r);
            await Dialogs.Alert(w, more.Length == 0 ? L("export.done") : L("export.doneIncomplete"), L("export.summary", r.Posts, r.Media, Format.Bytes(r.Bytes)) + (more.Length == 0 ? "" : "\n\n" + more));
        }
        catch (Exception e) { await Dialogs.Alert(w, L("common.notDone"), e.Message); }
    }
}
