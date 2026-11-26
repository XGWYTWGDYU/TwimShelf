// The browser extension's receiver on this device (the core answers it: core/src/extension.rs).
// It listens while the app is open and follows the download settings, so a link from the browser
// downloads as one pasted here would.
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Extension;

public static class Receiver
{
    public static int? Port { get; private set; }
    public static string? Problem { get; private set; }
    public static string ManagedDir => Path.Combine(DataHome.AppDir, "extension");
    static DownloadService? _downloads;

    public static void Start(DownloadService downloads)
    {
        _downloads = downloads;
        downloads.Changed += Apply;
        Apply();
    }

    static void Apply()
    {
        var d = _downloads;
        if (d == null) return;
        try
        {
            Port = TlCore.ExtensionServe(new JsonObject
            {
                ["name"] = SyncModel.DeviceName,
                ["platform"] = "windows",
                ["flavor"] = "native",
                ["route"] = d.Route switch { DownloadRoute.Fx => "fx", DownloadRoute.Cookie => "cookie", _ => "auto" },
                ["concurrency"] = d.Concurrency,
                ["interval_ms"] = d.IntervalMs,
                ["folder"] = d.Folder,
                ["listen"] = true,
                ["desktop"] = true,
                ["managed_dir"] = ManagedDir,
            });
            Problem = null;
        }
        catch (Exception e) { Problem = e.Message; }
    }

    /// Daily automatic update check for the app-hosted extension (only when the app manages a copy
    /// in its own data directory; external installs are never checked or modified).
    public static async Task CheckUpdateOnLaunch(Window w)
    {
        try
        {
            var status = TlCore.ExtensionManagedStatus();
            if (!status.Installed) return;
            var p = Prefs.Instance;
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (now - p.ExtUpdateLastCheck < 86_400_000) return;
            var info = await TlCore.Run(() => TlCore.ExtensionManagedCheck(Updates.Repo));
            p.ExtUpdateLastCheck = now;
            if (!info.Installed || !info.HasUpdate || p.ExtUpdateSkipped == info.Latest) return;
            var choice = await Dialogs.Choose(
                w,
                L("ext.managed.prompt.title", info.Latest),
                L("ext.managed.prompt.message", info.Current ?? ""),
                L("ext.managed.updateNow"),
                L("update.skip"));
            if (choice == 1) { p.ExtUpdateSkipped = info.Latest; return; }
            if (choice == 0) await InstallManaged(w, updating: true);
        }
        catch { /* quiet on background check */ }
    }

    /// Downloads or updates the app-hosted extension in-place (Chrome does not need to quit).
    public static async Task<ExtensionManagedStatus?> InstallManaged(Window w, bool updating)
    {
        try
        {
            var st = await Dialogs.Progress(
                w,
                updating ? L("ext.managed.updating") : L("ext.managed.downloading"),
                () => TlCore.ExtensionManagedInstall(Updates.Repo));
            Prefs.Instance.ExtUpdateLastCheck = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            Prefs.Instance.ExtUpdateSkipped = null;
            if (updating)
                await Dialogs.Alert(w, L("ext.managed.updated.title", st.Version ?? ""), L("ext.managed.updated.message"));
            else
                await Dialogs.Alert(w, L("ext.managed.downloaded.title"), L("ext.managed.downloaded.message", st.Dir));
            return st;
        }
        catch (Exception e)
        {
            Dialogs.Toast(w, L("ext.managed.downloadFailed", e.Message));
            return null;
        }
    }
}
