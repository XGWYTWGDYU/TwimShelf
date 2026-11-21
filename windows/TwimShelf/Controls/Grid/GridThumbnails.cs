// Two-tier GPU texture cache for the D3D11 photo grid: background WIC decoding (LIFO, newest visible
// tiles first) -> bounded per-frame GPU mipmapped texture upload -> LRU eviction within memory budget.
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using TwimShelf.Core;
using TwimShelf.Services;

namespace TwimShelf.Controls.ZoomGrid;

internal sealed partial class GridThumbnails : IDisposable
{
    const long SmallBudgetBytes = 256L * 1024 * 1024;
    const long LargeBudgetBytes = 160L * 1024 * 1024;
    const double LargeThresholdPixels = 420.0;

    sealed class GpuEntry
    {
        public required string Id;
        public nint Texture;
        public nint Srv;
        public long Bytes;
    }

    sealed class ReadyBitmap
    {
        public required string Id;
        public bool Large;
        public int Side;
        public required byte[] Pixels;
    }

    sealed class DecodeJob
    {
        public required FeedItem Item;
        public bool Large;
        public bool Prefetch;
    }

    readonly Dictionary<string, LinkedListNode<GpuEntry>> _smallMap = [];
    readonly LinkedList<GpuEntry> _smallLru = [];
    long _smallBytes;

    readonly Dictionary<string, LinkedListNode<GpuEntry>> _largeMap = [];
    readonly LinkedList<GpuEntry> _largeLru = [];
    long _largeBytes;

    readonly ConcurrentQueue<ReadyBitmap> _ready = new();
    readonly Lock _queueLock = new();
    readonly List<DecodeJob> _visibleStack = [];
    readonly List<DecodeJob> _prefetchQueue = [];
    readonly HashSet<string> _inflight = [];
    readonly HashSet<string> _failed = [];
    int _activeWorkers;
    readonly int _maxWorkers = Math.Clamp(Environment.ProcessorCount - 1, 2, 6);
    int _frameRequested;
    int _clearRequested;
    bool _disposed;
    CancellationTokenSource _cts = new();

    public event Action? Loaded;

    /// Drops queued (not yet started) decode jobs when switching pages, keeping VRAM cache intact.
    public void ClearPendingRequests()
    {
        lock (_queueLock)
        {
            foreach (var job in _visibleStack) _inflight.Remove((job.Large ? "L:" : "S:") + job.Item.MediaId);
            foreach (var job in _prefetchQueue) _inflight.Remove((job.Large ? "L:" : "S:") + job.Item.MediaId);
            _visibleStack.Clear();
            _prefetchQueue.Clear();
        }
    }

    /// Marks the VRAM cache to be released safely on the render thread (called when disk cache is cleared).
    public void RequestClearGpu()
    {
        Interlocked.Exchange(ref _clearRequested, 1);
        ClearPendingRequests();
        while (_ready.TryDequeue(out _)) { }
        lock (_queueLock) _failed.Clear();
    }

    public bool IsLarge(double pixels) => pixels > LargeThresholdPixels;

    public void BeginFrame() => _frameRequested = 0;

    /// Returns the best available GPU SRV for `item` at `pixels`, queueing background decode if needed.
    /// When large is needed but not ready yet, falls back to the small texture so zooming never flashes blank.
    public nint TextureFor(FeedItem item, double pixels, bool prefetch = false)
    {
        if (_disposed) return 0;
        var wantLarge = IsLarge(pixels);
        nint smallSrv = Touch(_smallMap, _smallLru, item.MediaId);
        nint largeSrv = Touch(_largeMap, _largeLru, item.MediaId);

        if (wantLarge)
        {
            if (largeSrv != 0) return largeSrv;
            Request(item, large: true, prefetch);
            if (smallSrv != 0) return smallSrv;
            // Also request small immediately so a fast-arriving 384px tile fills in first.
            Request(item, large: false, prefetch);
            return 0;
        }
        if (smallSrv != 0) return smallSrv;
        if (largeSrv != 0) return largeSrv;
        Request(item, large: false, prefetch);
        return 0;
    }

    static nint Touch(Dictionary<string, LinkedListNode<GpuEntry>> map, LinkedList<GpuEntry> lru, string id)
    {
        if (!map.TryGetValue(id, out var node)) return 0;
        if (lru.First != node)
        {
            lru.Remove(node);
            lru.AddFirst(node);
        }
        return node.Value.Srv;
    }

