// A second launch brings the running window forward (its request was left for it already), also
// when that window is hidden (开机自启 keeps TwimShelf running without it): it signals an event the
// first process waits on.
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TwimShelf.Services;

public static partial class SingleInstance
{
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetForegroundWindow(nint hwnd);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool ShowWindow(nint hwnd, int cmd);
    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool IsIconic(nint hwnd);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AllowSetForegroundWindow(int process);

    static string ShowEvent => ShareInbox.InstanceName + "-show";

    static string QuitEvent => ShareInbox.InstanceName + "-quit";

    /// The first process: `quit` runs when the setup asks it to end (an update, the uninstaller):
    /// it ends as 退出 does, also when its window is hidden.
    public static void ListenForQuit(Action quit)
    {
        var e = new EventWaitHandle(false, EventResetMode.ManualReset, QuitEvent);
        new Thread(() => { if (e.WaitOne()) quit(); }) { IsBackground = true, Name = "quit request" }.Start();
    }

    /// The setup: asks a running TwimShelf to end; false when none listens.
    public static bool AskToQuit()
    {
        try
        {
            if (!EventWaitHandle.TryOpenExisting(QuitEvent, out var e)) return false;
            using (e) e.Set();
            return true;
        }
        catch { return false; }
    }

    /// The first process: `show` runs (on a thread of its own) whenever a later launch asks.
    public static void Listen(Action show)
    {
        var e = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEvent);
        new Thread(() => { while (e.WaitOne()) show(); }) { IsBackground = true, Name = "show requests" }.Start();
    }

    public static void BringOtherToFront()
    {
        try
        {
            // the first one may take the foreground (this launch has it, from the click)
            AllowSetForegroundWindow(-1);
            if (EventWaitHandle.TryOpenExisting(ShowEvent, out var show)) { using (show) show.Set(); return; }
        }
        catch { }
        try
        {
            var me = Process.GetCurrentProcess();
            foreach (var p in Process.GetProcessesByName(me.ProcessName))
            {
                if (p.Id == me.Id || p.MainWindowHandle == 0) continue;
                if (IsIconic(p.MainWindowHandle)) ShowWindow(p.MainWindowHandle, 9); // SW_RESTORE
                SetForegroundWindow(p.MainWindowHandle);
                return;
            }
        }
        catch { }
    }
}
