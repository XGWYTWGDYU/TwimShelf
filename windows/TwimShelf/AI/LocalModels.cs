// On-device models: run by the core (core/src/ai) with llama.cpp (tl_llama.dll beside the program:
// CUDA or Vulkan on the GPU the core chooses, never the processor) and GGUF models from the core's
// catalog and model store, kept in <data>\App\Models as the Flutter app kept them.
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
    /// The GPU models run on (e.g. "CUDA0 (NVIDIA GeForce RTX 4070)"), or the GPUs it chooses among;
    /// null where there is none (on-device AI is then off).
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
            var hw = await TlCore.Run(TlCore.AiHardware);
            var gpus = hw.GetProperty("gpus").EnumerateArray().Select(g => $"{g.GetProperty("name").GetString()} ({g.GetProperty("description").GetString()})").ToList();
            Devices = gpus.Count == 0 ? null : string.Join(", ", gpus);
            Supported = hw.GetProperty("engine").GetBoolean() && gpus.Count > 0;
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

    public Task Unload() => Supported ? TlCore.Run(TlCore.AiUnload) : Task.CompletedTask;
}