    void Request(FeedItem item, bool large, bool prefetch)
    {
        var key = (large ? "L:" : "S:") + item.MediaId;
        lock (_queueLock)
        {
            if (_disposed || _failed.Contains(key) || _inflight.Contains(key)) return;
            if (!prefetch && _frameRequested >= 64) return;
            if (!prefetch) _frameRequested++;
            _inflight.Add(key);
            var job = new DecodeJob { Item = item, Large = large, Prefetch = prefetch };
            if (prefetch)
            {
                if (_prefetchQueue.Count > 256) _prefetchQueue.RemoveAt(0);
                _prefetchQueue.Add(job);
            }
            else
            {
                if (_visibleStack.Count > 256)
                {
                    var dropped = _visibleStack[0];
                    _visibleStack.RemoveAt(0);
                    _inflight.Remove((dropped.Large ? "L:" : "S:") + dropped.Item.MediaId);
                }
                _visibleStack.Add(job);
            }
            if (_activeWorkers < _maxWorkers)
            {
                _activeWorkers++;
                var ct = _cts.Token;
                _ = Task.Run(() => WorkerLoop(ct));
            }
        }
    }

    /// Uploads decoded bitmaps into mipmapped D3D11 textures on the render thread within a time budget.
    /// Returns true if more uploads are queued (caller should keep drawing next vsync).
    public bool DrainUploads(nint device, nint context, double budgetMs = 5.0)
    {
        if (_disposed || device == 0 || context == 0) return false;
        if (Interlocked.Exchange(ref _clearRequested, 0) != 0)
            ReleaseGpuResources();

        var start = Stopwatch.GetTimestamp();
        var budgetTicks = (long)(budgetMs * Stopwatch.Frequency / 1000.0);
        var uploaded = 0;

        while (uploaded < 32 && _ready.TryDequeue(out var bmp))
        {
            UploadOne(device, context, bmp);
            uploaded++;
            if (uploaded >= 1 && Stopwatch.GetTimestamp() - start >= budgetTicks) break;
        }
        return !_ready.IsEmpty;
    }

    unsafe void UploadOne(nint device, nint context, ReadyBitmap bmp)
    {
        var side = (uint)bmp.Side;
        var desc = new Dx.Texture2DDesc
        {
            Width = side,
            Height = side,
            MipLevels = 0, // full mip chain for crisp minification during zoom
            ArraySize = 1,
            Format = Dx.DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc = new Dx.SampleDesc { Count = 1, Quality = 0 },
            Usage = Dx.D3D11_USAGE_DEFAULT,
            BindFlags = Dx.D3D11_BIND_SHADER_RESOURCE | Dx.D3D11_BIND_RENDER_TARGET,
            CPUAccessFlags = 0,
            MiscFlags = Dx.D3D11_RESOURCE_MISC_GENERATE_MIPS,
        };
        if (Dx.CreateTexture2D(device, ref desc, null, out var tex) < 0 || tex == 0) return;
        if (Dx.CreateShaderResourceView(device, tex, 0, out var srv) < 0 || srv == 0)
        {
            Marshal.Release(tex);
            return;
        }
        fixed (byte* p = bmp.Pixels)
            Dx.UpdateSubresource(context, tex, 0, 0, p, side * 4, 0);
        Dx.GenerateMips(context, srv);

        // Including mipmap chain (~4/3x)
        var bytes = (long)side * side * 4 * 4 / 3;
        var entry = new GpuEntry { Id = bmp.Id, Texture = tex, Srv = srv, Bytes = bytes };

        if (bmp.Large)
            Insert(_largeMap, _largeLru, ref _largeBytes, LargeBudgetBytes, entry);
        else
            Insert(_smallMap, _smallLru, ref _smallBytes, SmallBudgetBytes, entry);
    }

    static void Insert(Dictionary<string, LinkedListNode<GpuEntry>> map, LinkedList<GpuEntry> lru, ref long totalBytes, long budget, GpuEntry entry)
    {
        if (map.TryGetValue(entry.Id, out var existing))
        {
            lru.Remove(existing);
            totalBytes -= existing.Value.Bytes;
            ReleaseEntry(existing.Value);
            map.Remove(entry.Id);
        }
        var node = lru.AddFirst(entry);
        map[entry.Id] = node;
        totalBytes += entry.Bytes;
        while (totalBytes > budget && lru.Count > 1)
        {
            var last = lru.Last!;
            lru.RemoveLast();
            map.Remove(last.Value.Id);
            totalBytes -= last.Value.Bytes;
            ReleaseEntry(last.Value);
        }
    }

    static void ReleaseEntry(GpuEntry e)
    {
        if (e.Srv != 0) { Marshal.Release(e.Srv); e.Srv = 0; }
        if (e.Texture != 0) { Marshal.Release(e.Texture); e.Texture = 0; }
    }

    static unsafe nint CreateWicFactory()
    {
        Dx.CoInitializeEx(0, 0 /* COINIT_MULTITHREADED */);
        var clsid = Dx.CLSID_WICImagingFactory;
        var iid = Dx.IID_IWICImagingFactory;
        Dx.CoCreateInstance(ref clsid, 0, 1 /* CLSCTX_INPROC_SERVER */, ref iid, out var factory);
        return factory;
    }

