using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;

namespace TwimShelf.Services;

/// A window's display scale, known before its content has loaded.
public static partial class WindowScale
{
    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint hwnd);

    public static double Of(AppWindow window)
    {
        var dpi = GetDpiForWindow(Win32Interop.GetWindowFromWindowId(window.Id));
        return dpi == 0 ? 1 : dpi / 96.0;
    }
}
