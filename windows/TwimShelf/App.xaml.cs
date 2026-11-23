using Microsoft.UI.Xaml;
using TwimShelf.Models;
using TwimShelf.Services;

namespace TwimShelf;

/// Starting: a second launch (发送到, the jump list, a second click) leaves its request for the first
/// and ends; the first finds its data folder (asking for one the first time), opens the library and
/// shows the main window.
public partial class App : Application
{
    static Mutex? _primary;

    /// Lets go of the single-instance lock (a restart: the new one takes it).
    public static void ReleasePrimary() { try { _primary?.Dispose(); } catch { } _primary = null; }
    StartWindow? _start;
    Window? _setupWindow;

    public App()
    {
        // light or dark is the system's (nothing to choose on Windows)
        InitializeComponent();
        // a failed button (no network for a check, say) is logged; it does not end the app
        UnhandledException += (_, e) => { Diagnostics.Log("unhandled: " + e.Message + "\n" + e.Exception); e.Handled = true; };
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Diagnostics.Log("unhandled (domain): " + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => Diagnostics.Log("unobserved: " + e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var argv = Environment.GetCommandLineArgs().Skip(1).ToArray();
        // the setup and the uninstaller are this program too (no library, no single-instance lock)
        var setup = Array.IndexOf(argv, "--setup");
        if (setup >= 0 || argv.Contains("--uninstall"))
        {
            var payload = setup >= 0 && setup + 1 < argv.Length ? argv[setup + 1].TrimEnd('\\') : null;
            var product = TwimShelf.Setup.Product.Read(Path.Combine(payload ?? AppContext.BaseDirectory, "payload.json"));
            // --quiet (CI's smoke test): no window, the exit code says how it went
            if (argv.Contains("--quiet")) { _ = Quiet(product, payload); return; }
            _setupWindow = new TwimShelf.Setup.SetupWindow(product, payload, argv.Contains("--update"));
            _setupWindow.Activate();
            return;
        }
        DataHome.WaitForPrevious(argv);
        try { ShareInbox.QueueArguments(argv); } catch { }
        _primary = ShareInbox.AcquirePrimary();
        // a restart: the old one may still be ending, give it a moment to let go
        for (var i = 0; _primary == null && argv.Contains("--after") && i < 50; i++) { Thread.Sleep(200); _primary = ShareInbox.AcquirePrimary(); }
        if (_primary == null)
        {
            // the first one is running: it picks the request up (and comes forward for a plain launch)
            SingleInstance.BringOtherToFront();
            Exit();
            return;
        }
        L10n.Load();
        // 开机自启: the library opens, the window waits until TwimShelf is opened
        if (argv.Contains(LaunchAtLogin.Argument) && DataHome.Locate()) { _ = Open(background: true); return; }
        _start = new StartWindow();
        _start.Activate();
        if (DataHome.Locate()) _ = Open();
        else _start.AskForDataFolder(() => _ = Open());
    }

    /// The setup or the uninstaller without a window: installs where it is installed already (or
    /// the default folder), or uninstalls keeping the data.
    static async Task Quiet(TwimShelf.Setup.Product product, string? payload)
    {
        var code = 0;
        try
        {
            var setup = new TwimShelf.Setup.Installer(product);
            var progress = new Progress<double>();
            if (payload != null)
            {
                var folder = setup.Installed()?.Folder ?? setup.DefaultFolder;
                if (TwimShelf.Setup.Installer.FolderProblem(folder) is { } problem) throw new IOException(problem);
                await setup.Install(payload, folder, false, progress);
            }
            else await setup.Uninstall(AppContext.BaseDirectory.TrimEnd('\\'), null, TwimShelf.Setup.SetupStrings.S("uninstallLeftovers"), progress);
        }
        catch (Exception e) { try { File.WriteAllText(Path.Combine(Path.GetTempPath(), "twimshelf-setup-error.txt"), e.ToString()); } catch { } code = 1; }
        Environment.Exit(code);
    }

    static MainWindow? _main;
    static bool _locked, _checked;

    /// 退出 (开机自启 keeps TwimShelf running when its window closes): the window closes for good.
    public static bool Quitting { get; private set; }
    public static void Quit() { Quitting = true; _main?.Close(); }

    /// The window hid (开机自启): the app lock asks again before it shows.
    public static void WindowHidden() => _locked = Prefs.Instance.AppLock;

    /// A later launch asked for the window (or a share that needs a choice): true once it shows.
    public static async Task<bool> ShowWindow()
    {
        if (_main == null) return false;
        if (!_main.Visible && _locked)
        {
            var gate = new StartWindow();
            gate.Activate();
            gate.ShowOpening();
            var ok = await AppLock.Unlock(gate);
            gate.Close();
            if (!ok) return false;
            _locked = false;
        }
        _main.Present();
        if (!_checked)
        {
            _checked = true;
            await Pages.DataHomeSettings.RequireOutsideProgram(LibraryModel.Current);
            _main.ShowPendingShares();
            _ = StartupChecks.Run(_main);
            WelcomeWindow.ShowIfNeeded();
        }
        return true;
    }

    async Task Open(bool background = false)
    {
        Prefs.Load();
        Diagnostics.Start();
        _start?.ShowOpening();
        try
        {
            if (!background && Prefs.Instance.AppLock && !await AppLock.Unlock(_start!)) { Exit(); return; }
            Diagnostics.Log(background ? "start: opening library (in the background)" : "start: opening library");
            var library = await LibraryModel.Open();
            Diagnostics.Log("start: library open");
            var main = _main = new MainWindow(library);
            Diagnostics.Log("start: main window made");
            main.Closed += (_, _) => { library.Close(); Exit(); };
            SingleInstance.Listen(() => main.DispatcherQueue.TryEnqueue(() => _ = ShowWindow()));
            SingleInstance.ListenForQuit(() => main.DispatcherQueue.TryEnqueue(Quit));
            LaunchAtLogin.Refresh();
            if (background) { _locked = Prefs.Instance.AppLock; return; }
            main.Present();
            Diagnostics.Log("start: main window shown");
            _start?.Close();
            _start = null;
            _checked = true;
            // a data folder inside the program's folder moves first (or the app quits)
            await Pages.DataHomeSettings.RequireOutsideProgram(library);
            main.ShowPendingShares();
            _ = StartupChecks.Run(main);
            WelcomeWindow.ShowIfNeeded();
        }
        catch (Exception e)
        {
            Diagnostics.Log("open failed: " + e);
            if (_start != null) _start.ShowFailed(e.Message);
            else Exit();
        }
    }
}