    async Task WorkerLoop(CancellationToken ct)
    {
        var factory = CreateWicFactory();

        try
        {
            while (!ct.IsCancellationRequested)
            {
                DecodeJob? job;
                lock (_queueLock)
                {
                    if (_visibleStack.Count > 0)
                    {
                        job = _visibleStack[^1]; // LIFO: newest visible tile first
                        _visibleStack.RemoveAt(_visibleStack.Count - 1);
                    }
                    else if (_prefetchQueue.Count > 0)
                    {
                        job = _prefetchQueue[^1];
                        _prefetchQueue.RemoveAt(_prefetchQueue.Count - 1);
                    }
                    else
                    {
                        _activeWorkers--;
                        return;
                    }
                }

                var key = (job.Large ? "L:" : "S:") + job.Item.MediaId;
                try
                {
                    if (factory == 0) continue;
                    var side = job.Large ? Thumbnails.LargeSide : Thumbnails.SmallSide;
                    var path = await ResolveFileAsync(job.Item, side, ct);
                    if (path == null || ct.IsCancellationRequested) continue;

                    var decoded = DecodeSquareBgra(factory, path);
                    if (decoded is { } d && !ct.IsCancellationRequested)
                    {
                        _ready.Enqueue(new ReadyBitmap { Id = job.Item.MediaId, Large = job.Large, Side = d.Side, Pixels = d.Pixels });
                        Loaded?.Invoke();
                    }
                    else
                    {
                        lock (_queueLock) _failed.Add(key);
                    }
                }
                catch (OperationCanceledException) { return; }
                catch
                {
                    lock (_queueLock) _failed.Add(key);
                }
                finally
                {
                    lock (_queueLock) _inflight.Remove(key);
                }
            }
        }
        finally
        {
            if (factory != 0) Marshal.Release(factory);
            lock (_queueLock)
            {
                if (ct.IsCancellationRequested && _activeWorkers > 0) _activeWorkers--;
            }
        }
    }

    static async Task<string?> ResolveFileAsync(FeedItem item, uint side, CancellationToken ct)
    {
        if (item.IsVideo)
            return await Thumbnails.VideoPosterPath(item.Path, side, ct);
        var made = Path.Combine(Thumbnails.CacheDir, side.ToString(), item.MediaId + ".jpg");
        if (File.Exists(made)) return made;
        return await Thumbnails.PhotoPath(item.MediaId, side, ct);
    }

    static unsafe (int Side, byte[] Pixels)? DecodeSquareBgra(nint factory, string path)
    {
        nint decoder = 0, frame = 0, converter = 0;
        try
        {
            fixed (char* pPath = path)
            {
                if (Dx.WicCreateDecoderFromFilename(factory, pPath, out decoder) < 0 || decoder == 0) return null;
            }
            if (Dx.WicDecoderGetFrame(decoder, 0, out frame) < 0 || frame == 0) return null;
            if (Dx.WicCreateFormatConverter(factory, out converter) < 0 || converter == 0) return null;
            var fmt = Dx.GUID_WICPixelFormat32bppBGRA;
            if (Dx.WicConverterInitialize(converter, frame, ref fmt) < 0) return null;
            if (Dx.WicSourceGetSize(converter, out var w, out var h) < 0 || w == 0 || h == 0) return null;

            var side = Math.Min(w, h);
            var rect = new Dx.WicRect
            {
                X = (int)((w - side) / 2),
                Y = (int)((h - side) / 2),
                Width = (int)side,
                Height = (int)side,
            };
            var stride = side * 4;
            var bytes = new byte[stride * side];
            fixed (byte* pBuf = bytes)
            {
                if (Dx.WicSourceCopyPixels(converter, &rect, stride, (uint)bytes.Length, pBuf) < 0) return null;
            }
            return ((int)side, bytes);
        }
        finally
        {
            if (converter != 0) Marshal.Release(converter);
            if (frame != 0) Marshal.Release(frame);
            if (decoder != 0) Marshal.Release(decoder);
        }
    }

    /// Releases GPU textures (e.g. on device lost) without disposing the cache instance.
    public void ReleaseGpuResources()
    {
        foreach (var entry in _smallLru) ReleaseEntry(entry);
        _smallLru.Clear();
        _smallMap.Clear();
        _smallBytes = 0;

        foreach (var entry in _largeLru) ReleaseEntry(entry);
        _largeLru.Clear();
        _largeMap.Clear();
        _largeBytes = 0;

        while (_ready.TryDequeue(out _)) { }
        lock (_queueLock)
        {
            _visibleStack.Clear();
            _prefetchQueue.Clear();
            _inflight.Clear();
            _failed.Clear();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _cts.Cancel();
        _cts.Dispose();
        ReleaseGpuResources();
    }
}
