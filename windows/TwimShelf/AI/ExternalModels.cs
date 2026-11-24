// Tagging with external models (any OpenAI-compatible service): the services the person added
// (shared by every device of the sync account through the core's settings), their API keys (in this
// device's secrets, bound to the service's origin), and the prompts. As the other apps do it.
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TwimShelf.Core;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.AI;

public sealed record ExternalModel(string Id, string Name = "", string Url = "", string Model = "")
{
    public static ExternalModel Create() => new("ext:" + Guid.NewGuid().ToString("D"));

    public string Host => Uri.TryCreate(Url, UriKind.Absolute, out var u) && u.Host.Length > 0 ? u.Host : Url;
    public string Title => Name.Length > 0 ? Name : Model.Length > 0 ? Model : Host;

    /// scheme://host:port of the service: an API key is only ever sent there.
    public string Origin
    {
        get
        {
            var value = Url.Trim();
            if (!Uri.TryCreate(value.Contains("://") ? value : "http://" + value, UriKind.Absolute, out var u) || u.Host.Length == 0) return value.ToLowerInvariant();
            var scheme = u.Scheme.ToLowerInvariant();
            var host = u.Host.ToLowerInvariant();
            if (host.Contains(':') && !host.StartsWith('[')) host = $"[{host}]";
            return $"{scheme}://{host}:{u.Port}";
        }
    }

    public JsonObject ToJson() => new() { ["id"] = Id, ["name"] = Name, ["url"] = Url, ["model"] = Model };
    public static ExternalModel FromJson(JsonNode j) => new((string)j["id"]!, (string?)j["name"] ?? "", (string?)j["url"] ?? "", (string?)j["model"] ?? "");
}

public sealed record AiPrompt(string System, string Prompt, string Context, string Existing, string Vocabulary)
{
    public static AiPrompt CatalogDefaults() => new(L("prompt.default.system"), L("prompt.default.prompt"), L("prompt.default.context"), L("prompt.default.existing"), L("prompt.default.vocabulary"));

    /// The prompts that ship with the app (assets/ai/<language>.txt, shared with the Flutter app).
    public static AiPrompt BundledDefaults()
    {
        var fallback = CatalogDefaults();
        try
        {
            using var s = typeof(AiPrompt).Assembly.GetManifestResourceStream($"ai.{L10n.LanguageTag}.txt")
                ?? typeof(AiPrompt).Assembly.GetManifestResourceStream("ai.en.txt");
            if (s == null) return fallback;
            using var r = new StreamReader(s);
            var sections = new Dictionary<string, string>();
            string? section = null;
            var lines = new List<string>();
            void Flush()
            {
                var v = string.Join('\n', lines).Trim();
                if (section != null && v.Length > 0) sections[section] = v;
                lines.Clear();
            }
            while (r.ReadLine() is { } line)
            {
                if (line.StartsWith('#')) continue;
                var t = line.Trim();
                if (t.StartsWith('[') && t.EndsWith(']')) { Flush(); section = t[1..^1]; }
                else lines.Add(line);
            }
            Flush();
            return FromJson(sections, fallback);
        }
        catch { return fallback; }
    }

    public static AiPrompt FromJson(IReadOnlyDictionary<string, string> d, AiPrompt? defaults)
    {
        var catalog = CatalogDefaults();
        var b = defaults ?? catalog;
        return new(d.GetValueOrDefault("system") ?? catalog.System, d.GetValueOrDefault("prompt") ?? catalog.Prompt,
            d.GetValueOrDefault("context") ?? catalog.Context, d.GetValueOrDefault("existing") ?? b.Existing, d.GetValueOrDefault("vocabulary") ?? b.Vocabulary);
    }

    public static AiPrompt? FromJson(JsonNode? j, AiPrompt? defaults)
    {
        if (j is not JsonObject o) return null;
        var d = new Dictionary<string, string>();
        foreach (var (k, v) in o) if (v is JsonValue jv && jv.TryGetValue<string>(out var s)) d[k] = s;
        return FromJson(d, defaults);
    }

    public JsonObject ToJson() => new() { ["system"] = System, ["prompt"] = Prompt, ["context"] = Context, ["existing"] = Existing, ["vocabulary"] = Vocabulary };
}

public sealed class ExternalModels
{
    public event Action? Changed;
    public AiPrompt Defaults { get; private set; } = AiPrompt.BundledDefaults();
    readonly SemaphoreSlim _writes = new(1, 1);
    const string PromptKey = "ai.modelPrompt.";

    public static bool IsExternal(string id) => id.StartsWith("ext:");

