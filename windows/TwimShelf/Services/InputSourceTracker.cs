// Lightweight Win32 Raw Input observer attached to MainWindow's HWND so controls can reliably
// distinguish Precision Touchpad two-finger swipes from physical mouse wheels (including tilt
// wheels, thumb horizontal wheels, and high-resolution free-spin mice).
// Foreground-only registration (dwFlags = 0), zero per-event heap allocation, Native AOT safe.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using TwimShelf.Controls;

namespace TwimShelf.Services;

public static unsafe partial class InputSourceTracker
{
    const uint WM_INPUT = 0x00FF;
    const uint RID_INPUT = 0x10000003;
    const uint RID_HEADER = 0x10000005;
    const uint RIM_TYPEMOUSE = 0;
    const uint RIM_TYPEHID = 2;
    const ushort RI_MOUSE_WHEEL = 0x0400;
    const ushort RI_MOUSE_HWHEEL = 0x0800;
    const ushort HID_USAGE_PAGE_GENERIC = 0x01;
    const ushort HID_USAGE_GENERIC_MOUSE = 0x02;
    const ushort HID_USAGE_PAGE_DIGITIZER = 0x0D;
    const ushort HID_USAGE_DIGITIZER_TOUCH_PAD = 0x05;
    const nuint SubclassId = 0x54534954; // 'TSIT'

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTDEVICE
    {
        public ushort usUsagePage;
        public ushort usUsage;
        public uint dwFlags;
        public nint hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUTHEADER
    {
        public uint dwType;
        public uint dwSize;
        public nint hDevice;
        public nuint wParam;
    }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct RAWMOUSE
    {
        [FieldOffset(0)] public ushort usFlags;
        [FieldOffset(4)] public ushort usButtonFlags;
        [FieldOffset(6)] public short usButtonData;
        [FieldOffset(8)] public uint ulRawButtons;
        [FieldOffset(12)] public int lLastX;
        [FieldOffset(16)] public int lLastY;
        [FieldOffset(20)] public uint ulExtraInformation;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RAWINPUT_MOUSE
    {
        public RAWINPUTHEADER Header;
        public RAWMOUSE Mouse;
    }

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetWindowSubclass(
        nint hWnd,
        delegate* unmanaged[Stdcall]<nint, uint, nuint, nint, nuint, nuint, nint> pfnSubclass,
        nuint uIdSubclass,
        nuint dwRefData);

    [LibraryImport("comctl32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RemoveWindowSubclass(
        nint hWnd,
        delegate* unmanaged[Stdcall]<nint, uint, nuint, nint, nuint, nuint, nint> pfnSubclass,
        nuint uIdSubclass);

    [LibraryImport("comctl32.dll")]
    private static partial nint DefSubclassProc(nint hWnd, uint uMsg, nuint wParam, nint lParam);

    [LibraryImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool RegisterRawInputDevices(RAWINPUTDEVICE* pRawInputDevices, uint uiNumDevices, uint cbSize);

    [LibraryImport("user32.dll")]
    private static partial uint GetRawInputData(nint hRawInput, uint uiCommand, void* pData, ref uint pcbSize, uint cbSizeHeader);

    [LibraryImport("user32.dll")]
    private static partial int GetSystemMetrics(int nIndex);

    const int SM_REMOTESESSION = 0x1000;

    /// True when Windows is currently running inside a Remote Desktop (RDP) session, where the
    /// client's trackpad is forwarded through the RDP virtual mouse driver.
    public static bool IsRemoteSession() => GetSystemMetrics(SM_REMOTESESSION) != 0;

    public static void Attach(Window window)
    {
        var hwnd = Win32Interop.GetWindowFromWindowId(window.AppWindow.Id);
        if (hwnd == 0) return;

        // Register foreground Raw Input for physical mice and Precision Touchpads independently so
        // machines without a touchpad still register mice cleanly.
        var mouse = new RAWINPUTDEVICE
        {
            usUsagePage = HID_USAGE_PAGE_GENERIC,
            usUsage = HID_USAGE_GENERIC_MOUSE,
            dwFlags = 0,
            hwndTarget = hwnd,
        };
        RegisterRawInputDevices(&mouse, 1, (uint)sizeof(RAWINPUTDEVICE));

        var touchpad = new RAWINPUTDEVICE
        {
            usUsagePage = HID_USAGE_PAGE_DIGITIZER,
            usUsage = HID_USAGE_DIGITIZER_TOUCH_PAD,
            dwFlags = 0,
            hwndTarget = hwnd,
        };
        RegisterRawInputDevices(&touchpad, 1, (uint)sizeof(RAWINPUTDEVICE));

        if (!SetWindowSubclass(hwnd, &SubclassProc, SubclassId, 0))
            return;

        window.Closed += (_, _) => RemoveWindowSubclass(hwnd, &SubclassProc, SubclassId);
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvStdcall)])]
    static nint SubclassProc(nint hwnd, uint msg, nuint wParam, nint lParam, nuint uIdSubclass, nuint dwRefData)
    {
        if (msg == WM_INPUT)
        {
            try
            {
                uint headerSize = (uint)sizeof(RAWINPUTHEADER);
                RAWINPUT_MOUSE buf = default;
                uint hdrSize = headerSize;
                if (GetRawInputData(lParam, RID_HEADER, &buf.Header, ref hdrSize, headerSize) == headerSize)
                {
                    if (buf.Header.dwType == RIM_TYPEHID)
                    {
                        TouchpadInputState.RecordTouchpad(Environment.TickCount64);
                    }
                    else if (buf.Header.dwType == RIM_TYPEMOUSE)
                    {
                        uint fullSize = (uint)sizeof(RAWINPUT_MOUSE);
                        if (GetRawInputData(lParam, RID_INPUT, &buf, ref fullSize, headerSize) != unchecked((uint)-1))
                        {
                            const ushort WheelMask = RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL;
                            if ((buf.Mouse.usButtonFlags & WheelMask) != 0 && buf.Header.hDevice != 0)
                                TouchpadInputState.RecordPhysicalMouseWheel(Environment.TickCount64);
                        }
                    }
                }
            }
            catch { }
        }
        return DefSubclassProc(hwnd, msg, wParam, lParam);
    }
}
