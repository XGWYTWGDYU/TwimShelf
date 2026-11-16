// 存储空间, 关于 (with the maintenance rows: the integrity check, the log, diagnostics) and the data
// folder (moving it), as the other apps have them.
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

/// 存储空间: what the app takes on this computer, by part, and clearing what can be made again.
public sealed partial class StorageSettings(LibraryModel library) : SettingsSubpage
{
    static readonly (string Title, string[] Keys)[] Sections =
    [
        ("storage.section.aiAndApp", ["models", "app"]),
        ("storage.section.library", ["database", "photos", "videos", "libraryOther"]),
        ("storage.section.free", ["bin", "thumbnails", "cache"]),
    ];
    static readonly HashSet<string> Clearable = ["thumbnails", "cache", "bin"];
    static readonly Dictionary<string, (uint Argb, string Glyph)> Looks = new()
    {
        ["models"] = (0xFF7E57C2, ""), ["app"] = (0xFF5C6BC0, ""), ["database"] = (0xFF42A5F5, ""),
        ["photos"] = (0xFFFFA726, ""), ["videos"] = (0xFFEF5350, ""), ["libraryOther"] = (0xFF26A69A, ""),
        ["bin"] = (0xFF8D6E63, ""), ["thumbnails"] = (0xFF66BB6A, ""), ["cache"] = (0xFF78909C, ""),
    };
    StorageUsage? _usage;
    string? _error;
    bool _started;
    readonly HashSet<string> _selected = ["thumbnails", "cache"];

    public override string Title => L("storage.title");

    Dictionary<string, List<string>> Places()
    {
        var cache = new List<string>();
        var cacheDir = DataHome.Path != null ? DataHome.CacheDir : null;
        if (cacheDir != null && Directory.Exists(cacheDir))
            foreach (var e in Directory.EnumerateFileSystemEntries(cacheDir))
                if (!string.Equals(Path.GetFullPath(e), Path.GetFullPath(Thumbnails.CacheDir), StringComparison.OrdinalIgnoreCase)) cache.Add(e);
        return new() { ["app"] = [AppContext.BaseDirectory.TrimEnd('\\')], ["thumbnails"] = [Thumbnails.CacheDir], ["cache"] = cache };
    }

    async Task Measure()
    {
        _usage = null;
        _error = null;
        Build();
        try { var places = Places(); _usage = await TlCore.Run(() => TlCore.StorageUsage(places)); }
        catch (Exception e) { _error = e.Message; }
        Build();
    }

