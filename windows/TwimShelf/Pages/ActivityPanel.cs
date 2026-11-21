// What runs in the background (downloads, model downloads, AI tagging, sync, imports, the integrity
// check), as cards floating over every page at the bottom right (as the other apps show it), out of
// the way while the viewer is open. A card stays at least two seconds, so it can always be read,
// and shows its real outcome once the work has ended.
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.AI;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public enum ActivityKind { Download, Model, Tagging, Sync, Verify, Importing }

public sealed record Activity(ActivityKind Kind, string Title, string Detail, double? Progress = null, string? PreviewPath = null, bool PreviewIsVideo = false)
{
    /// A stopped worker is no proof of success: only an explicit success fills the bar.
    public Activity Ended(string outcome, string? detail = null, double? progress = null)
    {
        var prefix = outcome switch
        {
            "succeeded" => L("activity.done"),
            "partial" => L("activity.partial"),
            "failed" => L("activity.failed"),
            "cancelled" => L("models.cancelled"),
            "paused" => L("activity.paused"),
            _ => L("activity.stopped"),
        };
        return this with { Title = $"{prefix} · {Title.Replace(L("activity.running"), "")}", Detail = detail ?? Detail, Progress = outcome == "succeeded" ? 1 : progress ?? Progress };
    }
}

public sealed partial class ActivityPanel : UserControl
{
    LibraryModel? _library;
    readonly StackPanel _cards = new() { Spacing = 10 };
    readonly Border _panel;
    ImportProgress? _import;
    VerifyStatus? _verify;
    bool _polling;
    List<Activity> _shown = [];
    readonly Dictionary<ActivityKind, DateTime> _since = [], _until = [];
    readonly Dictionary<ActivityKind, Activity> _last = [];
    Microsoft.UI.Dispatching.DispatcherQueueTimer? _poll, _expire;