    static string? Shared(string key) { try { return TlCore.Setting(key); } catch { return null; } }
    static void SetShared(string key, string? value) => TlCore.SetSetting(key, value);

    JsonArray Array(string key)
    {
        try { return JsonNode.Parse(Shared(key) ?? "[]") as JsonArray ?? []; }
        catch { return []; }
    }

    public IReadOnlyList<ExternalModel> All
    {
        get
        {
            try { return Array("ai.external").Select(v => ExternalModel.FromJson(v!)).ToList(); }
            catch { return new List<ExternalModel>(); }
        }
    }

    public ExternalModel? Find(string id) => All.FirstOrDefault(m => m.Id == id);

    async Task Serial(Func<Task> work)
    {
        await _writes.WaitAsync();
        try { await work(); }
        finally { _writes.Release(); }
        Changed?.Invoke();
    }

    async Task<T> Serial<T>(Func<Task<T>> work)
    {
        await _writes.WaitAsync();
        try { return await work(); }
        finally { _writes.Release(); }
    }

    public Task Save(ExternalModel model) => Serial(() =>
    {
        if (!IsExternal(model.Id)) throw new ArgumentException(model.Id);
        if (model.Url.Trim().Length > 0) ExternalAI.Endpoint(model.Url, "models");
        var list = All.ToList();
        var i = list.FindIndex(m => m.Id == model.Id);
        if (i < 0) list.Add(model); else list[i] = model;
        SetShared("ai.external", new JsonArray([.. list.Select(m => (JsonNode)m.ToJson())]).ToJsonString());
        return Task.CompletedTask;
    });

    public Task Remove(string id) => Serial(async () =>
    {
        await SaveKey(id, null, null);
        var list = All.Where(m => m.Id != id).ToList();
        SetShared("ai.external", list.Count == 0 ? null : new JsonArray([.. list.Select(m => (JsonNode)m.ToJson())]).ToJsonString());
        SetShared(PromptKey + id, null);
    });

    static async Task SaveKey(string id, string? key, string? origin)
    {
        try
        {
            // fail closed: a credential never gets a new origin before the old one is removed
            await Secrets.Delete("ai.key." + id);
            if (string.IsNullOrEmpty(key))
            {
                await Secrets.Delete("ai.keyorigin." + id);
                return;
            }
            await Secrets.Write("ai.keyorigin." + id, origin!);
            await Secrets.Write("ai.key." + id, key);
        }
        catch (ExternalFailure) { throw; }
        catch { throw new ExternalFailure(ExternalFailureKind.SecretsUnavailable); }
    }

    public Task SetApiKey(ExternalModel model, string? key) => Serial(() =>
    {
        if (!string.IsNullOrEmpty(key)) ExternalAI.Endpoint(model.Url, "models");
        return SaveKey(model.Id, key, model.Origin);
    });

    public Task<string?> ApiKey(ExternalModel model) => Serial(async () =>
    {
        string? key, bound;
        try
        {
            key = await Secrets.Read("ai.key." + model.Id);
            bound = await Secrets.Read("ai.keyorigin." + model.Id);
        }
        catch { throw new ExternalFailure(ExternalFailureKind.SecretsUnavailable); }
        if (string.IsNullOrEmpty(key)) return null;
        if (string.IsNullOrEmpty(bound))
        {
            try { await Secrets.Write("ai.keyorigin." + model.Id, model.Origin); }
            catch { throw new ExternalFailure(ExternalFailureKind.SecretsUnavailable); }
            return key;
        }
        return bound == model.Origin ? key : null;
    });

    AiPrompt? Decoded(string? raw)
    {
        if (raw == null) return null;
        try { return AiPrompt.FromJson(JsonNode.Parse(raw), Defaults); }
        catch { return null; }
    }

    /// The prompt a model tags with: its own (shared by every device of the account), an old
    /// assigned set, the old common one, or the default.
    public AiPrompt PromptFor(string model) => Decoded(Shared(PromptKey + model)) ?? Assigned(model) ?? Decoded(Shared("ai.prompt")) ?? Defaults;

    AiPrompt? Assigned(string model)
    {
        try
        {
            var set = (JsonNode.Parse(Shared("ai.modelPrompts") ?? "{}") as JsonObject)?[model];
            if (set == null) return null;
            foreach (var v in Array("ai.prompts"))
                if ((string?)v?["id"] == (string?)set) return AiPrompt.FromJson(v!["prompt"], Defaults);
        }
        catch { }
        return null;
    }

    public Task SavePromptFor(string model, AiPrompt prompt) => Serial(() =>
    {
        SetShared(PromptKey + model, prompt.ToJson().ToJsonString());
        return Task.CompletedTask;
    });