    public override void Build()
    {
        if (!_started) { _started = true; _ = Measure(); }
        Clear();
        var u = _usage;
        if (u == null) { Card(_error == null ? L("storage.measuring") : L("storage.failed", _error), null, null, _error == null ? new ProgressRing { IsActive = true, Width = 20, Height = 20 } : null); return; }
        var bar = new Grid { Height = 14, CornerRadius = new CornerRadius(7), Margin = new Thickness(0, 8, 0, 4) };
        var col = 0;
        foreach (var g in u.Groups.Where(g => g.Bytes > 0))
        {
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(g.Bytes, u.Total / 200 + 1), GridUnitType.Star) });
            var b = new Border { Background = new SolidColorBrush(Theming.ToColor(Looks.GetValueOrDefault(g.Key, (Argb: 0xFF607D8BU, Glyph: "")).Argb)) };
            ToolTipService.SetToolTip(b, $"{L("storage.group." + g.Key)} · {Format.Bytes(g.Bytes)}");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, $"{L("storage.group." + g.Key)} · {Format.Bytes(g.Bytes)}");
            Grid.SetColumn(b, col++);
            bar.Children.Add(b);
        }
        var refresh = new Button { Content = L("storage.refresh") };
        refresh.Click += (_, _) => _ = Measure();
        Card(Format.Bytes(u.Total), null, "", refresh);
        Add(bar);
        foreach (var (title, keys) in Sections)
        {
            var groups = keys.Select(k => u.Groups.FirstOrDefault(g => g.Key == k)).OfType<StorageGroup>().ToList();
            if (groups.Count == 0) continue;
            Header(L(title));
            foreach (var g in groups)
            {
                var (argb, glyph) = Looks.GetValueOrDefault(g.Key, (0xFF607D8B, ""));
                var detail = L("storage.group." + g.Key + ".detail") + (g.Files > 0 && g.Key != "app" ? " · " + L("storage.files", g.Files) : "");
                object? content = new TextBlock { Text = Format.Bytes(g.Bytes), VerticalAlignment = VerticalAlignment.Center };
                if (Clearable.Contains(g.Key))
                {
                    var tick = new CheckBox { IsChecked = _selected.Contains(g.Key), Content = Format.Bytes(g.Bytes) };
                    var key = g.Key;
                    tick.Click += (_, _) => { if (tick.IsChecked == true) _selected.Add(key); else _selected.Remove(key); Build(); };
                    content = tick;
                }
                var c = Card(L("storage.group." + g.Key), detail, null, content);
                c.HeaderIcon = new FontIcon { Glyph = glyph, Foreground = new SolidColorBrush(Theming.ToColor(argb)) };
                if (g.Key == "models")
                {
                    var manage = new HyperlinkButton { Content = L("storage.manage") };
                    manage.Click += (_, _) => Host?.Push(new AiSettings(library));
                    c.Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Children = { (UIElement)content!, manage } };
                }
            }
        }
        var size = u.Groups.Where(g => _selected.Contains(g.Key)).Sum(g => g.Bytes);
        var clear = new Button { Content = size > 0 ? $"{L("storage.clear.selected")}  {Format.Bytes(size)}" : L("storage.clear.selected"), IsEnabled = size > 0, Style = (Style)Application.Current.Resources["AccentButtonStyle"], HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        clear.Click += (_, _) => _ = ClearSelected(size);
        Add(clear);
    }

    async Task ClearSelected(long size)
    {
        var bin = _selected.Contains("bin");
        if (!await Dialogs.Confirm(W, L("storage.clear.title"), string.Join('\n', new[] { L("storage.clear.message", Format.Bytes(size)), bin ? L("storage.clear.binWarning") : null }.Where(s => s != null)), L("storage.clear.confirm"), destructive: true)) return;
        var before = _usage?.Total ?? 0;
        var places = Places();
        var keys = _selected.ToHashSet();
        var skipped = await Task.Run(() =>
        {
            var left = new List<string>();
            var recent = DateTime.Now.AddHours(-1);
            void Remove(string p, bool keepRecent)
            {
                try
                {
                    var dir = Directory.Exists(p);
                    if (keepRecent && (dir ? Directory.GetLastWriteTime(p) : File.GetLastWriteTime(p)) > recent) { left.Add($"{p}\n{L("storage.clear.recent")}"); return; }
                    if (dir) Directory.Delete(p, true); else File.Delete(p);
                }
                catch (Exception e) { left.Add($"{p}\n{e.Message}"); }
            }
            foreach (var key in keys.Where(Clearable.Contains))
                foreach (var place in places.GetValueOrDefault(key) ?? [])
                {
                    if (!Directory.Exists(place)) { if (File.Exists(place)) Remove(place, key == "cache"); continue; }
                    if (key == "thumbnails") foreach (var f in Directory.EnumerateFiles(place, "*", SearchOption.AllDirectories)) Remove(f, false);
                    else foreach (var e in Directory.EnumerateFileSystemEntries(place)) Remove(e, key == "cache");
                }
            return left;
        });
        if (bin) { try { await TlCore.Run(TlCore.EmptyTrash); } catch (Exception e) { skipped.Add($"{L("storage.group.bin")}\n{e.Message}"); } await library.Refresh(); }
        await Measure();
        var after = _usage?.Total ?? before;
        await Dialogs.Alert(W, L("storage.clear.done", Format.Bytes(Math.Max(0, before - after))), skipped.Count == 0 ? null : L("storage.clear.skipped") + "\n\n" + string.Join("\n\n", skipped));
    }
}

/// 关于: the app, its version; with the maintenance rows (ten clicks on the icon bring them out):
/// the integrity check, the log, diagnostics.
public sealed partial class AboutSettings(LibraryModel library) : SettingsSubpage
{
    IntegritySummary? _integrity;
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _poll;
    int _taps;
    bool _started;

    public override string Title => L("settings.about");

    async Task LoadIntegrity()
    {
        try { _integrity = await TlCore.Run(TlCore.IntegritySummary); } catch { _integrity = null; }
        var running = _integrity?.Last?.Running ?? false;
        if (running && _poll == null)
        {
            _poll = DispatcherQueue.CreateTimer();
            _poll.Interval = TimeSpan.FromSeconds(1);
            _poll.Tick += (_, _) => _ = LoadIntegrity();
            _poll.Start();
        }
        else if (!running) { _poll?.Stop(); _poll = null; }
        Build();
    }

