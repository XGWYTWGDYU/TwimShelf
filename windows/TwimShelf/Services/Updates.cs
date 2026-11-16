// 检查更新, in GitHub builds only (built with TlUpdateRepo=owner/name; every other build never
// looks): at most once a day when the app opens, or when asked in 设置. The release's setup is
// downloaded, checked against the release (size, SHA-256) and started with --update: it installs
// over this copy without asking and starts the new version.
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using TwimShelf.Controls;
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Services;

public static class Updates
{
    public static string Repo => typeof(Updates).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "UpdateRepo")?.Value ?? "";
    public static bool Enabled => Repo.Contains('/');
    /// As shown to people: this version is still a preview.
    public static string Display => Current + " Preview";

    public static string Current => typeof(Updates).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0";
    static string Arch => RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";

    public static async Task<UpdateInfo?> Check(bool manual)
    {
        var p = Prefs.Instance;
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (!manual && now - p.UpdateLastCheck < 86_400_000) return null;
        var info = await TlCore.Run(() => TlCore.CheckUpdate(Repo, Current, [".exe"], Arch));
        p.UpdateLastCheck = now;
        if (info != null && !manual && p.UpdateSkipped == info.Version) return null;
        return info;
    }

    public static async Task CheckOnLaunch(Window w)
    {
        if (!Enabled) return;
        try { if (await Check(false) is { } info) await Offer(w, info); } catch { }
    }

    public static async Task CheckNow(Window w)
    {
        Dialogs.Toast(w, L("update.checking"));
        try
        {
            var info = await Check(true);
            if (info == null) Dialogs.Toast(w, L("update.current", Current));
            else await Offer(w, info);
        }
        catch (Exception e) { Dialogs.Toast(w, L("update.failed", e.Message)); }
    }

    static async Task Offer(Window w, UpdateInfo info)
    {
        var installs = info.AssetUrl != null;
        var choice = await Dialogs.Choose(w, L("update.available.title", info.Version), L("update.available.message", Display),
            installs ? L("update.install") : L("update.openPage"), L("update.skip"));
        if (choice == 1) { Prefs.Instance.UpdateSkipped = info.Version; return; }
        if (choice != 0) return;
        if (!installs)
        {
            if (Uri.TryCreate(info.PageUrl, UriKind.Absolute, out var u) && u.Scheme == "https") await Windows.System.Launcher.LaunchUriAsync(u);
            return;
        }
        try
        {
            var dir = Path.Combine(Path.GetTempPath(), "TwimShelf-updates");
            var file = await Dialogs.Progress(w, L("update.downloading"), () => TlCore.DownloadUpdate(info, dir));
            Process.Start(new ProcessStartInfo(file, "--update") { UseShellExecute = true });
            Application.Current.Exit();
        }
        catch (Exception e) { Dialogs.Toast(w, L("update.failed", e.Message)); }
    }
}
