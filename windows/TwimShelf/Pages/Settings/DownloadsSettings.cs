// 下载帖子: the running job (pause, resume, cancel, what failed), the download method and folder,
// links pasted one per line, a bookmarks JSON (Twitter Web Exporter) with its concurrency and
// interval, and the account cookies locked accounts need — the other apps' download page.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class DownloadsSettings : SettingsSubpage
{
    readonly LibraryModel _library;
    DownloadService D => _library.Downloads;
    readonly TextBox _links;
    string? _batchPath, _batchName;
    int _batchCount;

    public override string Title => L("common.downloadPosts");

    public DownloadsSettings(LibraryModel library, string initialLinks)
    {
        _library = library;
        _links = new TextBox { Text = initialLinks, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 96, MaxHeight = 220, PlaceholderText = L("settings.links.placeholder") };
        D.Changed += OnChanged;
    }

    readonly Dictionary<string, CookieEditor> _cookieEditors = [];
    readonly HashSet<string> _cookieExpanded = [];
    bool _addingCookie;
    CookieEditor? _newCookieEditor;

    /// The download's progress redraws the page, but never under someone typing in it.
    void OnChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_links.FocusState != FocusState.Unfocused
            || _cookieEditors.Values.Any(e => e.HasFocus)
            || (_newCookieEditor?.HasFocus ?? false)) return;
        Build();
    });
    public override void Closed()
    {
        D.Changed -= OnChanged;
        foreach (var e in _cookieEditors.Values) e.Release();
        _newCookieEditor?.Release();
    }

    async Task Run(Func<Task> action)
    {
        try { await action(); }
        catch (DownloadServiceException e) { Dialogs.Toast(W, L(e.MessageKey)); }
        catch { Dialogs.Toast(W, L("common.couldNotStartDownload")); }
    }

    public override void Build()
    {
        Clear();
        var s = D.Status;
        var phase = D.Phase;
        var busy = phase is DownloadPhase.Running or DownloadPhase.Queued or DownloadPhase.Pausing;
        if (s != null || phase != DownloadPhase.Idle)
        {
            Header(L("settings.downloadStatus"));
            var state = phase switch
            {
                DownloadPhase.Running or DownloadPhase.Queued => L("settings.downloading"),
                DownloadPhase.Paused or DownloadPhase.Pausing => L("download.paused"),
                DownloadPhase.Cancelled or DownloadPhase.Cancelling => L("download.cancelled"),
                DownloadPhase.Failed => L("download.partial"),
                _ => s == null ? L("download.notYet") : L("download.done"),
            };
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            // links waiting with nothing running (it could not start): a way to start them
            // (also after a failure: the queued links stay, and can go again or be dropped)
            var waiting = (phase == DownloadPhase.Queued || (phase == DownloadPhase.Failed && D.Queue.Count > 0)) && s?.Running != true;
            if (waiting)
            {
                busy = false;
                if (phase == DownloadPhase.Queued) state = L("download.notYet");
                buttons.Children.Add(Btn(L("common.download"), () => _ = Run(D.Start), accent: true));
            }
            if (busy) buttons.Children.Add(Btn(L("settings.pause"), () => _ = Run(D.Pause)));
            if (phase == DownloadPhase.Paused) buttons.Children.Add(Btn(L("settings.resume"), () => _ = Run(D.Resume), accent: true));
            if (busy || waiting || phase == DownloadPhase.Paused) buttons.Children.Add(Btn(L("settings.cancelDownload"), () => _ = Run(D.Cancel)));
            var status = Card(state, s == null ? null : L("activity.downloadSummary", s.Done, s.Skipped, s.Failed, s.Total), "", buttons);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(status, "download-status");
            if (busy && s is { Total: > 0 })
                Add(new ProgressBar { Value = 100.0 * (s.Done + s.Skipped + s.Failed) / s.Total, Margin = new Thickness(2, 4, 2, 4) });
            if (D.ErrorKey != null) Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = L(D.ErrorKey) });
            if (D.DamagedQueue != null) Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Message = D.DamagedQueue });
            if (s is { Errors.Count: > 0 })
            {
                var ex = new SettingsExpander { Header = L("settings.viewFailed"), HeaderIcon = Icon("") };
                foreach (var e in s.Errors)
                    ex.Items.Add(new SettingsCard { Header = new TextBlock { Text = e.FirstOrDefault() ?? "", IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap }, Description = e.Count > 1 ? string.Join(" · ", e.Skip(1)) : null });
                Add(ex);
            }
            if (phase == DownloadPhase.Paused) Footer(L("settings.paused.footer"));
        }

        Header(L("settings.section.method"));
        var route = new Segmented { MinWidth = 300 };
        DownloadRoute[] routes = [DownloadRoute.Auto, DownloadRoute.Fx, DownloadRoute.Cookie];
        foreach (var label in new[] { L("common.auto"), L("settings.method.fx"), L("settings.method.cookie") })
            route.Items.Add(new SegmentedItem { Content = label });
        route.SelectedIndex = Array.IndexOf(routes, D.Route);
        // by index: an enum kept in Tag does not come back as itself through WinRT
        route.SelectionChanged += (_, _) => { if (route.SelectedIndex is var i and >= 0 && routes[i] != D.Route) D.Route = routes[i]; };
        Card(L("settings.section.method"), D.Route switch { DownloadRoute.Fx => L("mac.method.fx"), DownloadRoute.Cookie => L("mac.method.cookie"), _ => L("mac.method.auto") }, "", route);
        var folder = new DropDownButton { Content = D.Folder ?? L("common.notIntoFolder") };
        var menu = new MenuFlyout();
        menu.Items.Add(FolderActions.Item(L("common.notIntoFolder"), null, () => { D.Folder = null; Build(); }));
        foreach (var f in _library.Folders?.Folders ?? []) { var n = f.Name; menu.Items.Add(FolderActions.Item(n, "", () => { D.Folder = n; Build(); })); }
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(FolderActions.Item(L("common.newFolderEllipsis"), "", async () => { if (await MediaActions.PickFolder() is { } n) { D.Folder = n; Build(); } }));
        folder.Flyout = menu;
        Card(L("settings.intoFolder"), null, "", folder);
        Footer(L("settings.method.footer"));

        Header(L("common.download"));
        var start = Btn(L("common.download"), async () =>
        {
            var lines = _links.Text.Split((char[])[' ', '\n', '\r', '\t'], StringSplitOptions.RemoveEmptyEntries);
            if (lines.Length == 0) { Dialogs.Toast(W, L("settings.links.empty")); return; }
            await Run(async () => { await D.StartLinks(lines); _links.Text = ""; });
        }, accent: true);
        Add(new SettingsCard { Header = L("mac.links.label"), HeaderIcon = Icon(""), Content = start });
        Detach.From(_links);
        Add(_links);
        Footer(L("settings.links.footer"));

        Header(L("settings.batch"));
        Action(_batchName == null ? L("settings.batch.pick") : L("settings.batch.loaded", _batchName), L("mac.batch.drop.detail"), "", () => _ = PickBatch());
        Card(L("settings.batch.posts"), null, "", new TextBlock { Text = _batchPath == null ? "—" : _batchCount.ToString() });
        Card(L("settings.batch.concurrency"), L("mac.batch.concurrency.detail"), "", Stepper(D.Concurrency.ToString(), D.Concurrency > 1 ? () => { D.Concurrency--; Build(); } : null, D.Concurrency < 16 ? () => { D.Concurrency++; Build(); } : null));
        Card(L("settings.batch.interval"), L("mac.batch.interval.detail"), "", Stepper(L("settings.batch.seconds", D.IntervalMs / 1000.0),
            D.IntervalMs > 0 ? () => { D.IntervalMs = Math.Clamp(D.IntervalMs - 250, 0, 10000); Build(); } : null,
            D.IntervalMs < 10000 ? () => { D.IntervalMs = Math.Clamp(D.IntervalMs + 250, 0, 10000); Build(); } : null));
        var batch = Btn(L("settings.batch.start"), () => _ = StartBatch(), accent: true);
        batch.IsEnabled = _batchCount > 0;
        Card(L("settings.batch.start"), null, "", batch);

        CookieSection();
    }

    static Button Btn(string text, Action click, bool accent = false)
    {
        var b = new Button { Content = text };
        if (accent) b.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        b.Click += (_, _) => click();
        return b;
    }

    static StackPanel Stepper(string value, Action? minus, Action? plus)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        p.Children.Add(new TextBlock { Text = value, VerticalAlignment = VerticalAlignment.Center, MinWidth = 40, TextAlignment = TextAlignment.Right });
        var m = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, IsEnabled = minus != null };
        m.Click += (_, _) => minus?.Invoke();
        var pl = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 }, IsEnabled = plus != null };
        pl.Click += (_, _) => plus?.Invoke();
        p.Children.Add(m);
        p.Children.Add(pl);
        return p;
    }

    async Task PickBatch()
    {
        var path = await Pickers.OpenFile(W, ".json");
        if (path == null) return;
        try
        {
            var urls = await TlCore.Run(() => TlCore.BookmarkUrls(path));
            _batchPath = path;
            _batchName = Path.GetFileName(path);
            _batchCount = urls.Count;
            Build();
        }
        catch { Dialogs.Toast(W, L("settings.links.unrecognized")); }
    }

    async Task StartBatch()
    {
        if (_batchPath is not { } path) return;
        await Run(async () =>
        {
            await D.ImportBookmarks(path);
            await D.Start();
            _batchPath = _batchName = null;
            _batchCount = 0;
            Build();
        });
    }

    /// Multi-account X cookies (all equal, synced across devices), modeled after AiSettings' expandable model/prompt cards.
    void CookieSection()
    {
        Header(L("settings.cookie.header"));
        List<CookieAccount> accounts;
        try { accounts = TlCore.CookiesList(); } catch { accounts = []; }

        if (accounts.Count == 0 && !_addingCookie) Card(L("cookie.noneAdded"), null, "");

        foreach (var acc in accounts)
        {
            var item = acc;
            var title = DisplayName(item);
            var desc = DetailLine(item);
            var ex = new SettingsExpander { Header = title, Description = desc, HeaderIcon = Icon("") };
            ex.IsExpanded = _cookieExpanded.Contains(item.Id);
            ex.Expanded += (_, _) => _cookieExpanded.Add(item.Id);
            ex.Collapsed += (_, _) => _cookieExpanded.Remove(item.Id);

            if (!_cookieEditors.TryGetValue(item.Id, out var editor))
                _cookieEditors[item.Id] = editor = new CookieEditor(item, OnCookieSaved, null);
            var editCard = new SettingsCard { ContentAlignment = ContentAlignment.Vertical, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            editCard.Content = Detach.From(editor);
            Detach.Owned(editCard, editor);
            ex.Items.Add(editCard);

            var del = new SettingsCard { Header = L("common.delete"), HeaderIcon = Icon(""), IsClickEnabled = true };
            del.Click += async (_, _) =>
            {
                if (!await Dialogs.Confirm(W, L("cookie.delete.title", title), L("cookie.delete.message"), L("common.delete"), destructive: true)) return;
                try
                {
                    TlCore.CookieDelete(item.Id);
                    _cookieExpanded.Remove(item.Id);
                    _cookieEditors.Remove(item.Id);
                    Build();
                }
                catch (Exception e) { Dialogs.Toast(W, e.Message); }
            };
            ex.Items.Add(del);
            Add(ex);
        }

        if (_addingCookie)
        {
            _newCookieEditor ??= new CookieEditor(null, saved =>
            {
                _addingCookie = false;
                _newCookieEditor?.Release();
                _newCookieEditor = null;
                _cookieExpanded.Add(saved.Id);
                OnCookieSaved(saved);
            }, () =>
            {
                _addingCookie = false;
                _newCookieEditor?.Release();
                _newCookieEditor = null;
                Build();
            });
            var addCard = new SettingsCard
            {
                Header = L("cookie.add"),
                HeaderIcon = Icon(""),
                ContentAlignment = ContentAlignment.Vertical,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            };
            addCard.Content = Detach.From(_newCookieEditor);
            Detach.Owned(addCard, _newCookieEditor);
            Add(addCard);
        }
        else
        {
            Action(L("cookie.add"), null, "", () =>
            {
                _newCookieEditor = null;
                _addingCookie = true;
                Build();
            });
        }
        Footer(L("cookie.multi.footer"));
    }

    void OnCookieSaved(CookieAccount saved)
    {
        _cookieEditors.Remove(saved.Id);
        Build();
    }

    static string DisplayName(CookieAccount a)
    {
        if (!string.IsNullOrWhiteSpace(a.Label)) return a.Label;
        if (!string.IsNullOrWhiteSpace(a.ScreenName)) return "@" + a.ScreenName;
        return L("cookie.unnamed");
    }

    static string DetailLine(CookieAccount a)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(a.ScreenName) && !string.IsNullOrWhiteSpace(a.Label))
            parts.Add("@" + a.ScreenName);
        parts.Add(a.AuthToken.Length > 4 ? "••••" + a.AuthToken[^4..] : "••••");
        return string.Join(" · ", parts);
    }

    sealed partial class CookieEditor : StackPanel
    {
        readonly CookieAccount? _account;
        readonly TextBox _label;
        readonly TextBox _auth;
        readonly TextBox _ct0;
        string? _screenName;

        public bool HasFocus => _label.FocusState != FocusState.Unfocused
            || _auth.FocusState != FocusState.Unfocused
            || _ct0.FocusState != FocusState.Unfocused;

        public CookieEditor(CookieAccount? account, Action<CookieAccount> onSaved, Action? onCancel)
        {
            _account = account;
            _screenName = account?.ScreenName;
            Spacing = 10;
            _label = new TextBox { Header = L("cookie.label"), Text = account?.Label ?? "" };
            _auth = new TextBox { Header = "auth_token", Text = account?.AuthToken ?? "", FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas") };
            _ct0 = new TextBox { Header = "ct0", Text = account?.Ct0 ?? "", FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas") };
            Children.Add(_label);
            Children.Add(_auth);
            Children.Add(_ct0);

            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right };
            if (onCancel != null)
            {
                var cancel = new Button { Content = L("common.cancel") };
                cancel.Click += (_, _) => onCancel();
                buttons.Children.Add(cancel);
            }
            var check = new Button { Content = L("settings.cookie.check") };
            check.Click += async (_, _) =>
            {
                var a = _auth.Text.Trim();
                var c = _ct0.Text.Trim();
                if (a.Length == 0 || c.Length == 0) { Dialogs.Toast(W, L("cookie.fillBoth")); return; }
                var r = await Dialogs.Progress(W, L("settings.cookie.checking"), () => TlCore.CheckCookies(a, c));
                if (r.Error == null && !string.IsNullOrWhiteSpace(r.ScreenName))
                {
                    _screenName = r.ScreenName;
                    if (_account != null)
                    {
                        try { onSaved(TlCore.CookieSave(_account.Id, _label.Text, a, c, _screenName)); } catch { }
                    }
                }
                await Dialogs.Alert(W, r.Error == null ? "@" + (r.ScreenName ?? "") : L("cookie.invalid"), r.Error ?? r.Name);
            };
            var save = new Button { Content = L("common.save"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            save.Click += (_, _) =>
            {
                var a = _auth.Text.Trim();
                var c = _ct0.Text.Trim();
                if (a.Length == 0 || c.Length == 0) { Dialogs.Toast(W, L("cookie.fillBoth")); return; }
                try
                {
                    var saved = TlCore.CookieSave(_account?.Id, _label.Text, a, c, _screenName);
                    Dialogs.Toast(W, L("settings.cookie.saved"));
                    onSaved(saved);
                }
                catch (Exception e) { Dialogs.Toast(W, e.Message); }
            };
            buttons.Children.Add(check);
            buttons.Children.Add(save);
            Children.Add(buttons);
        }

        public void Release() => Detach.From(this);
    }
}
