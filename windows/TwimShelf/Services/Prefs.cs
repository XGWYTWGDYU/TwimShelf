// This device's display preferences, under the native apps' UserDefaults names, in the same file
// the Flutter app kept them (<data>\App\shared_preferences.json, keys prefixed "flutter."), so an
// upgrade keeps them.
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TwimShelf.Services;

public sealed class Prefs
{
    public static Prefs Instance { get; private set; } = null!;
    public event Action? Changed;

    const string Prefix = "flutter.";
    readonly string _file;
    readonly JsonObject _values;
    readonly Lock _lock = new();

    Prefs(string file, JsonObject values)
    {
        _file = file;
        _values = values;
    }

    public static void Load()
    {
        var file = Path.Combine(DataHome.AppDir, "shared_preferences.json");
        JsonObject values;
        try { values = JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? []; }
        catch { values = []; }
        Instance = new Prefs(file, values);
    }

    void Save()
    {
        string text;
        lock (_lock) text = _values.ToJsonString();
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_file)!);
            var tmp = _file + ".partial";
            File.WriteAllText(tmp, text);
            File.Move(tmp, _file, true);
        }
        catch { /* a read-only data folder: the preference lasts this session */ }
    }

    JsonNode? Get(string key) { lock (_lock) return _values[Prefix + key]; }
    bool Bool(string key, bool fallback) => Get(key) is JsonValue v && v.TryGetValue<bool>(out var b) ? b : fallback;
    // A number set this session is held as the type it was set with (an int, say), which
    // TryGetValue<long> refuses; read from the file it is a JSON element. Its text serves both.
    static string? NumberText(JsonNode? n) => n is JsonValue v && v.GetValueKind() == System.Text.Json.JsonValueKind.Number ? v.ToJsonString() : null;
    long? Long(string key) => NumberText(Get(key)) is { } t
        ? long.TryParse(t, System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out var l) ? l
        : double.TryParse(t, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? (long)d : null
        : null;
    double? Double(string key) => NumberText(Get(key)) is { } t && double.TryParse(t, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : null;
    public string? String(string key) => Get(key) is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;

    public void Set(string key, JsonNode? value, bool notify = true)
    {
        lock (_lock)
        {
            if (value == null) _values.Remove(Prefix + key);
            else _values[Prefix + key] = value;
        }
        Save();
        if (notify) Changed?.Invoke();
    }

    /// 清除所有数据: every setting; with keepAI, those of the AI models stay.
    public void Wipe(bool keepAI)
    {
        lock (_lock)
            foreach (var k in _values.Select(p => p.Key).ToList())
            {
                var key = k.StartsWith(Prefix) ? k[Prefix.Length..] : k;
                if (keepAI && (key.StartsWith("ai.") || key.StartsWith("models."))) continue;
                _values.Remove(k);
            }
        Save();
        Changed?.Invoke();
    }

    /// How 标签 is ordered: 0 by media, 1 by your tags, 2 by AI tags, 3 by name.
    public int TagSort { get => (int)Math.Clamp(Long("tags.sort") ?? 0, 0, 3); set => Set("tags.sort", value); }
    /// 浏览 by when things were added, newest first, instead of at random.
    public bool FeedByAdded { get => Bool("feed.sortByAdded", false); set => Set("feed.sortByAdded", value); }
    /// 应用锁: every opening asks first (Windows Hello).
    public bool AppLock { get => Bool("appLock.enabled", false); set => Set("appLock.enabled", value); }
    /// 使用 Claude Code 吉祥物.
    public bool Mascot { get => Bool("mascot.enabled", false); set => Set("mascot.enabled", value); }
    /// 仅用耳机播放声音.
    /// The maintenance rows of 关于 (ten taps on the icon), 损坏或丢失 and 损坏 among search words.
    public bool AboutExtras { get => Bool("about.extras", false); set => Set("about.extras", value); }
    /// 按帖子分组 in 浏览.
    public bool FeedGrouped { get => Bool("feed.grouped", true); set => Set("feed.grouped", value); }
    /// How many cards a row of 浏览 holds: 0 fewer, 1 medium, 2 more. The other apps keep one per
    /// orientation; a Windows window has none, so both are set together and the landscape one read.
    public int DensityPortrait { get => (int)(Long("feed.density.portrait") ?? 1); set => Set("feed.density.portrait", value); }
    public int DensityLandscape { get => (int)(Long("feed.density.landscape") ?? 1); set => Set("feed.density.landscape", value); }

    /// The columns of 浏览 for a width: one card per 400 at 适中, wider at 少, narrower at 多.
    public int FeedColumns(double width, double height)
    {
        var level = Math.Clamp(DensityLandscape, 0, 2);
        var per = 400 * new[] { 1.35, 1.0, 0.72 }[level];
        return (int)Math.Clamp(Math.Floor(width / per), 1, 4 + (level == 2 ? 2 : 0));
    }

    /// The sidebar's width, between 200 and 420.
    public double SidebarWidth { get => Math.Clamp(Double("sidebar.width") ?? 264, 200, 420); set => Set("sidebar.width", Math.Clamp(value, 200, 420), notify: false); }
    /// 检查更新: when it last looked (ms), and a version the person chose to skip.
    public long UpdateLastCheck { get => Long("update.lastCheck") ?? 0; set => Set("update.lastCheck", value, notify: false); }
    public string? UpdateSkipped { get => String("update.skipped"); set => Set("update.skipped", value, notify: false); }
    /// The photo grid's tile size (legacy setting) and zoom level (0 densest .. 2 largest).
    public double GridTile { get => Math.Clamp(Double("windows.grid.tile") ?? 160, 72, 400); set => Set("windows.grid.tile", value, notify: false); }
    public int GridLevel { get => (int)Math.Clamp(Long("windows.grid.level") ?? 1, 0, 2); set => Set("windows.grid.level", Math.Clamp(value, 0, 2), notify: false); }
    public double PlayerVolume { get => Math.Clamp(Double("player.volume") ?? 1.0, 0.0, 1.0); set => Set("player.volume", Math.Clamp(value, 0.0, 1.0), notify: false); }

    public JsonNode? Raw(string key) => Get(key);
}
