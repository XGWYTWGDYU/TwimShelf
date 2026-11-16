// 开机自启: TwimShelf starts in the background when the person signs in to Windows (their own Run
// entry, nothing system-wide), and stays running when its window is closed — downloads, sync and
// tagging go on. No tray icon: opening TwimShelf again (Start, the taskbar, a second click) brings
// the window back. The entry itself is the setting (this computer's, not synced).
using Microsoft.Win32;

namespace TwimShelf.Services;

public static class LaunchAtLogin
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string Name = "TwimShelf";
    public const string Argument = "--background";

    static string Command => $"\"{Environment.ProcessPath}\" {Argument}";

    public static bool IsOn
    {
        get
        {
            try
            {
                using var k = Registry.CurrentUser.OpenSubKey(RunKey);
                return k?.GetValue(Name) is string v && v.Contains(Path.GetFileName(Environment.ProcessPath ?? "TwimShelf.exe"), StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    public static void Set(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue(Name, Command);
        else k.DeleteValue(Name, false);
    }

    /// The entry again where the program now is (an update or a move changes the path).
    public static void Refresh()
    {
        try { if (IsOn) Set(true); } catch { }
    }

    /// For the uninstaller: no entry left behind.
    public static void Remove()
    {
        try { using var k = Registry.CurrentUser.OpenSubKey(RunKey, true); k?.DeleteValue(Name, false); } catch { }
    }
}
