// Thumbnails for the grids and folder covers. Photos: the core makes a square JPEG (decoded,
// oriented, cropped) into <data>\Cache\GridThumbnails — the folder the Flutter app used, so its
// cache is kept. Videos: the shell's own thumbnail of the file (Windows makes posters itself).
// A thumbnail made already comes straight from the disk. What has to be made is made a few at a
// time, the newest ask first: a fast scroll makes what is on screen now, not the backlog it left.
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TwimShelf.Core;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace TwimShelf.Services;

public static class Thumbnails
{
    public static string CacheDir { get; private set; } = "";
    public const uint SmallSide = 384;
    public const uint LargeSide = 1280;

    static readonly LifoGate Workers = new(Math.Clamp(Environment.ProcessorCount - 1, 2, 6));
    static readonly HashSet<string> Failed = [];
    /// A thumbnail that could not be decoded (the app marks the media damaged).
    public static event Action<string>? OnFailed;

    /// Downloads (or another device) may have replaced damaged files: they get another try.
    /// 清除所有数据: every cached picture goes. False when some could not be removed.
    public static bool Clear()
    {
        lock (Failed) Failed.Clear();
        try
        {
            if (Directory.Exists(CacheDir)) Directory.Delete(CacheDir, true);
            Directory.CreateDirectory(CacheDir);
            return true;
        }
        catch { return false; }
    }

    public static void ForgetFailures() { lock (Failed) Failed.Clear(); }

    public static void Init()
    {
        var lib = Environment.GetEnvironmentVariable("TL_LIBRARY_DIR");
        CacheDir = lib != null ? Path.Combine(lib, ".thumbs") : Path.Combine(DataHome.CacheDir, "GridThumbnails");
        Directory.CreateDirectory(CacheDir);
    }

    /// The JPEG of a photo's square thumbnail, made when missing (blocks: call off the UI).
    public static async Task<string?> PhotoPath(string mediaId, uint side, CancellationToken cancel)
    {
        lock (Failed) if (Failed.Contains(mediaId)) return null;
        await Workers.WaitAsync(cancel);
        try
        {
            cancel.ThrowIfCancellationRequested();
            var r = await Task.Run(() => TlCore.Thumbnail(mediaId, side, CacheDir), cancel);
            return r.Path;
        }
        catch (ThumbnailNotDecodableException)
        {
            lock (Failed) Failed.Add(mediaId);
            OnFailed?.Invoke(mediaId);
            return null;
        }
        catch (OperationCanceledException) { throw; }
        catch { return null; }
        finally { Workers.Release(); }
    }

    /// A tile's picture at a pixel size (the UI thread makes the bitmap; the work runs elsewhere).
    public static async Task<ImageSource?> Tile(string mediaId, string path, bool video, int pixels, CancellationToken cancel)
    {
        if (video) return await VideoPoster(path, (uint)pixels, cancel);
        var side = pixels > SmallSide ? LargeSide : SmallSide;
        // made already (the core names them so): no wait for a worker
        var made = Path.Combine(CacheDir, side.ToString(), mediaId + ".jpg");
        var file = File.Exists(made) ? made : await PhotoPath(mediaId, side, cancel);
        if (file == null || cancel.IsCancellationRequested) return null;
        return new BitmapImage { DecodePixelWidth = pixels, DecodePixelType = DecodePixelType.Physical, UriSource = new Uri(file) };
    }

    /// The shell's thumbnail of a video (or any file it can draw), made once into the cache like a
    /// photo's and shown from the file.
    public static async Task<ImageSource?> VideoPoster(string path, uint pixels, CancellationToken cancel)
    {
        var side = pixels > SmallSide ? LargeSide : SmallSide;
        var made = Path.Combine(CacheDir, "video-" + side, PosterName(path));
        if (!File.Exists(made))
        {
            await Workers.WaitAsync(cancel);
            try
            {
                // off the UI thread, as the core makes photos' thumbnails: the shell's video thumbnail
                // runs Media Foundation and waits in ways that let the UI thread's messages in, and
                // WinUI, entered again in the middle of its own work, ends the process
                if (!File.Exists(made) && !await Task.Run(() => MakePoster(path, side, made, cancel), cancel)) return null;
            }
            catch (OperationCanceledException) { throw; }
            catch { return null; }
            finally { Workers.Release(); }
        }
        if (cancel.IsCancellationRequested) return null;
        return new BitmapImage { DecodePixelWidth = (int)pixels, DecodePixelType = DecodePixelType.Physical, UriSource = new Uri(made) };
    }

    /// A name for a video's poster: the file's path, size and time (a replaced file gets a new one).
    static string PosterName(string path)
    {
        var full = Path.GetFullPath(path);
        var info = new FileInfo(full);
        var key = $"{full.ToLowerInvariant()}|{(info.Exists ? info.Length : 0)}|{(info.Exists ? info.LastWriteTimeUtc.Ticks : 0)}";
        return Convert.ToHexString(System.Security.Cryptography.SHA1.HashData(System.Text.Encoding.UTF8.GetBytes(key))) + ".img";
    }

    static async Task<bool> MakePoster(string path, uint side, string made, CancellationToken cancel)
    {
        // StorageFile refuses a path with both separators, as the core makes them (…\lib\blobs/ab/…)
        var file = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(path));
        cancel.ThrowIfCancellationRequested();
        using var thumb = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, side, ThumbnailOptions.ResizeThumbnail);
        if (thumb == null || thumb.Size == 0) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(made)!);
        var partial = made + ".partial";
        using (var input = thumb.AsStreamForRead())
        using (var output = File.Create(partial))
            await input.CopyToAsync(output, cancel);
        File.Move(partial, made, true);
        return true;
    }

    /// A photo shown large (the viewer, a card): HEIC and AVIF through the core as JPEG, the rest as they are.
    public static async Task<string> Displayable(string path, uint maxSide)
    {
        var ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is ".heic" or ".heif" or ".avif")
        {
            try { return await Task.Run(() => TlCore.DisplayImage(path, maxSide, CacheDir)); }
            catch { return path; }
        }
        return path;
    }
}

/// A few at a time, like a semaphore, but the most recent waiter goes first and a cancelled one
/// (its tile scrolled away) drops out without ever running.
sealed class LifoGate(int count)
{
    readonly List<(TaskCompletionSource Ready, CancellationToken Cancel)> _waiting = [];
    int _free = count;

    public Task WaitAsync(CancellationToken cancel)
    {
        lock (_waiting)
        {
            if (_free > 0) { _free--; return Task.CompletedTask; }
            var t = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiting.Add((t, cancel));
            if (cancel.CanBeCanceled) cancel.Register(() => { lock (_waiting) _waiting.RemoveAll(w => w.Ready == t); t.TrySetCanceled(cancel); });
            return t.Task;
        }
    }

    public void Release()
    {
        lock (_waiting)
        {
            while (_waiting.Count > 0)
            {
                var (ready, cancel) = _waiting[^1];
                _waiting.RemoveAt(_waiting.Count - 1);
                if (!cancel.IsCancellationRequested && ready.TrySetResult()) return;
            }
            _free++;
        }
    }
}
