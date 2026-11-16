// The viewers' 分享: a small card with 另存为… (a copy where the person chooses) and 复制 (the file on
// the clipboard, to paste in Explorer or another app; a photo's picture too).
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Controls;

public static class ShareMenu
{
    public static MenuFlyout For(Func<Core.FeedItem> current)
    {
        var m = new MenuFlyout();
        m.Items.Add(FolderActions.Item(L("windows.viewer.saveAs"), "", () => _ = SaveAs(current())));
        m.Items.Add(FolderActions.Item(L("windows.viewer.copy"), "", () => _ = Copy(current())));
        return m;
    }

    static async Task SaveAs(Core.FeedItem item)
    {
        var w = MainWindow.Current!;
        var ext = Path.GetExtension(item.Path);
        // named after the post (the library keeps files by their contents' hash)
        var name = string.Concat($"{(item.ScreenName is { Length: > 0 } sn ? sn + "_" : "")}{item.PostId}_{item.Ordinal + 1}".Split(Path.GetInvalidFileNameChars()));
        var to = await Pickers.SaveFile(w, name + ext, (ext.TrimStart('.').ToUpperInvariant(), ext));
        if (to == null) return;
        try
        {
            await Task.Run(() => File.Copy(item.Path, to, true));
            Dialogs.Toast(w, L("viewer.copiedTo", to));
        }
        catch (Exception e) { Services.Diagnostics.Log("save as: " + e.Message); Dialogs.Toast(w, L("viewer.copyFailed")); }
    }

    static async Task Copy(Core.FeedItem item)
    {
        var w = MainWindow.Current!;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(item.Path));
            var data = new DataPackage { RequestedOperation = DataPackageOperation.Copy };
            data.SetStorageItems(new List<IStorageItem> { file });
            if (!item.IsVideo) data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
            Clipboard.SetContent(data);
            Clipboard.Flush();
            Dialogs.Toast(w, L("viewer.copied"));
        }
        catch (Exception e) { Services.Diagnostics.Log("copy: " + e.Message); Dialogs.Toast(w, L("viewer.copyFailed")); }
    }
}
