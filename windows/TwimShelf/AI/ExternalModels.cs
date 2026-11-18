// Tagging with external models (any OpenAI-compatible service): the services the person added
// (shared by every device of the sync account through the core's settings), their API keys (in this
// device's secrets, bound to the service's origin), and the prompts. As the other apps do it.
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
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

    public string Question(IReadOnlyList<string>? existing = null, IReadOnlyList<string>? vocabulary = null, string? postText = null)
    {
        var q = Prompt;
        if (existing is { Count: > 0 }) q += "\n\n" + Existing.Replace("{existing}", string.Join(L("list.separator"), existing));
        if (vocabulary is { Count: > 0 }) q += "\n\n" + Vocabulary.Replace("{tags}", string.Join(L("list.separator"), vocabulary));
        var clean = CleanContext(postText);
        if (clean != null) q += "\n\n" + Context.Replace("{text}", clean);
        return q;
    }

    public static string? CleanContext(string? text)
    {
        if (text == null) return null;
        var v = Regex.Replace(text, @"https?://\S+", "");
        v = Regex.Replace(v, "@[A-Za-z0-9_]{1,15}", "").Trim();
        if (v.Length == 0) return null;
        var si = new StringInfo(v);
        return si.LengthInTextElements > 300 ? si.SubstringByTextElements(0, 300) + "…" : v;
    }
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

public sealed partial class ExternalAI(ExternalModels models)
{
    static readonly HttpClient Client = new(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = System.Threading.Timeout.InfiniteTimeSpan };
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(120);

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