    static string IntegrityText(IntegritySummary s)
    {
        var last = s.Last;
        if (last == null) return L("verify.never", s.Unchecked) + (s.Bad > 0 ? L("verify.knownBad", s.Bad) : "");
        if (last.Running) return L("verify.checking", last.Checked, last.Total);
        if (last.CompletedAt == 0 || last.Outcome is "interrupted" or "failed" or "cancelled")
            return L("verify.stopped", last.Outcome == "failed" ? L("verify.failed") : L("verify.interrupted"), last.Checked, last.Total);
        if (s.Bad > 0) return L("verify.foundBad", s.Bad, s.Unchecked);
        if (s.Unchecked > 0) return L("verify.newSince", s.Unchecked);
        if (last.Outcome != "succeeded") return L("verify.lastBad", last.Bad);
        return L("verify.lastOK").Trim();
    }

    public override void Build()
    {
        if (!_started) { _started = true; _ = LoadIntegrity(); }
        Clear();
        var icon = new Image { Width = 96, Height = 96, Margin = new Thickness(0, 12, 0, 4) };
        var png = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.png");
        if (File.Exists(png)) icon.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(png));
        var iconButton = new Button { Content = icon, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center };
        iconButton.Click += (_, _) =>
        {
            // ten clicks bring the maintenance rows out (and put them away again)
            if (++_taps < 10) return;
            _taps = 0;
            Prefs.Instance.AboutExtras = !Prefs.Instance.AboutExtras;
            Build();
        };
        Add(iconButton);
        Add(new TextBlock { Text = "TwimShelf", Style = (Style)Application.Current.Resources["TitleTextBlockStyle"], HorizontalAlignment = HorizontalAlignment.Center });
        Add(new TextBlock { Text = L("about.tagline"), HorizontalAlignment = HorizontalAlignment.Center, Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
        Add(new TextBlock { Text = L("about.version", Updates.Display) + $" · {RuntimeInformation.ProcessArchitecture.ToString().ToLowerInvariant()}", HorizontalAlignment = HorizontalAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Margin = new Thickness(0, 4, 0, 12) });
        Action("GitHub", null, "", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri("https://github.com/" + (Updates.Enabled ? Updates.Repo : "XGWYTWGDYU/TwimShelf"))));
        if (!Prefs.Instance.AboutExtras) return;

        Header(L("settings.section.maintenance"));
        var verifying = _integrity?.Last?.Running ?? false;
        Action(verifying ? L("settings.stopCheck") : L("settings.check"), null, verifying ? "" : "", () =>
        {
            if (verifying) TlCore.CancelVerify();
            else { try { TlCore.StartVerify(); } catch { Dialogs.Toast(W, L("settings.checkFailed")); } }
            _ = LoadIntegrity();
        });
        Card(L("settings.integrity"), _integrity == null ? L("settings.checkUnreadable") : IntegrityText(_integrity), "");
        Action(L("about.logs"), null, "", () => _ = ShowLog());
        Action(L("settings.exportDiagnostics"), null, "", () => _ = ExportDiagnostics());
        Footer(L("settings.maintenance.footer"));
    }

    async Task ShowLog()
    {
        var dir = Path.Combine(library.Directory, "logs");
        var text = "";
        foreach (var f in new[] { "diagnostics.log", "windows.log" })
        {
            var p = Path.Combine(dir, f);
            if (File.Exists(p)) { try { using var s = new FileStream(p, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); using var r = new StreamReader(s); text += await r.ReadToEndAsync() + "\n"; } catch { } }
        }
        text = text.Trim();
        if (text.Length > 200_000) text = text[^200_000..];
        await Dialogs.ShowAsync(W, new ContentDialog
        {
            Title = L("about.logs"),
            Content = new ScrollViewer { MaxHeight = 520, Content = new TextBlock { Text = text.Length == 0 ? L("about.logs.empty") : text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 } },
            CloseButtonText = L("common.close"),
        });
    }

