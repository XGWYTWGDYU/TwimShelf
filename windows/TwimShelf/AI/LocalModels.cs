// On-device models: llama.cpp (tl_llama.dll beside the program, CPU or Vulkan) with GGUF models from
// the core's catalog and model store, kept in <data>\App\Models as the Flutter app kept them.
// One job at a time, off the UI; a model stays loaded between pictures and goes 30 s after the last.
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI.Dispatching;
using TwimShelf.Core;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.AI;

public sealed class LocalModels
{
    public static LocalModels Instance { get; } = new();
    public event Action? Changed;

    public const string Format = "gguf";
    public List<CatalogEntry> Catalog { get; private set; } = [];
    public bool Supported { get; private set; }
    /// llama.cpp's devices (e.g. "Vulkan0 (…), CPU").
    public string? Devices { get; private set; }
    public List<ModelInfo> Installed { get; private set; } = [];
    public ModelDownloadStatus? Download { get; private set; }
    DispatcherQueueTimer? _poll;
    bool _started;

    public async Task Start()
    {
        if (_started) return;
        _started = true;
        var dir = DataHome.ModelsDir;
        Directory.CreateDirectory(dir);
        TlCore.SetModelsDirectory(dir);
        // no semantic search here: its embedding models are not offered
        try { Catalog = TlCore.ModelCatalog(Format).Where(c => !c.Embedder).ToList(); } catch { }
        try
        {
            Devices = await Llama.Init();
            Supported = true;
        }
        catch { Supported = false; }
        await Refresh();
    }

    public async Task Refresh()
    {
        try
        {
            Installed = await TlCore.Run(() => TlCore.InstalledModels().Where(m => m.Format == Format).ToList());
            Download = TlCore.ModelStatus();
        }
        catch { }
        Changed?.Invoke();
    }

    public ModelInfo? Find(string id) => Installed.FirstOrDefault(m => m.Id == id);
    public CatalogEntry? CatalogFor(string id) => Catalog.FirstOrDefault(c => c.Folder == id);
    public string Title(ModelInfo m) => CatalogFor(m.Id) is { } c ? L(c.NameKey) : m.Repo ?? m.Id;

    public void InstallCurated(CatalogEntry c)
    {
        TlCore.HubInstall(c.Format, c.Repo, null, c.Weights, c.Projector, c.Bytes, c.Folder);
        Watch();
    }

    public void InstallVariant(HubDetail d, HubVariant v)
    {
        TlCore.HubInstall(Format, d.Repo.Repo, d.Revision, v.Weights, v.Projector, v.Bytes, v.Folder);
        Watch();
    }

    public void CancelDownload() => TlCore.CancelModelDownload();

    /// Follows a model coming in (a download started here or from another device).
    public void Watch()
    {
        _poll?.Stop();
        _poll = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _poll.Interval = TimeSpan.FromMilliseconds(500);
        _poll.Tick += (_, _) =>
        {
            try { Download = TlCore.ModelStatus(); } catch { }
            if (Download?.Running == true) { Changed?.Invoke(); return; }
            _poll?.Stop();
            _ = Refresh();
        };
        _poll.Start();
        _ = Refresh();
    }

    public async Task Delete(string id)
    {
        await Unload();
        await TlCore.Run(() => TlCore.DeleteModel(id));
        await Refresh();
    }

    public Task Unload() => Supported ? Llama.UnloadAll() : Task.CompletedTask;

    /// Tags for one picture (the JPEG the tagger prepared: the same input on every device).
    public async Task<List<string>> Tags(string id, byte[] jpeg, string system, string question)
    {
        var m = Find(id) ?? throw new ExternalFailure(ExternalFailureKind.NoModel);
        var tmp = Path.Combine(Path.GetTempPath(), $"tl-tag-{DateTime.UtcNow.Ticks}.jpg");
        await File.WriteAllBytesAsync(tmp, jpeg);
        try
        {
            var raw = await Llama.Describe(Path.Combine(m.Path, m.Weights ?? ""), Path.Combine(m.Path, m.Projector ?? ""), tmp, system, question);
            return TagReply.Parse(raw, requireArray: true);
        }
        finally { try { File.Delete(tmp); } catch { } }
    }
}

/// llama.cpp through tl_llama.dll (flutter/tl_llama/src/tl_llama.h).
public static partial class Llama
{
    const string Lib = "tl_llama";
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial nint tl_llama_init(string? dir);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial nint tl_llama_load(string weights, string? projector, int gpuLayers, int context, int embeddings, out nint error);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] private static partial nint tl_llama_describe(nint m, string image, string system, string question, int maxTokens, out nint error);
    [LibraryImport(Lib)] private static partial void tl_llama_unload(nint m);
    [LibraryImport(Lib)] private static partial void tl_llama_free_string(nint s);

    static readonly SemaphoreSlim Gate = new(1, 1);
    static (string Key, nint Handle)? _tagger;
    static Timer? _idle;
    static string? _devices;

    /// A model's answer as text; what is half a character at the end is dropped.
    static unsafe string? Take(nint p)
    {
        if (p == 0) return null;
        var s = Encoding.UTF8.GetString(MemoryMarshal.CreateReadOnlySpanFromNullTerminated((byte*)p)).Replace("�", "");
        tl_llama_free_string(p);
        return s;
    }

    public static Task<string> Init() => Task.Run(() => _devices ??= Take(tl_llama_init(null)) ?? "");

    static async Task<T> Exclusive<T>(Func<T> body, bool idle = true)
    {
        _idle?.Dispose();
        await Gate.WaitAsync();
        try { return await Task.Run(body); }
        finally
        {
            Gate.Release();
            _idle?.Dispose();
            _idle = idle ? new Timer(_ => _ = UnloadAll(), null, 30000, Timeout.Infinite) : null;
        }
    }

    public static Task<string> Describe(string weights, string projector, string image, string system, string question, int maxTokens = 160, int gpuLayers = 999) =>
        Exclusive(() =>
        {
            var key = weights + "|" + projector;
            if (_tagger?.Key != key)
            {
                if (_tagger is { } old) tl_llama_unload(old.Handle);
                _tagger = null;
                var h = tl_llama_load(weights, projector, gpuLayers, 4096, 0, out var err);
                if (h == 0) throw new InvalidOperationException("load: " + (Take(err) ?? "?"));
                _tagger = (key, h);
            }
            var r = tl_llama_describe(_tagger.Value.Handle, image, system, question, maxTokens, out var e);
            return Take(r) ?? throw new InvalidOperationException("describe: " + (Take(e) ?? "?"));
        });

    public static Task UnloadAll() => Exclusive(() =>
    {
        if (_tagger is { } t) tl_llama_unload(t.Handle);
        _tagger = null;
        return 0;
    }, idle: false);
}
