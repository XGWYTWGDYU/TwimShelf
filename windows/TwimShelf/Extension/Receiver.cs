// The browser extension's receiver on this device (the core answers it: core/src/extension.rs).
// It listens while the app is open and follows the download settings, so a link from the browser
// downloads as one pasted here would.
using System.Text.Json.Nodes;
using TwimShelf.Core;
using TwimShelf.Models;

namespace TwimShelf.Extension;

public static class Receiver
{
    public static int? Port { get; private set; }
    public static string? Problem { get; private set; }
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
            });
            Problem = null;
        }
        catch (Exception e) { Problem = e.Message; }
    }
}