    /// 清除所有数据: the API keys always go; the models' settings too with settings.
    public Task Forget(bool settings) => Serial(async () =>
    {
        foreach (var m in All)
        {
            try { await Secrets.Delete("ai.key." + m.Id); await Secrets.Delete("ai.keyorigin." + m.Id); } catch { }
        }
        if (settings)
        {
            Prefs.Instance.Set("ai.autotag", null, notify: false);
            Prefs.Instance.Set("ai.tagger.id", null, notify: false);
        }
    });

    /// A tagger when there is none or the chosen one has gone: the installed vision model that asks least.
    public async Task AdoptInstalled(LocalModels local)
    {
        var id = ActiveTaggerId;
        var vision = local.Installed.Where(m => m.Vision).ToList();
        if (id != null && (IsExternal(id) ? Find(id) != null : local.Find(id) != null)) return;
        if (vision.Count == 0)
        {
            if (id != null) await SetActiveTagger(null);
            return;
        }
        vision.Sort((a, b) => (local.CatalogFor(a.Id)?.RecommendGb ?? 1 << 30).CompareTo(local.CatalogFor(b.Id)?.RecommendGb ?? 1 << 30));
        await SetActiveTagger(vision[0].Id);
    }

    public bool AutoTag => Prefs.Instance.Raw("ai.autotag") is JsonValue v && v.TryGetValue<bool>(out var b) ? b : true;
    public string? ActiveTaggerId => Prefs.Instance.String("ai.tagger.id");
    public Task SetAutoTag(bool value) => Serial(() => { Prefs.Instance.Set("ai.autotag", value); return Task.CompletedTask; });
    public Task SetActiveTagger(string? value) => Serial(() => { Prefs.Instance.Set("ai.tagger.id", value); return Task.CompletedTask; });
}

/// Services as the core reaches them (core/src/ai/external.rs): the app keeps their list and keys,
/// the core sends the requests.
public sealed class ExternalAI(ExternalModels models)
{
    /// The address of `path` at the service `baseUrl`, as the core forms it: for checking what the
    /// user typed, and for binding a key to its origin.
    public static Uri Endpoint(string baseUrl, string path)
    {
        var v = baseUrl.Trim();
        if (!v.Contains("://")) v = "http://" + v;
        v = v.TrimEnd('/');
        foreach (var tail in new[] { "/chat/completions", "/models" })
            if (v.EndsWith(tail)) v = v[..^tail.Length];
        if (!v.EndsWith("/v1")) v += "/v1";
        if (!Uri.TryCreate($"{v}/{path}", UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")
            || uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new ExternalFailure(ExternalFailureKind.BadUrl);
        return uri;
    }

    /// `model` as the core takes it, with its key from this device's credential store.
    public async Task<JsonObject> Service(ExternalModel model)
    {
        Endpoint(model.Url, "models");
        var key = await models.ApiKey(model);
        return new JsonObject { ["kind"] = "external", ["id"] = model.Id, ["url"] = model.Url, ["model"] = model.Model, ["key"] = key };
    }

    public async Task<List<string>> AvailableModels(ExternalModel model, CancellationToken cancel = default)
    {
        var service = await Service(model);
        cancel.ThrowIfCancellationRequested();
        try { return await TlCore.Run(() => TlCore.AiServiceModels(service)); }
        catch (AiException e) { throw ExternalFailure.FromCore(e); }
    }

    /// 测试: the tags for a plain grey picture, to see the service answer as a tagger should.
    public async Task<List<string>> Test(ExternalModel model, CancellationToken cancel = default) =>
        await CoreTags(await Service(model), "", [], [], null, cancel);

    /// The tags for the picture at `image` (empty: a plain grey one) from `model` (a local
    /// {kind, id} or a Service): the core prepares the picture, asks the model and reads its reply.
    public static async Task<List<string>> CoreTags(JsonObject model, string image, IReadOnlyList<string> existing, IReadOnlyList<string> vocabulary, string? postText, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var job = "tag-" + Guid.NewGuid().ToString("N");
        var request = new JsonObject
        {
            ["job"] = job, ["model"] = model, ["image"] = image,
            ["existing"] = new JsonArray(existing.Select(t => (JsonNode?)JsonValue.Create(t)).ToArray()),
            ["vocabulary"] = new JsonArray(vocabulary.Select(t => (JsonNode?)JsonValue.Create(t)).ToArray()),
            ["post_text"] = postText,
        };
        using var stop = cancel.Register(() => TlCore.AiCancel(job));
        try { return await TlCore.Run(() => TlCore.AiTag(request)); }
        catch (AiException e) { throw ExternalFailure.FromCore(e); }
    }
}