    /// The request, byte for byte the other apps' (keys sorted as Swift's encoder gives them).
    public static string Body(string model, string system, string question, byte[] jpeg, JsonObject? thinkingOff = null)
    {
        var o = new JsonObject
        {
            ["max_tokens"] = 300,
            ["messages"] = new JsonArray(
                new JsonObject { ["content"] = system, ["role"] = "system" },
                new JsonObject
                {
                    ["content"] = new JsonArray(
                        new JsonObject { ["text"] = question, ["type"] = "text" },
                        new JsonObject { ["image_url"] = new JsonObject { ["url"] = "data:image/jpeg;base64," + Convert.ToBase64String(jpeg) }, ["type"] = "image_url" }),
                    ["role"] = "user",
                }),
            ["model"] = model,
            ["stream"] = false,
            ["temperature"] = 0.1,
        };
        if (thinkingOff != null) foreach (var (k, v) in thinkingOff) o[k] = v?.DeepClone();
        return o.ToJsonString(new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping })
            .Replace("\"temperature\":0.1", "\"temperature\":0.10000000000000001");
    }

    /// What turns a model's reasoning off, as this service spells it. Services that answer with the
    /// result alone get nothing; the rest of the world (local servers) gets the usual words.
    public static JsonObject? ThinkingOff(string host)
    {
        var h = host.ToLowerInvariant();
        bool At(string d) => h == d || h.EndsWith("." + d, StringComparison.Ordinal);
        if (At("openai.com") || At("openai.azure.com") || At("x.ai") || At("anthropic.com")) return null;
        if (At("deepseek.com") || At("bigmodel.cn") || At("z.ai")) return new JsonObject { ["thinking"] = new JsonObject { ["type"] = "disabled" } };
        if (At("aliyuncs.com") || At("siliconflow.cn") || At("siliconflow.com")) return new JsonObject { ["enable_thinking"] = false };
        if (At("openrouter.ai")) return new JsonObject { ["reasoning"] = new JsonObject { ["enabled"] = false } };
        if (At("googleapis.com")) return new JsonObject { ["reasoning_effort"] = "none" };
        return new JsonObject { ["think"] = false, ["enable_thinking"] = false, ["chat_template_kwargs"] = new JsonObject { ["enable_thinking"] = false } };
    }

    /// Servers that refused the switch above: asked plainly from then on.
    static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> RefusedThinkingOff = new();

    async Task<byte[]> Send(ExternalModel model, string path, string? body, CancellationToken cancel)
    {
        cancel.ThrowIfCancellationRequested();
        var uri = Endpoint(model.Url, path);
        var key = await models.ApiKey(model);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        timeout.CancelAfter(Timeout);
        using var request = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, uri);
        if (key != null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        if (body != null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        try
        {
            using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var ms = new MemoryStream();
            var buffer = new byte[65536];
            int n;
            while ((n = await stream.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (ms.Length + n > 2 * 1024 * 1024) throw new ExternalFailure(ExternalFailureKind.InvalidResponse);
                ms.Write(buffer, 0, n);
            }
            var data = ms.ToArray();
            if (!response.IsSuccessStatusCode)
            {
                string message;
                try
                {
                    var json = JsonNode.Parse(data);
                    var error = json?["error"];
                    message = error is JsonObject eo && eo["message"] is JsonValue mv && mv.TryGetValue<string>(out var m) ? m
                        : error is JsonValue ev && ev.TryGetValue<string>(out var es) ? es
                        : Encoding.UTF8.GetString(data.AsSpan(0, Math.Min(200, data.Length)));
                }
                catch { message = Encoding.UTF8.GetString(data.AsSpan(0, Math.Min(200, data.Length))); }
                if (key != null) message = message.Replace(key, "");
                throw new ExternalFailure(ExternalFailureKind.Http, (int)response.StatusCode, message);
            }
            return data;
        }
        catch (ExternalFailure) { throw; }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested) { throw new ExternalFailure(ExternalFailureKind.Cancelled); }
        catch (OperationCanceledException) { throw new ExternalFailure(ExternalFailureKind.Timeout); }
        // the system's reason (refused, no route, a certificate…): it names at most the host typed in
        catch (Exception e) { throw new ExternalFailure(ExternalFailureKind.Transport, detail: (e.InnerException ?? e).Message.Trim()); }
    }

    static JsonNode? Json(byte[] data)
    {
        try { return JsonNode.Parse(data); }
        catch { throw new ExternalFailure(ExternalFailureKind.InvalidResponse); }
    }

    public async Task<List<string>> AvailableModels(ExternalModel model, CancellationToken cancel = default)
    {
        var json = Json(await Send(model, "models", null, cancel));
        return json?["data"] is JsonArray a ? [.. a.OfType<JsonObject>().Select(r => r["id"] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null).OfType<string>()] : [];
    }

    [GeneratedRegex("^[\\t \\u00a0\\u1680\\u2000-\\u200a\\u202f\\u205f\\u3000]+|[\\t \\u00a0\\u1680\\u2000-\\u200a\\u202f\\u205f\\u3000]+$")]
    private static partial Regex Blank();

    public async Task<string> ModelName(ExternalModel model, CancellationToken cancel)
    {
        var v = Blank().Replace(model.Model, "");
        if (v.Length > 0) return v;
        var names = await AvailableModels(model, cancel);
        return names.Count > 0 ? names[0] : throw new ExternalFailure(ExternalFailureKind.NoModel);
    }

    public static string Answer(byte[] data)
    {
        var content = Json(data)?["choices"]?[0]?["message"]?["content"];
        if (content is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0) return s;
        if (content is JsonArray parts)
        {
            // (never the parts that hold the model's reasoning)
            var joined = string.Concat(parts.OfType<JsonObject>().Where(p => !(p["type"] is JsonValue k && k.TryGetValue<string>(out var type) && (type.Contains("think", StringComparison.OrdinalIgnoreCase) || type.Contains("reason", StringComparison.OrdinalIgnoreCase)))).Select(p => p["text"] is JsonValue t && t.TryGetValue<string>(out var x) ? x : ""));
            if (joined.Length > 0) return joined;
        }
        throw new ExternalFailure(ExternalFailureKind.Empty);
    }


    /// A model's answer as tags: a JSON list if there is one, else separated words; at most 12, each short.
    /// A model's reply as tags (TagReply.Parse: the rules every app shares).
    public static List<string> ParseTags(string raw) => TagReply.Parse(raw);

    public async Task<List<string>> Tags(ExternalModel model, byte[] jpeg, IReadOnlyList<string> existing, IReadOnlyList<string> vocabulary, string? postText, CancellationToken cancel)
    {
        var prompt = models.PromptFor(model.Id);
        var name = await ModelName(model, cancel);
        var question = prompt.Question(existing, vocabulary, postText);
        var off = RefusedThinkingOff.ContainsKey(model.Url) ? null : ThinkingOff(Endpoint(model.Url, "chat/completions").Host);
        byte[] data;
        try { data = await Send(model, "chat/completions", Body(name, prompt.System, question, jpeg, off), cancel); }
        catch (ExternalFailure e) when (off != null && e.Kind == ExternalFailureKind.Http && e.Status is 400 or 422)
        {
            RefusedThinkingOff[model.Url] = true;
            data = await Send(model, "chat/completions", Body(name, prompt.System, question, jpeg), cancel);
        }
        return ParseTags(Answer(data));
    }

    /// 测试: a small grey picture, to see the service answer.
    public async Task<List<string>> Test(ExternalModel model, CancellationToken cancel = default) =>
        await Tags(model, await TaggingImage.GrayJpeg(), [], [], null, cancel);
}
