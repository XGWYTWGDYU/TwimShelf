// The setup and the uninstaller, in Fluent: one small Mica window with every step laid out the same
// way — what and which version at the top, one card with what this step is about, the actions at
// the bottom right. As the Flutter setup: install (fresh, upgrade, the same version again, an older
// one), uninstall (keeping the data folder unless asked), and --update: the app updating itself,
// over the installed copy without asking, then the new version starts.
//   TwimShelf.exe --setup <payload folder> [--update]   (the setup.exe stub passes these)
//   TwimShelf.exe --uninstall                            (Settings › Apps runs this)
using System.Diagnostics;
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwimShelf.Controls;
using static TwimShelf.Setup.SetupStrings;

namespace TwimShelf.Setup;

public sealed partial class SetupWindow : Window
{
    enum Step { Ready, Working, Done, Failed }

    readonly Product _p;
    readonly string? _payload;
    readonly bool _update;
    readonly Installer _setup;
    readonly InstalledCopy? _copy;
    readonly InstallKind _kind;
    readonly string? _data;
    string _folder;
    bool _desktop, _launch = true, _removeData;
    Step _step = Step.Ready;
    double _progress;
    string? _error;
    readonly Grid _root = new() { Padding = new Thickness(32, 20, 32, 24) };

    bool Installing => _payload != null;

