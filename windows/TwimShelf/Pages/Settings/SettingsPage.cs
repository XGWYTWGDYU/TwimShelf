// 设置, shown beside the sidebar as the Mac app shows it, drawn as Windows Settings is: sections of
// setting cards, a card with a chevron opening its page (the title bar's Back returns). The same
// settings as the other apps.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.AI;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

/// A page of 设置 (the root or one opened from it).
public abstract partial class SettingsSubpage : UserControl
{
    public abstract string Title { get; }
    protected StackPanel Body { get; } = new() { Spacing = 4, Margin = new Thickness(36, 8, 36, 36) };

    /// What holds Body (kept here: Parent is not reliable under AOT).
    readonly Grid _column = new();

    /// Takes Body out of the page's own scrolling column, for a page that lays itself out.
    protected StackPanel TakeBody() { _column.Children.Remove(Body); return Body; }
    public SettingsPage? Host { get; set; }
    public event Action? Changed;
    protected void NotifyChanged() => Changed?.Invoke();

    protected SettingsSubpage()
    {
        // at most 1000 wide, from the left edge with the breadcrumb (as Windows Settings): the page
        // follows the sidebar when it folds, rather than staying centred
        var column = _column;
        column.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = 1072 });
        column.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        column.Children.Add(Body);
        Content = new ScrollViewer { Content = column, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    /// Built (again) when shown; the page reads what it shows fresh each time.
    public abstract void Build();
    public virtual void Closed() { }

    protected void Clear() => Body.Children.Clear();
    protected void Header(string text) => Body.Children.Add(new TextBlock { Text = text, Style = (Style)Application.Current.Resources["SettingsSectionHeaderTextBlockStyle"] });
    protected void Footer(string text) => Body.Children.Add(new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"], Margin = new Thickness(2, 4, 0, 4) });
    internal T Add<T>(T e) where T : UIElement { Body.Children.Add(e); return e; }

    public static FontIcon Icon(string glyph) => new() { Glyph = glyph };

    /// In place of a glyph: AI tagging's four-pointed star (the AI tags' mark), drawn.
    public const string Sparkle = "sparkle";

    protected SettingsCard Card(string header, string? description = null, string? glyph = null, object? content = null)
    {
        var c = new SettingsCard { Header = header, Description = description, Content = content };
        if (glyph != null) c.HeaderIcon = glyph == Sparkle ? Controls.TagStyle.MenuIconSparkle() : Icon(glyph);
        return Add(c);
    }

    /// A card that opens a page.
    protected SettingsCard Nav(string header, string? description, string glyph, Func<SettingsSubpage> page, string? id = null)
    {
        var c = Card(header, description, glyph);
        c.IsClickEnabled = true;
        c.ActionIcon = new FontIcon { Glyph = "" };
        c.Click += (_, _) =>
        {
            try { Host?.Push(page()); }
            catch (Exception e) { Services.Diagnostics.Log("settings page: " + e); Dialogs.Toast(W, e.Message); }
        };
        if (id != null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(c, id);
        return c;
    }

    /// A card that does something when clicked.
    protected SettingsCard Action(string header, string? description, string glyph, Action click, bool danger = false)
    {
        var c = Card(header, description, glyph);
        c.IsClickEnabled = true;
        c.Click += (_, _) => click();
        if (danger) c.Foreground = (Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
        return c;
    }

    protected ToggleSwitch Switch(string header, string? description, string? glyph, bool on, Action<bool> changed)
    {
        var t = new ToggleSwitch { IsOn = on };
        t.Toggled += (_, _) => changed(t.IsOn);
        Card(header, description, glyph, t);
        return t;
    }

    protected ComboBox Choice<T>(string header, string? description, string? glyph, IReadOnlyList<(T Value, string Label)> items, T value, Action<T> changed)
    {
        var box = new ComboBox { MinWidth = 160 };
        foreach (var (_, label) in items) box.Items.Add(new ComboBoxItem { Content = label });
        box.SelectedIndex = Math.Max(0, items.ToList().FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, value)));
        // by index into items: a value type kept in Tag does not come back as itself through WinRT
        box.SelectionChanged += (_, _) => { if (box.SelectedIndex is var i and >= 0 && i < items.Count) changed(items[i].Value); };
        Card(header, description, glyph, box);
        return box;
    }

    protected static Window W => MainWindow.Current!;
}

public sealed partial class SettingsPage : UserControl, IShellPage
{
    readonly LibraryModel _library;
    readonly Stack<SettingsSubpage> _stack = new();
    readonly Grid _host = new();
    readonly BreadcrumbBar _crumbs = new() { Margin = new Thickness(36, 16, 36, 4) };

    public event Action? ChromeChanged;
    public string Title => L("place.settings");
    public string Subtitle => "";
    public bool CanGoBack => _stack.Count > 1;
    public void GoBack() => Pop();

    public SettingsPage(LibraryModel library)
    {
        _library = library;
        var grid = new Grid { RowDefinitions = { new RowDefinition { Height = GridLength.Auto }, new RowDefinition() } };
        grid.Children.Add(_crumbs);
        Grid.SetRow(_host, 1);
        grid.Children.Add(_host);
        Content = grid;
        _crumbs.ItemClicked += (_, e) => { while (_stack.Count > e.Index + 1) Pop(); };
        Push(new SettingsRoot(library));
    }

    public void Push(SettingsSubpage page)
    {
        if (_stack.TryPeek(out var top)) top.Visibility = Visibility.Collapsed;
        page.Host = this;
        page.Changed += () => { if (_stack.TryPeek(out var t) && t == page) page.Build(); };
        _stack.Push(page);
        _host.Children.Add(page);
        page.Build();
        Crumbs();
    }

    public void Pop()
    {
        if (_stack.Count <= 1) return;
        var page = _stack.Pop();
        page.Closed();
        _host.Children.Remove(page);
        var top = _stack.Peek();
        top.Visibility = Visibility.Visible;
        top.Build();
        Crumbs();
    }

    /// Opens one of the pages by name (the quick download card's 跳转到下载设置, or browser extension update jump).
    public void Open(string name)
    {
        while (_stack.Count > 1) Pop();
        if (name == "downloads") Push(new DownloadsSettings(_library, QuickDownload.TakeDraft()));
        else if (name == "extension") Push(new ExtensionSettings(_library));
        else if (name == "extension-update") Push(new ExtensionSettings(_library, autoCheckUpdate: true));
    }

    void Crumbs()
    {
        var items = new List<string>();
        foreach (var p in _stack.Reverse()) items.Add(p.Title);
        _crumbs.ItemsSource = items;
        ChromeChanged?.Invoke();
    }

    public void Shown()
    {
        if (_stack.TryPeek(out var top)) top.Build();
        ChromeChanged?.Invoke();
    }

    public void Hidden() { }

    public void Close()
    {
        foreach (var p in _stack) p.Closed();
    }
}

/// The root: the library's counts, then 内容, 外观, 浏览与播放, 卡片, 应用锁, 智能与同步, the data
/// folder, 检查更新, 存储空间 and 关于, and 清除所有数据 last — the other apps' order.
public sealed partial class SettingsRoot(LibraryModel library) : SettingsSubpage
{
    public override string Title => L("place.settings");

    // the four figures, kept so they follow the library while the page is open (sync, downloads)
    readonly List<(TextBlock Text, Func<LibraryStats, long> Value)> _figures = [];
    bool _watching;

    void ShowFigures()
    {
        if (library.Stats is not { } s) return;
        foreach (var (text, value) in _figures) text.Text = value(s).ToString("N0");
    }

    public override void Closed()
    {
        if (_watching) library.Changed -= ShowFigures;
        _watching = false;
    }

    public override void Build()
    {
        Clear();
        _figures.Clear();
        if (!_watching) { library.Changed += ShowFigures; _watching = true; }
        var s = library.Stats;
        var prefs = Prefs.Instance;
        if (library.Sync.Status is { Syncing: > 0 })
            Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = L("activity.syncing"), Message = L("activity.syncDetail") });
        if (s != null)
        {
            // one wide card, the four figures side by side with a line between them
            var row = new Grid();
            (Func<LibraryStats, long>, string, string)[] cells = [(x => x.Posts, L("common.posts"), ""), (x => x.Photos, L("search.kw.photo.word"), ""), (x => x.Videos, L("place.videos"), ""), (x => x.Tags, L("common.tags"), "")];
            for (var i = 0; i < cells.Length; i++)
            {
                if (i > 0)
                {
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var line = new Border { Width = 1, Margin = new Thickness(0, 4, 0, 4), Background = (Brush)Application.Current.Resources["DividerStrokeColorDefaultBrush"] };
                    Grid.SetColumn(line, row.ColumnDefinitions.Count - 1);
                    row.Children.Add(line);
                }
                row.ColumnDefinitions.Add(new ColumnDefinition());
                var (value, label, glyph) = cells[i];
                var figure = new TextBlock { Text = value(s).ToString("N0"), Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"] };
                _figures.Add((figure, value));
                var cell = new StackPanel
                {
                    Spacing = 2,
                    Padding = new Thickness(i == 0 ? 0 : 20, 0, 12, 0),
                    Children =
                    {
                        new FontIcon { Glyph = glyph, FontSize = 16, HorizontalAlignment = HorizontalAlignment.Left, Foreground = (Brush)Application.Current.Resources["AccentTextFillColorPrimaryBrush"] },
                        figure,
                        new TextBlock { Text = label, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] },
                    },
                };
                Grid.SetColumn(cell, row.ColumnDefinitions.Count - 1);
                row.Children.Add(cell);
            }
            var stats = new Border
            {
                Padding = new Thickness(20, 14, 20, 14), CornerRadius = new CornerRadius(4), Margin = new Thickness(0, 4, 0, 0),
                Background = (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],
                BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1),
                Child = row,
            };
            Header(L("common.library"));
            Add(stats);
        }

        Header(L("settings.section.content"));
        var downloads = Nav(L("common.downloadPosts"), library.Downloads.Phase == DownloadPhase.Running ? L("settings.downloading") : null, "", () => new DownloadsSettings(library, ""), "settings-downloads");
        // the mascot mode: the crab with its bag while posts download
        if (Clawd.On && library.Downloads.Phase == DownloadPhase.Running) downloads.HeaderIcon = Clawd.Icon("bag", 24);
        Nav(L("common.importAndBackup"), null, "", () => new TransferSettings(library));
        Nav(L("common.tags"), null, "", () => new TagsSettings(library), "settings-tags");

        Header(L("appearance.title"));
        // one number of cards (a window has no orientation): both of the other apps' settings at once
        (int, string)[] density = [(0, L("cards.fewer")), (1, L("cards.medium")), (2, L("cards.more"))];
        Choice(L("cards.section"), L("cards.footer"), "", density, prefs.DensityLandscape, v => { prefs.DensityLandscape = v; prefs.DensityPortrait = v; });

        Header(L("mascot.title"));
        var mascot = new ToggleSwitch { IsOn = prefs.Mascot };
        mascot.Toggled += (_, _) => prefs.Mascot = mascot.IsOn;
        Add(new SettingsCard { Header = L("mascot.toggle"), HeaderIcon = Clawd.Icon("settings", 30), Content = mascot });
        Action(L("mascot.licenses"), null, "\uE8A5", () => _ = Dialogs.Alert(W, L("mascot.licenses"), Clawd.License));
        Footer(L("mascot.footer"));

        Header(L("applock.section"));
        var lockSwitch = Switch(L("applock.toggle", L("applock.method.hello")), null, "", prefs.AppLock, async v =>
        {
            if (v && !await AppLock.Available()) { prefs.AppLock = false; Build(); await Dialogs.Alert(W, L("applock.unavailable")); return; }
            // turning it on is confirmed with Windows Hello itself, as turning it off
            if (!await AppLock.Unlock(W)) { Build(); return; }
            prefs.AppLock = v;
        });

        Header(L("settings.section.smart"));
        var tagger = library.Ai.Models.ActiveTaggerId;
        var tagging = Nav(L("models.tagging"), tagger == null ? L("models.external") : library.Ai.Models.Find(tagger)?.Title ?? (LocalModels.Instance.Find(tagger) is { } m ? LocalModels.Instance.Title(m) : L("models.external")),
            Sparkle, () => new AiSettings(library), "settings-ai");
        // the mascot mode: the crab with its camera while it tags
        if (Clawd.On && library.Ai.Tagger.Running) tagging.HeaderIcon = Clawd.Icon("camera", 24);
        Nav(L("common.lanSync"), library.Sync.Joined ? L("sync.state.on") : L("sync.state.notJoined"), "", () => new SyncSettings(library), "settings-sync");
        Nav(L("ext.title"), ExtensionSettings.Summary(), "", () => new ExtensionSettings(library), "settings-extension");

        if (DataHome.Path != null) DataHomeSettings.Section(this, library);

        if (Updates.Enabled)
        {
            Header(L("update.check"));
            Action(L("update.check"), L("update.footer"), "", () => _ = Updates.CheckNow(W));
        }

        Header(L("sidebar.app"));
        // 开机自启 (this computer's): then closing the window leaves TwimShelf running, and 退出 ends it
        Switch(L("settings.launchAtLogin"), L("settings.launchAtLogin.footer"), "\uE7E8", LaunchAtLogin.IsOn, v =>
        {
            try { LaunchAtLogin.Set(v); }
            catch (Exception e) { Diagnostics.Log("launch at login: " + e.Message); Dialogs.Toast(W, e.Message); }
            Build();
        });
        if (LaunchAtLogin.IsOn) Action(L("menu.quit"), null, "\uE8BB", App.Quit).IsActionIconVisible = false;
        Nav(L("storage.title"), null, "", () => new StorageSettings(library), "settings-storage");
        Nav(L("settings.about"), null, "", () => new AboutSettings(library), "settings-about");

        // set apart (no heading of its own, as the other apps)
        Action(L("settings.wipe.button"), L("settings.wipe.footer"), "", () => _ = Wipe(library), danger: true).Margin = new Thickness(0, 30, 0, 0);
    }

    /// 清除所有数据, as the other apps: typed to confirm; the AI models stay unless chosen.
    internal static async Task Wipe(LibraryModel library)
    {
        var word = L("settings.wipe.word");
        var box = new TextBox { PlaceholderText = word };
        var models = new CheckBox { Content = L("settings.wipe.withModels") };
        var message = new TextBlock { Text = L("settings.wipe.message"), TextWrapping = TextWrapping.Wrap };
        models.Click += (_, _) => message.Text = L("settings.wipe.message") + (models.IsChecked == true ? L("settings.wipe.modelsToo") : "");
        var d = new ContentDialog
        {
            Title = L("settings.wipe.title"),
            Content = new StackPanel { Spacing = 12, Width = 420, Children = { message, new TextBlock { Text = L("settings.wipe.typeToConfirm", word), TextWrapping = TextWrapping.Wrap }, box, models } },
            PrimaryButtonText = L("settings.wipe.confirm"),
            CloseButtonText = L("common.cancel"),
            DefaultButton = ContentDialogButton.Close,
            IsPrimaryButtonEnabled = false,
        };
        box.TextChanged += (_, _) => d.IsPrimaryButtonEnabled = box.Text.Trim() == word;
        if (await Dialogs.ShowAsync(W, d) != ContentDialogResult.Primary) return;
        var problems = await library.WipeEverything(models.IsChecked == true);
        await Dialogs.Alert(W, L("settings.wipe.doneMessage"), problems.Count == 0 ? null : string.Join('\n', problems));
    }
}