    public ActivityPanel()
    {
        _panel = new Border
        {
            Width = 340,
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(8),
            Background = (Brush)Application.Current.Resources["AcrylicInAppFillColorDefaultBrush"],
            BorderBrush = (Brush)Application.Current.Resources["SurfaceStrokeColorFlyoutBrush"],
            BorderThickness = new Thickness(1),
            Shadow = new ThemeShadow(),
            Translation = new System.Numerics.Vector3(0, 0, 24),
            Child = _cards,
            Visibility = Visibility.Collapsed,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(_panel, "activityPanel");
        Content = _panel;
        IsHitTestVisible = false;
    }

    public void Attach(LibraryModel library)
    {
        _library = library;
        library.Ai.Tagger.Changed += Rebuild;
        library.Sync.Changed += Rebuild;
        LocalModels.Instance.Changed += Rebuild;
        library.Changed += () => { if (library.Downloads != null) { library.Downloads.Changed -= Rebuild; library.Downloads.Changed += Rebuild; } };
        if (library.Downloads != null) library.Downloads.Changed += Rebuild;
        Viewer.Opened += Rebuild;
        Viewer.Closed += Rebuild;
        _poll = DispatcherQueue.CreateTimer();
        _poll.Interval = TimeSpan.FromSeconds(1);
        _poll.Tick += (_, _) => _ = PollCore();
        _poll.Start();
    }

    async Task PollCore()
    {
        if (_polling) return;
        _polling = true;
        try
        {
            (_import, _verify) = await TlCore.Run(() => (TlCore.ImportStatus(), TlCore.VerifyStatus()));
            Rebuild();
        }
        catch { }
        finally { _polling = false; }
    }

    static bool IsVideoPath(string p) => p.EndsWith(".mp4", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".mov", StringComparison.OrdinalIgnoreCase) || p.EndsWith(".m4v", StringComparison.OrdinalIgnoreCase);

    List<Activity> Running()
    {
        var list = new List<Activity>();
        var lib = _library!;
        if (lib.Downloads?.Status is { Running: true } d)
        {
            var recent = d.Recent.Count == 0 ? null : d.Recent[^1];
            var handled = d.Done + d.Skipped + d.Failed;
            list.Add(new(ActivityKind.Download, L("activity.downloadingPosts"),
                $"{handled} / {d.Total}" + (d.Failed > 0 ? L("settings.failedSuffix", d.Failed) : "") + (d.Active.Count == 0 ? "" : L("activity.activeSuffix", d.Active.Count)),
                d.Total > 0 ? (double)handled / d.Total : null, recent, recent != null && IsVideoPath(recent)));
        }
        if (LocalModels.Instance.Download is { Running: true } m)
            list.Add(new(ActivityKind.Model, L("activity.downloadingModel", m.Repo.Split('/')[^1]), $"{Format.Bytes(m.DoneBytes)} / {Format.Bytes(m.TotalBytes)}",
                m.TotalBytes > 0 && !m.Verifying ? (double)m.DoneBytes / m.TotalBytes : null));
        var t = lib.Ai.Tagger;
        if (t.Running && !t.Paused)
            list.Add(new(ActivityKind.Tagging, t.Title, $"{t.Done} / {Math.Max(t.Total, t.Done)}", t.Total > 0 ? (double)t.Done / t.Total : null, t.CurrentPath, t.CurrentKind == "video"));
        if (lib.Sync.Status is { Syncing: > 0 } s)
        {
            if (s.Receiving is { Total: > 0 } r)
            {
                var inFlight = r.CurrentSize > 0 ? (double)r.CurrentDone / r.CurrentSize : 0;
                var detail = L("activity.filesLeft", Math.Max(0, r.Total - r.Received));
                if (r.TotalBytes > 0)
                {
                    detail += " · " + Format.Bytes(Math.Max(0, r.TotalBytes - r.Bytes));
                    detail += L("activity.received", r.Received, r.Total, Format.Bytes(r.Bytes), Format.Bytes(r.TotalBytes));
                }
                else detail += L("activity.receivedShort", r.Received, r.Total, Format.Bytes(r.Bytes));
                if (r.CurrentSize > 8_000_000) detail += L("activity.currentFile", (int)Math.Round(inFlight * 100));
                list.Add(new(ActivityKind.Sync, L("activity.receiving"), detail, Math.Clamp(r.TotalBytes > 0 ? (double)r.Bytes / r.TotalBytes : (r.Received + inFlight) / r.Total, 0, 1)));
            }
            else list.Add(new(ActivityKind.Sync, L("activity.syncing"), L("activity.syncDetail")));
        }
        if (_import is { Running: true } i)
            list.Add(new(ActivityKind.Importing, i.Waiting ? L("activity.importWaiting") : L("activity.importing"),
                L("activity.importProgress", i.FoldersDone, i.FoldersTotal, i.FilesDone) + (i.Issues > 0 ? L("activity.importIssues", i.Issues) : ""),
                i.FoldersTotal > 0 ? (double)i.FoldersDone / i.FoldersTotal : null, i.Current, i.Current != null && IsVideoPath(i.Current)));
        if (_verify is { Running: true } v)
            list.Add(new(ActivityKind.Verify, L("activity.verifying"), $"{v.Checked} / {v.Total} · {Format.Bytes(v.Bytes)}" + (v.Bad > 0 ? L("activity.foundBad", v.Bad) : ""),
                v.Total > 0 ? (double)v.Checked / v.Total : null, v.Current, v.Current != null && IsVideoPath(v.Current)));
        return list;
    }

    void Rebuild()
    {
        if (_library == null) return;
        var now = DateTime.Now;
        var running = Running();
        var o = running.ToList();
        var live = running.Select(a => a.Kind).ToHashSet();
        foreach (var a in running)
        {
            if (!_since.ContainsKey(a.Kind) || _until.ContainsKey(a.Kind)) _since[a.Kind] = now;
            _until.Remove(a.Kind);
            _last[a.Kind] = a;
        }
        foreach (var kind in _last.Keys.ToList())
        {
            if (live.Contains(kind)) continue;
            if (!_until.ContainsKey(kind))
            {
                var hold = _since.GetValueOrDefault(kind, now) + TimeSpan.FromSeconds(2);
                var moment = now + TimeSpan.FromMilliseconds(1200);
                _until[kind] = hold > moment ? hold : moment;
            }
            if (now < _until[kind]) o.Add(Completed(_last[kind]));
            else { _last.Remove(kind); _until.Remove(kind); _since.Remove(kind); }
        }
        _expire?.Stop();
        if (_until.Count > 0)
        {
            _expire ??= DispatcherQueue.CreateTimer();
            _expire.IsRepeating = false;
            _expire.Interval = (_until.Values.Min() - now) + TimeSpan.FromMilliseconds(20);
            _expire.Tick -= OnExpire;
            _expire.Tick += OnExpire;
            _expire.Start();
        }
        if (Viewer.IsOpen) o = [];
        if (o.SequenceEqual(_shown)) return;
        _shown = o;
        Draw();
    }

    void OnExpire(Microsoft.UI.Dispatching.DispatcherQueueTimer s, object e) => Rebuild();

    Activity Completed(Activity last)
    {
        var lib = _library!;
        switch (last.Kind)
        {
            case ActivityKind.Download:
                var d = lib.Downloads?.Status;
                if (d == null) return last.Ended("stopped");
                return last.Ended(lib.Downloads!.Phase == DownloadPhase.Paused ? "paused" : d.Outcome, L("activity.downloadSummary", d.Done, d.Skipped, d.Failed, d.Total),
                    d.Total > 0 ? (double)(d.Done + d.Skipped + d.Failed) / d.Total : null);
            case ActivityKind.Model:
                var m = LocalModels.Instance.Download;
                if (m == null) return last.Ended("stopped");
                return last.Ended(m.Finished ? "succeeded" : m.Error == L("models.cancelled") ? "cancelled" : "failed", m.Error, m.TotalBytes > 0 ? (double)m.DoneBytes / m.TotalBytes : null);
            case ActivityKind.Tagging:
                var t = lib.Ai.Tagger;
                return last.Ended(t.Paused ? "paused" : t.Outcome, $"{t.Done} / {t.Total}", t.Total > 0 ? (double)t.Done / t.Total : null);
            case ActivityKind.Importing:
                if (_import is not { } i) return last.Ended("stopped");
                return last.Ended(i.Outcome, L("activity.importSummary", i.FoldersDone, i.FoldersTotal, i.FilesDone, i.Issues), i.FoldersTotal > 0 ? (double)i.FoldersDone / i.FoldersTotal : null);
            case ActivityKind.Verify:
                if (_verify is not { } v) return last.Ended("stopped");
                return last.Ended(v.Outcome, L("activity.verifySummary", v.Checked, v.Total, v.Bad), v.Total > 0 ? (double)v.Checked / v.Total : null);
            default:
                // no overall success signal for a sync session: its state
                return new(ActivityKind.Sync, SyncState(), L("activity.syncSeePage"));
        }
    }

    string SyncState()
    {
        var s = _library!.Sync.Status;
        if (s == null) return L("sync.state.reading");
        if (s.Failed.Count > 0 || s.Peers.Any(p => p.LastError != null)) return L("sync.state.failed");
        var last = s.Peers.Select(p => p.LastSync).DefaultIfEmpty(0).Max();
        if (last > 0) return L("sync.state.lastOK") + DateTimeOffset.FromUnixTimeSeconds(last).LocalDateTime.ToString("HH:mm");
        return L("sync.state.waiting");
    }

    static string Glyph(ActivityKind k) => k switch
    {
        ActivityKind.Download => "",
        ActivityKind.Model => "",
        ActivityKind.Tagging => "",
        ActivityKind.Sync => "",
        ActivityKind.Verify => "",
        _ => "",
    };

    void Draw()
    {
        _cards.Children.Clear();
        _panel.Visibility = _shown.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        foreach (var a in _shown)
        {
            // the icon on the card itself (no tile behind it); a preview fills the square
            var picture = new Border { Width = 46, Height = 46, CornerRadius = new CornerRadius(6) };
            if (a.PreviewPath != null && !a.PreviewIsVideo)
                picture.Child = new Image { Stretch = Stretch.UniformToFill, Source = new BitmapImage { DecodePixelWidth = 140, UriSource = new Uri(a.PreviewPath) } };
            else
                picture.Child = a.Kind == ActivityKind.Sync
                    ? new ProgressRing { IsActive = true, Width = 24, Height = 24 }
                    : new FontIcon { Glyph = Glyph(a.Kind), FontSize = 22 };
            var bar = new ProgressBar { IsIndeterminate = a.Progress == null, Value = (a.Progress ?? 0) * 100, Maximum = 100, Margin = new Thickness(0, 7, 0, 0) };
            var text = new StackPanel
            {
                Children =
                {
                    new TextBlock { Text = a.Title, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 },
                    new TextBlock { Text = a.Detail, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], TextWrapping = TextWrapping.Wrap, MaxLines = 2, TextTrimming = TextTrimming.CharacterEllipsis },
                    bar,
                },
            };
            var row = new Grid { ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() } };
            row.Children.Add(picture);
            text.Margin = new Thickness(12, 0, 0, 0);
            Grid.SetColumn(text, 1);
            row.Children.Add(text);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(row, "activity-" + a.Kind.ToString().ToLowerInvariant());
            _cards.Children.Add(row);
        }
    }
}
