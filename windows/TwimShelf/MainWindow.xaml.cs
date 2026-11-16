using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.Controls;
using TwimShelf.Models;
using TwimShelf.Pages;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf;

/// A page shown beside the sidebar: its title and subtitle for the title bar, and its own controls
/// there (as the Mac app puts them in the toolbar).
public interface IShellPage
{
    string Title { get; }
    string Subtitle { get; }
    /// In the middle of the title bar.
    UIElement? TitleContent => null;
    /// At the right of the title bar (zoom, 选择, More …).
    UIElement? Commands => null;
    /// A level below its place (a folder below 文件夹, a settings page): the title bar's Back.
    bool CanGoBack => false;
    void GoBack() { }
    event Action? ChromeChanged;
    /// Shown again (selected in the sidebar) or hidden.
    void Shown() { }
    void Hidden() { }
}

public sealed partial class MainWindow : Window
{
    readonly LibraryModel _library;
    Place _place = Place.Browse;
    readonly BrowsePage _browse;
    IShellPage? _page;
    string _lastSidebarKey = "";
    bool _building;

    public static new MainWindow? Current { get; private set; }

    public MainWindow(LibraryModel library)
    {
        _library = library;
        Current = this;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        // the taskbar's and Alt+Tab's icon; the title bar shows none
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        // made here rather than read back from AppWindow.Presenter: in the AOT build that comes
        // back as the base AppWindowPresenter, and a cast to OverlappedPresenter fails
        _presenter = OverlappedPresenter.Create();
        AppWindow.SetPresenter(_presenter);
        Theming.Apply(this);
        RestoreSize();

        _browse = new BrowsePage(library);
        Activity.Attach(library);
        // the mascot's little Clawd over everything (its home is the bottom-right corner, where the
        // activity panel sits too); it shows itself when the mode is on
        var pet = new PetLayer(ContentHost);
        ContentHost.Children.Add(pet);
        library.Changed += BuildSidebar;
        Prefs.Instance.Changed += BuildSidebar;
        library.RevealRequested += _ => Go(Place.Browse);
        library.FilterRequested += _ => Go(Place.Browse);
        library.Shares.Events += OnShare;
        // files dragged onto the window go to the share page
        DropImport.Attach(this, Root, library);
        BuildSidebar();
        Show(Place.Browse);
        Closed += (_, _) => SaveSize();
        // 开机自启: closing hides the window and TwimShelf goes on in the background (退出 ends it)
        AppWindow.Closing += (_, e) =>
        {
            if (App.Quitting || !LaunchAtLogin.IsOn) return;
            e.Cancel = true;
            SaveSize();
            if (Viewer.IsOpen) Viewer.Shown?.Close();
            InlineVideo.StopAll();
            AppWindow.Hide();
            App.WindowHidden();
            Diagnostics.Log("window hidden: running in the background");
        };
        // nothing moves while hidden (the little Clawd rests)
        VisibilityChanged += (_, e) => pet.SetShown(e.Visible);
        // the system's light or dark, followed as it changes: what the pages drew in code is drawn again
        if (Content is FrameworkElement root)
            root.ActualThemeChanged += (_, _) =>
            {
                Theming.Apply(this);
                BuildSidebar();
                if (_place != Place.Browse) Show(_place);
            };
    }

    /// The title bar moves the window again (after the viewer, which covers it, has closed).
    public void RestoreTitleBar() => SetTitleBar(AppTitleBar);

    // ---- window size --------------------------------------------------------------------------

    readonly OverlappedPresenter _presenter;

