// The system's file and folder dialogs, tied to the window (an unpackaged app gives its handle).
using Microsoft.UI.Xaml;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace TwimShelf.Controls;

public static class Pickers
{
    static T Init<T>(T picker, Window w) where T : class
    {
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(w));
        return picker;
    }

    public static async Task<string?> SaveFile(Window w, string name, params (string Label, string Ext)[] types)
    {
        var p = Init(new FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(name), SuggestedStartLocation = PickerLocationId.Downloads }, w);
        foreach (var (label, ext) in types) p.FileTypeChoices.Add(label, new List<string> { ext });
        var f = await p.PickSaveFileAsync();
        return f?.Path;
    }

    public static async Task<string?> OpenFile(Window w, params string[] exts)
    {
        var p = Init(new FileOpenPicker { SuggestedStartLocation = PickerLocationId.Downloads, ViewMode = PickerViewMode.List }, w);
        foreach (var e in exts.Length == 0 ? ["*"] : exts) p.FileTypeFilter.Add(e);
        var f = await p.PickSingleFileAsync();
        return f?.Path;
    }

    public static async Task<List<string>> OpenFiles(Window w, params string[] exts)
    {
        var p = Init(new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary, ViewMode = PickerViewMode.Thumbnail }, w);
        foreach (var e in exts.Length == 0 ? ["*"] : exts) p.FileTypeFilter.Add(e);
        var fs = await p.PickMultipleFilesAsync();
        return [.. fs.Select(f => f.Path)];
    }

    public static async Task<string?> Folder(Window w)
    {
        var p = Init(new FolderPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary }, w);
        p.FileTypeFilter.Add("*");
        var f = await p.PickSingleFolderAsync();
        return f?.Path;
    }
}