    /// 导出诊断信息: errors and numbers only (no pictures, text, tag names or cookies).
    async Task ExportDiagnostics()
    {
        var now = DateTime.Now;
        var out_ = await Pickers.SaveFile(W, L("settings.diagnostics.fileName", now.ToString("yyyy-MM-dd HHmm")), ("ZIP", ".zip"));
        if (out_ == null) return;
        try
        {
            var info = new JsonObject
            {
                ["platform"] = "windows",
                ["os_version"] = Environment.OSVersion.VersionString,
                ["flutter"] = false,
                ["native"] = "winui",
                ["version"] = Updates.Current,
                ["exported_at"] = DateTime.UtcNow.ToString("O"),
                ["prefs"] = new JsonObject { ["auto_tag"] = library.Ai.Models.AutoTag, ["has_tagger"] = library.Ai.Models.ActiveTaggerId != null },
            };
            await Dialogs.Progress(W, L("settings.diagnostics.collecting"), () => TlCore.ExportDiagnostics(out_, info));
            MediaActions.ShowInExplorer(out_);
        }
        catch (Exception e) { Dialogs.Toast(W, e.Message); }
    }

    public override void Closed() { _poll?.Stop(); _poll = null; }
}

/// The data folder (Windows): where everything is kept, and moving it.
public static class DataHomeSettings
{
    public static void Section(SettingsRoot page, LibraryModel library)
    {
        page.Add(new TextBlock { Text = L("datahome.setting"), Style = (Style)Application.Current.Resources["SettingsSectionHeaderTextBlockStyle"] });
        var open = new Button { Content = L("windows.showInExplorer") };
        open.Click += (_, _) => { try { System.Diagnostics.Process.Start("explorer.exe", $"\"{DataHome.Path}\""); } catch { } };
        page.Add(new SettingsCard { Header = DataHome.Path, HeaderIcon = new FontIcon { Glyph = "" }, Content = open });
        var move = new SettingsCard { Header = L("datahome.move"), HeaderIcon = new FontIcon { Glyph = "" }, IsClickEnabled = true };
        move.Click += async (_, _) => await Move(library);
        page.Add(move);
        page.Add(new TextBlock { Text = L("datahome.footer"), TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], Margin = new Thickness(2, 4, 0, 4) });
    }

    /// Moves the data folder; false when it did not (cancelled, refused, failed). On success the
    /// app restarts from the new place.
    public static async Task<bool> Move(LibraryModel library)
    {
        var w = MainWindow.Current!;
        var target = await Pickers.Folder(w);
        if (target == null) return false;
        // never into another library (it would be overwritten) or into the program's folder
        if (DataHome.MoveProblem(target) is { } problem) { await Dialogs.Alert(w, L(problem)); return false; }
        var from = DataHome.Path!;
        var progress = "";
        try
        {
            await library.StopWriting();
            var db = Path.Combine(DataHome.LibraryDir, "library.sqlite");
            await Dialogs.Progress(w, L("datahome.move"), () =>
            {
                DataHome.MoveTo(target, out_ => TlCore.Run(() => TlCore.DbSnapshot(out_)), db, new Progress<(int Done, int Total)>(p => progress = L("datahome.moving", p.Done, p.Total))).GetAwaiter().GetResult();
                return 0;
            }, () => progress);
        }
        catch (Exception e)
        {
            await library.ResumeWriting();
            await Dialogs.Alert(w, L("datahome.moveFailed", e.Message));
            return false;
        }
        var deleteOld = await Dialogs.Choose(w, L("datahome.setting"), L("datahome.moved"), L("datahome.restart"), L("datahome.deleteOld"));
        if (deleteOld == 1) File.WriteAllText(Path.Combine(target, "delete-after-move.json"), new JsonObject { ["path"] = from }.ToJsonString());
        DataHome.Restart();
        return true;
    }

    /// The data folder is inside the program's folder (an older version allowed it; uninstalling
    /// or updating would delete it): nothing else until it has moved, or the app quits.
    public static async Task RequireOutsideProgram(LibraryModel library)
    {
        var w = MainWindow.Current!;
        while (DataHome.InProgramFolder)
        {
            // no 取消: moving or quitting are the only ways on
            var d = new ContentDialog
            {
                Title = L("datahome.mustMove.title"),
                Content = new TextBlock { Text = L("datahome.mustMove.message", DataHome.Path), TextWrapping = TextWrapping.Wrap },
                PrimaryButtonText = L("datahome.move"),
                SecondaryButtonText = L("menu.quit"),
                DefaultButton = ContentDialogButton.Primary,
            };
            var r = await Dialogs.ShowAsync(w, d);
            if (r == ContentDialogResult.Secondary) { App.Quit(); return; }
            if (r == ContentDialogResult.Primary && await Move(library)) return;
        }
    }
}