    void RestoreSize()
    {
        var w = Prefs.Instance.Raw("windows.window.width") is { } jw ? (int)jw.GetValue<double>() : 1280;
        var h = Prefs.Instance.Raw("windows.window.height") is { } jh ? (int)jh.GetValue<double>() : 820;
        var scale = (Content as FrameworkElement)?.XamlRoot?.RasterizationScale ?? 1;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(Math.Max(w, 640) * scale), (int)(Math.Max(h, 480) * scale)));
        _presenter.PreferredMinimumWidth = 640;
        _presenter.PreferredMinimumHeight = 480;
        // maximized only when shown (Maximize shows the window: 开机自启 starts without it)
        _maximize = Prefs.Instance.Raw("windows.window.maximized") is { } m && m.GetValue<bool>();
    }

    bool _maximize;

    /// Shows the window (the first time as it was left: maximized or not).
    public void Present()
    {
        if (_maximize) { _maximize = false; _presenter.Maximize(); }
        AppWindow.Show();
        Activate();
    }

    void SaveSize()
    {
        Prefs.Instance.Set("windows.window.maximized", _presenter.State == OverlappedPresenterState.Maximized, notify: false);
        if (_presenter.State != OverlappedPresenterState.Restored) return;
        var scale = Root.XamlRoot?.RasterizationScale ?? 1;
        Prefs.Instance.Set("windows.window.width", AppWindow.Size.Width / scale, notify: false);
        Prefs.Instance.Set("windows.window.height", AppWindow.Size.Height / scale, notify: false);
    }

    // ---- sidebar ------------------------------------------------------------------------------

    /// 资料库 (浏览), 媒体类型, 文件夹 (all of them, then each), 其他, 应用 (设置): the Mac sidebar.
    void BuildSidebar()
    {
        var stats = _library.Stats;
        var o = _library.Folders;
        var folders = o?.Folders ?? [];
        var key = string.Join('|', folders.Select(f => $"{f.Name}:{f.Count}")) + $"|{o?.Photos}|{o?.Videos}|{stats?.Bad}|{stats?.Trashed}|{Prefs.Instance.AboutExtras}|{L10n.LanguageTag}|{Clawd.On}|{Theming.IsDark(this)}";
        if (key == _lastSidebarKey) return;
        _lastSidebarKey = key;
        _building = true;
        var items = Nav.MenuItems;
        items.Clear();
        void Header(string text) => items.Add(new NavigationViewItemHeader { Content = text });
        Header(L("sidebar.library"));
        items.Add(Item(Place.Browse, null));
        Header(L("sidebar.mediaTypes"));
        items.Add(Item(Place.Photos, o?.Photos));
        items.Add(Item(Place.Videos, o?.Videos));
        Header(L("place.folders"));
        items.Add(Item(Place.AllFolders, null));
        foreach (var f in folders) items.Add(Item(Place.OfFolder(f.Name), f.Count));
        Header(L("sidebar.other"));
        foreach (var p in Place.Offered)
            items.Add(Item(p, p == Place.Bad ? (stats?.Bad > 0 ? stats.Bad : null) : p == Place.Trash ? (stats?.Trashed > 0 ? stats.Trashed : null) : null));
        // 设置 at the foot of the sidebar, always in view (Windows' place for it; the Mac's 应用 section)
        Nav.FooterMenuItems.Clear();
        Nav.FooterMenuItems.Add(Item(Place.Settings, null));
        // a deleted folder that was open: back to the folders
        if (_place.Folder != null && folders.All(f => f.Name != _place.Folder)) { _building = false; Go(Place.AllFolders); return; }
        Nav.SelectedItem = AllItems().FirstOrDefault(i => (i.Tag as Place) == _place);
        _building = false;
    }

    IEnumerable<NavigationViewItem> AllItems() => Nav.MenuItems.OfType<NavigationViewItem>().Concat(Nav.FooterMenuItems.OfType<NavigationViewItem>());

    NavigationViewItem Item(Place p, long? count)
    {
        var title = new TextBlock { Text = p.Title, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var grid = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        grid.Children.Add(title);
        if (count != null)
        {
            var c = new TextBlock
            {
                Text = count.Value.ToString("N0"),
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(8, 0, 4, 0),
            };
            Grid.SetColumn(c, 1);
            grid.Children.Add(c);
        }
        var item = new NavigationViewItem
        {
            Content = grid,
            Tag = p,
        };
        if (Clawd.On && Clawd.For(p) is { } mascot) item.Icon = Clawd.Icon(mascot);
        else
        {
            // a null brush would hide the glyph: only 损坏或丢失 has a colour of its own
            var icon = new FontIcon { Glyph = p.Glyph };
            if (p == Place.Bad) icon.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"];
            item.Icon = icon;
        }
        ToolTipService.SetToolTip(item, p.Title);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, count == null ? p.Title : L("format.commaJoin", p.Title, count));
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(item, "side-" + p.Id);
        if (p.Folder is { } name)
            item.ContextFlyout = FolderActions.Menu(this, name, onRenamed: n => { if (_place == p) Go(Place.OfFolder(n)); });
        else if (p == Place.AllFolders)
            item.ContextFlyout = FolderActions.NewMenu(this);
        return item;
    }

    void OnNavSelection(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (_building || args.SelectedItem is not NavigationViewItem { Tag: Place p } || p == _place) return;
        Show(p);
    }

    /// The place shown, clicked again: back to its top (设置 from one of its pages, as the Mac app).
    void OnNavInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer is not NavigationViewItem { Tag: Place p } || p != _place) return;
        for (var i = 0; i < 20 && _page?.CanGoBack == true; i++) _page.GoBack();
    }

    void OnPaneToggle(TitleBar sender, object args) => Nav.IsPaneOpen = !Nav.IsPaneOpen;

    void OnBack(TitleBar sender, object args)
    {
        if (_page?.CanGoBack == true) _page.GoBack();
        else if (_place.Folder != null) Go(Place.AllFolders);
    }

    /// Goes somewhere: the sidebar selects it, the content follows.
    public void Go(Place p)
    {
        if (p != _place) Show(p);
        _building = true;
        Nav.SelectedItem = AllItems().FirstOrDefault(i => (i.Tag as Place) == p);
        _building = false;
    }

    /// A page of 设置 by name (the quick download card's 跳转到下载设置).
    public void OpenSettingsPage(string name)
    {
        Go(Place.Settings);
        (_page as SettingsPage)?.Open(name);
    }

    // ---- content ------------------------------------------------------------------------------

    void Show(Place p)
    {
        _place = p;
        if (_page != null)
        {
            _page.ChromeChanged -= RefreshChrome;
            _page.Hidden();
        }
        IShellPage page = p.Id switch
        {
            "browse" => _browse,
            "folders" => new FoldersPage(_library, name => Go(Place.OfFolder(name))),
            "settings" => new SettingsPage(_library),
            _ => new GridPage(_library, p),
        };
        _page = page;
        PageHost.Children.Clear();
        PageHost.Children.Add((UIElement)page);
        page.ChromeChanged += RefreshChrome;
        page.Shown();
        RefreshChrome();
    }

    void RefreshChrome()
    {
        if (_page == null) return;
        AppTitleBar.Title = _page.Title;
        AppTitleBar.Subtitle = _page.Subtitle;
        Title = _page.Title.Length > 0 ? $"{_page.Title} - TwimShelf" : "TwimShelf";
        TitleContent.Content = _page.TitleContent;
        TitleRight.Content = _page.Commands;
        AppTitleBar.IsBackButtonVisible = _page.CanGoBack || _place.Folder != null;
    }

    // ---- shares -------------------------------------------------------------------------------

    Task? _sharePage;
    readonly HashSet<string> _shown = [];

    DateTime _shareFailureShown;

    /// Why shares were not taken in, in words (the inbox's reasons are keys of its own).
    static string ShareReason(string message) => message switch
    {
        "shareInbox.media" => L("shareInbox.reason.notMedia"),
        _ when message.StartsWith("shareInbox.") => L("shareInbox.reason.unreadable"),
        _ => message,
    };

    void OnShare(ShareEvent e)
    {
        switch (e)
        {
            case ShareNeedsChoice c when _shown.Add(c.Id):
                _sharePage = (_sharePage ?? Task.CompletedTask).ContinueWith(_ => DispatcherQueue.TryEnqueue(async () => { if (Visible || await App.ShowWindow()) await ShareDialog.Show(this, _library, c); }), TaskScheduler.Default);
                break;
            // shares that could not be taken in (a file of a kind it can't import, say): said,
            // rather than the window coming forward with nothing (at most every few seconds: they
            // are tried again)
            case ShareInboxFailure f when f.Message != null:
                Diagnostics.Log($"share failed: {f.Pending} ({f.Message})");
                DispatcherQueue.TryEnqueue(async () =>
                {
                    if (DateTime.UtcNow - _shareFailureShown < TimeSpan.FromSeconds(8)) return;
                    _shareFailureShown = DateTime.UtcNow;
                    // forward first: the share came from another app, and a message in a window that
                    // isn't the active one is dismissed at once
                    if (!await App.ShowWindow()) return;
                    await Task.Delay(300);
                    Dialogs.Toast(this, L("shareInbox.failed", f.Pending, ShareReason(f.Message)));
                });
                break;
            case ShareQuickDownload:
                _ = App.ShowWindow();
                Go(Place.Browse);
                _browse.QuickDownload();
                break;
        }
    }

    /// The pending shares that came in before the window was there.
    public void ShowPendingShares()
    {
        List<ShareNeedsChoice> pending;
        lock (_library.Shares.PendingChoices) pending = [.. _library.Shares.PendingChoices];
        foreach (var c in pending) OnShare(c);
    }
}
