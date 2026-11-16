// 下载帖子 in the taskbar icon's menu (the jump list's task: TwimShelf.exe --quick-download), through
// the shell's COM objects with source-generated interop (Native AOT has no built-in COM).
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;

namespace TwimShelf.Services;

public static unsafe partial class JumpList
{
    public static void Install(string title)
    {
        var exe = Environment.ProcessPath!;
        var link = Create<IShellLinkW>(CLSID_ShellLink, IID_IShellLinkW);
        Check(link.SetPath(exe));
        Check(link.SetArguments("--quick-download"));
        Check(link.SetIconLocation(exe, 0));
        var store = (IPropertyStore)link;
        var key = new PropertyKey { fmtid = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), pid = 2 }; // System.Title
        var value = new PropVariant { vt = 31 /* VT_LPWSTR */, pointer = Marshal.StringToCoTaskMemUni(title) };
        try { Check(store.SetValue(ref key, ref value)); }
        finally { Marshal.FreeCoTaskMem(value.pointer); }
        Check(store.Commit());

        var list = Create<ICustomDestinationList>(CLSID_DestinationList, IID_ICustomDestinationList);
        var iidArray = IID_IObjectArray;
        Check(list.BeginList(out _, ref iidArray, out _));
        var tasks = Create<IObjectCollection>(CLSID_EnumerableObjectCollection, IID_IObjectCollection);
        Check(tasks.AddObject(link));
        Check(list.AddUserTasks((IObjectArray)tasks));
        Check(list.CommitList());
    }

    static void Check(int hr) => Marshal.ThrowExceptionForHR(hr);

    static T Create<T>(Guid clsid, Guid iid)
    {
        Check(CoCreateInstance(ref clsid, 0, 1 /* CLSCTX_INPROC_SERVER */, ref iid, out var p));
        try { return (T)ComInterfaceMarshaller<object>.ConvertToManaged((void*)p)!; }
        finally { Marshal.Release(p); }
    }

    [LibraryImport("ole32.dll")]
    private static partial int CoCreateInstance(ref Guid clsid, nint outer, uint context, ref Guid iid, out nint result);

    static readonly Guid CLSID_ShellLink = new("00021401-0000-0000-C000-000000000046");
    static readonly Guid CLSID_DestinationList = new("77F10CF0-3DB5-4966-B520-B7C54FD35ED6");
    static readonly Guid CLSID_EnumerableObjectCollection = new("2D3468C1-36A7-43B6-AC24-D3F02FD9607A");
    static readonly Guid IID_IShellLinkW = new("000214F9-0000-0000-C000-000000000046");
    static readonly Guid IID_ICustomDestinationList = new("6332DEBF-87B5-4670-90C0-5E57B408A49E");
    static readonly Guid IID_IObjectCollection = new("5632B1A4-E38A-400A-928A-D4CD63230295");
    static readonly Guid IID_IObjectArray = new("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9");

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropertyKey { public Guid fmtid; public uint pid; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropVariant { public ushort vt; public ushort r1, r2, r3; public nint pointer; public nint pad; }

    [GeneratedComInterface(StringMarshalling = StringMarshalling.Utf16), Guid("000214F9-0000-0000-C000-000000000046")]
    internal partial interface IShellLinkW
    {
        [PreserveSig] int GetPath(nint file, int max, nint data, uint flags);
        [PreserveSig] int GetIDList(out nint pidl);
        [PreserveSig] int SetIDList(nint pidl);
        [PreserveSig] int GetDescription(nint name, int max);
        [PreserveSig] int SetDescription(string name);
        [PreserveSig] int GetWorkingDirectory(nint dir, int max);
        [PreserveSig] int SetWorkingDirectory(string dir);
        [PreserveSig] int GetArguments(nint args, int max);
        [PreserveSig] int SetArguments(string args);
        [PreserveSig] int GetHotkey(out ushort key);
        [PreserveSig] int SetHotkey(ushort key);
        [PreserveSig] int GetShowCmd(out int cmd);
        [PreserveSig] int SetShowCmd(int cmd);
        [PreserveSig] int GetIconLocation(nint path, int max, out int index);
        [PreserveSig] int SetIconLocation(string path, int index);
        [PreserveSig] int SetRelativePath(string path, uint reserved);
        [PreserveSig] int Resolve(nint hwnd, uint flags);
        [PreserveSig] int SetPath(string file);
    }

    [GeneratedComInterface, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    internal partial interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    [GeneratedComInterface, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9")]
    internal partial interface IObjectArray
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, ref Guid iid, out nint obj);
    }

    [GeneratedComInterface, Guid("5632B1A4-E38A-400A-928A-D4CD63230295")]
    internal partial interface IObjectCollection : IObjectArray
    {
        [PreserveSig] int AddObject([MarshalAs(UnmanagedType.Interface)] object obj);
        [PreserveSig] int AddFromArray(IObjectArray source);
        [PreserveSig] int RemoveObjectAt(uint index);
        [PreserveSig] int Clear();
    }

    [GeneratedComInterface, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E")]
    internal partial interface ICustomDestinationList
    {
        [PreserveSig] int SetAppID([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int BeginList(out uint slots, ref Guid iid, out nint removed);
        [PreserveSig] int AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, IObjectArray items);
        [PreserveSig] int AppendKnownCategory(int category);
        [PreserveSig] int AddUserTasks(IObjectArray tasks);
        [PreserveSig] int CommitList();
        [PreserveSig] int GetRemovedDestinations(ref Guid iid, out nint obj);
        [PreserveSig] int DeleteList([MarshalAs(UnmanagedType.LPWStr)] string id);
        [PreserveSig] int AbortList();
    }
}