    public SetupWindow(Product product, string? payload, bool update)
    {
        _p = product;
        _payload = payload;
        _update = update;
        _setup = new Installer(product);
        _copy = _setup.Installed();
        _kind = Installer.KindOf(_copy, product.Version);
        // a copy that is there is replaced where it is: a second folder would leave the old one behind
        _folder = _copy?.Folder ?? (Installing ? _setup.DefaultFolder : AppContext.BaseDirectory.TrimEnd('\\'));
        _data = Installing ? null : Installer.DataFolder();
        _desktop = _copy != null && _setup.HasDesktopShortcut();
        Title = product.Name;
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        Content = _root;
        var icon = Path.Combine(Installing ? payload! : AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        if (File.Exists(icon)) AppWindow.SetIcon(icon);
        // the setup's size is its own: made here (AppWindow.Presenter comes back in the AOT build
        // as the base presenter, and a cast to OverlappedPresenter fails)
        var op = OverlappedPresenter.Create();
        op.IsResizable = false;
        op.IsMaximizable = false;
        AppWindow.SetPresenter(op);
        // no icon in the caption (the taskbar has it)
        AppWindow.TitleBar.IconShowOptions = IconShowOptions.HideIconAndSystemMenu;
        var scale = (double)Win32.DpiForSystem() / 96;
        AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(600 * scale), (int)(470 * scale)));
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        AppWindow.Move(new Windows.Graphics.PointInt32(area.X + (area.Width - AppWindow.Size.Width) / 2, area.Y + (area.Height - AppWindow.Size.Height) / 2));
        AppWindow.Closing += (_, e) => { if (_step == Step.Working) e.Cancel = true; };
        Draw();
        if (_update && Installing && _kind is InstallKind.Upgrade or InstallKind.Reinstall)
            _root.Loaded += async (_, _) => { await Run(); if (_step == Step.Done) Finish(); };
    }

    static string V(string v) => "v" + v;
    /// This build's own version: still a preview.
    static string VP(string v) => $"v{v} Preview";

    string TitleText => (Installing, _step, _kind) switch
    {
        (_, Step.Failed, _) => S("failed"),
        (true, Step.Ready, InstallKind.Fresh) => S("installTitle", _p.Name),
        (true, Step.Ready, InstallKind.Upgrade) => S("upgradeTitle", _p.Name),
        (true, Step.Ready, _) => S("overwriteTitle", _p.Name),
        (true, Step.Working, InstallKind.Fresh) => S("installing", _p.Name),
        (true, Step.Working, InstallKind.Upgrade) => S("upgrading", _p.Name),
        (true, Step.Working, _) => S("overwriting", _p.Name),
        (true, Step.Done, InstallKind.Upgrade) => S("upgraded", _p.Name, VP(_p.Version)),
        (true, Step.Done, _) => S("installed", _p.Name),
        (false, Step.Ready, _) => S("uninstallTitle", _p.Name),
        (false, Step.Working, _) => S("uninstalling", _p.Name),
        _ => S("uninstalled", _p.Name),
    };

    string? Subtitle => (Installing, _step, _kind) switch
    {
        (true, Step.Ready, InstallKind.Fresh) => null,
        // an older version may not open what a newer one wrote: its notice says so instead
        (true, Step.Ready, InstallKind.Downgrade) => null,
        (true, Step.Ready, _) => S("keepsData"),
        (true, Step.Done, _) => S("installedBody"),
        (false, Step.Ready, _) => S("uninstallBody"),
        _ => null,
    };

    /// The version beside the title: from and to when upgrading.
    string? Pill
    {
        get
        {
            if (!Installing) return _copy?.Version == null ? null : V(_copy.Version);
            if (_kind != InstallKind.Upgrade) return VP(_p.Version);
            return _step == Step.Done ? null : $"{V(_copy!.Version!)} → {VP(_p.Version)}";
        }
    }

    static Brush Res(string key) => (Brush)Application.Current.Resources[key];
    static Style Sty(string key) => (Style)Application.Current.Resources[key];

    void Draw()
    {
        _root.Children.Clear();
        _root.RowDefinitions.Clear();
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition());
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // the app's name in the caption area (no icon)
        var caption = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(-16, -8, 0, 0) };
        caption.Children.Add(new TextBlock { Text = _p.Name, Style = Sty("CaptionTextBlockStyle"), VerticalAlignment = VerticalAlignment.Center });
        _root.Children.Add(caption);

        var header = new StackPanel { Spacing = 6 };
        var titleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        titleRow.Children.Add(new TextBlock { Text = TitleText, Style = Sty("SubtitleTextBlockStyle"), TextWrapping = TextWrapping.Wrap });
        if (Pill is { } pill)
            titleRow.Children.Add(new Border
            {
                Child = new TextBlock { Text = pill, Style = Sty("CaptionTextBlockStyle"), Foreground = Res("TextOnAccentFillColorPrimaryBrush") },
                Background = Res("AccentFillColorDefaultBrush"), CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 2, 10, 3), VerticalAlignment = VerticalAlignment.Center,
            });
        header.Children.Add(titleRow);
        if (Subtitle is { } sub) header.Children.Add(new TextBlock { Text = sub, TextWrapping = TextWrapping.Wrap, Foreground = Res("TextFillColorSecondaryBrush") });
        Grid.SetRow(header, 1);
        _root.Children.Add(header);

        var panel = new StackPanel { Spacing = 4, Margin = new Thickness(0, 20, 0, 12) };
        switch (_step)
        {
            case Step.Ready:
                if (Installing) InstallOptions(panel); else UninstallOptions(panel);
                break;
            case Step.Working:
                var bar = new ProgressBar { Maximum = 1, Value = _progress, Margin = new Thickness(0, 24, 0, 0) };
                panel.Children.Add(bar);
                panel.Children.Add(new TextBlock { Text = $"{Math.Round(_progress * 100)}%", HorizontalAlignment = HorizontalAlignment.Right, Style = Sty("CaptionTextBlockStyle") });
                break;
            case Step.Done:
                if (Installing)
                {
                    panel.Children.Add(PathCard(S("installedFolder"), _folder, null));
                }
                else if (_data == null || _removeData)
                    panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Success, Message = _data == null ? S("uninstalled", _p.Name) : S("dataRemoved") });
                else panel.Children.Add(PathCard(S("dataKept"), _data, null));
                break;
            case Step.Failed:
                panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = _error ?? "" });
                break;
        }
        var scroll = new ScrollViewer { Content = panel };
        Grid.SetRow(scroll, 2);
        _root.Children.Add(scroll);

        // bottom: a note on the left, the actions on the right
        var bottom = new Grid { ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } } };
        var note = _step switch
        {
            Step.Ready when _data != null => S("dataKeptNote"),
            _ => "",
        };
        bottom.Children.Add(new TextBlock { Text = note, TextWrapping = TextWrapping.Wrap, Style = Sty("CaptionTextBlockStyle"), Foreground = Res("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 16, 0) });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        Button Btn(string text, Action a, bool accent = false)
        {
            var b = new Button { Content = text, MinWidth = 96 };
            if (accent) b.Style = Sty("AccentButtonStyle");
            b.Click += (_, _) => a();
            return b;
        }
        // an option beside the buttons: the desktop shortcut before installing, opening the app after
        CheckBox? option = (_step, Installing) switch
        {
            (Step.Ready, true) => new CheckBox { Content = S("desktopShortcut"), IsChecked = _desktop },
            (Step.Done, true) => new CheckBox { Content = S("launch", _p.Name), IsChecked = _launch },
            _ => null,
        };
        if (option != null)
        {
            option.VerticalAlignment = VerticalAlignment.Center;
            option.Margin = new Thickness(0, 0, 8, 0);
            option.Click += (_, _) => { if (_step == Step.Ready) _desktop = option.IsChecked == true; else _launch = option.IsChecked == true; };
            actions.Children.Add(option);
        }
        switch (_step)
        {
            case Step.Ready:
                actions.Children.Add(Btn(S("cancel"), Application.Current.Exit));
                var go = Btn(Installing ? _kind switch { InstallKind.Fresh => S("install"), InstallKind.Upgrade => S("upgrade"), _ => S("overwrite") } : S("uninstall"), () => _ = Run(), accent: true);
                // not into a folder with other files, or one holding the data
                go.IsEnabled = !(Installing && _kind == InstallKind.Fresh && Installer.FolderProblem(_folder) != null);
                actions.Children.Add(go);
                break;
            case Step.Done:
                actions.Children.Add(Btn(S("finish"), Finish, accent: true));
                break;
            case Step.Failed:
                actions.Children.Add(Btn(S("close"), Application.Current.Exit));
                actions.Children.Add(Btn(S("retry"), () => _ = Run(), accent: true));
                break;
        }
        Grid.SetColumn(actions, 1);
        bottom.Children.Add(actions);
        Grid.SetRow(bottom, 3);
        _root.Children.Add(bottom);
    }

    SettingsCard PathCard(string header, string path, Action? change)
    {
        var c = new SettingsCard
        {
            Header = header,
            HeaderIcon = new FontIcon { Glyph = "" },
            Description = new TextBlock { Text = path, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 },
        };
        if (change != null)
        {
            var b = new Button { Content = S("change") };
            b.Click += (_, _) => change();
            c.Content = b;
        }
        return c;
    }

    void InstallOptions(StackPanel panel)
    {
        var notice = _kind switch
        {
            InstallKind.Upgrade => S("upgradeNotice", V(_copy!.Version!), VP(_p.Version)),
            InstallKind.Reinstall => S("reinstallNotice", VP(_p.Version)),
            InstallKind.Downgrade => S("downgradeNotice", V(_copy!.Version!), VP(_p.Version)),
            InstallKind.UnknownVersion => S("unknownNotice", VP(_p.Version)),
            _ => null,
        };
        if (notice != null)
            panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Message = notice, Severity = _kind == InstallKind.Downgrade ? InfoBarSeverity.Warning : InfoBarSeverity.Informational, Margin = new Thickness(0, 0, 0, 4) });
        if (_kind == InstallKind.Fresh && Installer.FolderProblem(_folder) is { } problem)
            panel.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Message = S(problem), Severity = InfoBarSeverity.Error, Margin = new Thickness(0, 0, 0, 4) });
        panel.Children.Add(PathCard(_kind == InstallKind.Fresh ? S("folder") : S("installedFolder"), _folder, _kind == InstallKind.Fresh ? async () =>
        {
            var d = await Pickers.Folder(this);
            if (d != null) { _folder = Path.Combine(d, _p.Name); Draw(); }
        } : null));
    }

    void UninstallOptions(StackPanel panel)
    {
        panel.Children.Add(PathCard(S("installedFolder"), _folder, null));
        if (_data != null)
        {
            var remove = new CheckBox { Content = S("removeData"), IsChecked = _removeData };
            remove.Click += (_, _) => _removeData = remove.IsChecked == true;
            panel.Children.Add(new SettingsCard
            {
                Header = remove,
                HeaderIcon = new FontIcon { Glyph = "" },
                Description = new TextBlock { Text = _data, TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 12 },
            });
        }
    }

    async Task Run()
    {
        _step = Step.Working;
        _progress = 0;
        Draw();
        var progress = new Progress<double>(v => { _progress = v; if (_step == Step.Working) Draw(); });
        try
        {
            if (_payload is { } payload) await _setup.Install(payload, _folder, _desktop, progress);
            else await _setup.Uninstall(_folder, _removeData ? _data : null, S("uninstallLeftovers"), progress);
            _step = Step.Done;
        }
        catch (Exception e)
        {
            _step = Step.Failed;
            _error = e.Message;
        }
        Draw();
    }

    void Finish()
    {
        if (Installing && _step == Step.Done && _launch)
            Process.Start(new ProcessStartInfo(Path.Combine(_folder, _p.Executable)) { UseShellExecute = true, WorkingDirectory = _folder });
        Application.Current.Exit();
    }
}

static partial class Win32
{
    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    internal static partial uint GetDpiForSystem();
    public static uint DpiForSystem() => GetDpiForSystem();
}
