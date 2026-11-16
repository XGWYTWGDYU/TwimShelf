// Secrets (the X cookies, the sync account key): in the data folder (App\secrets.json), each value
// sealed (ChaCha20-Poly1305, by the core) under a key beside it (App\secrets.key) — the Flutter
// app's files, so an upgrade keeps them. Never plain text; they move with the data folder.
using System.Text.Json.Nodes;
using TwimShelf.Core;

namespace TwimShelf.Services;

public static class Secrets
{
    static readonly SemaphoreSlim Gate = new(1, 1);
    /// A run on a synthetic library keeps its secrets in memory (tests never touch the real ones).
    static readonly Dictionary<string, string>? Memory = Environment.GetEnvironmentVariable("TL_LIBRARY_DIR") != null ? [] : null;

    static (string File, string Key) Open()
    {
        var dir = DataHome.AppDir;
        Directory.CreateDirectory(dir);
        var keyPath = Path.Combine(dir, "secrets.key");
        string key;
        if (File.Exists(keyPath)) key = File.ReadAllText(keyPath).Trim();
        else
        {
            key = TlCore.SecretKey();
            File.WriteAllText(keyPath, key);
        }
        return (Path.Combine(dir, "secrets.json"), key);
    }

    static JsonObject ReadAll(string file)
    {
        if (!File.Exists(file)) return [];
        try { return JsonNode.Parse(File.ReadAllText(file)) as JsonObject ?? throw new FormatException(); }
        catch
        {
            // damaged: kept aside, never silently dropped (the app reports secrets as unavailable)
            File.Move(file, $"{file}.damaged-{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}");
            throw new IOException("secrets.unavailable");
        }
    }

    static void WriteAll(string file, JsonObject o)
    {
        var tmp = file + ".partial";
        File.WriteAllText(tmp, o.ToJsonString());
        File.Move(tmp, file, true);
    }

    /// The value, null when there is none. Throws when the secrets cannot be read.
    public static async Task<string?> Read(string key)
    {
        if (Memory != null) return Memory.GetValueOrDefault(key);
        await Gate.WaitAsync();
        try
        {
            return await Task.Run(() =>
            {
                var (f, k) = Open();
                var blob = (string?)ReadAll(f)[key];
                return blob == null ? null : TlCore.SecretOpen(k, blob);
            });
        }
        finally { Gate.Release(); }
    }

    /// An empty value deletes the key.
    public static async Task Write(string key, string value)
    {
        if (Memory != null) { if (value.Length == 0) Memory.Remove(key); else Memory[key] = value; return; }
        await Gate.WaitAsync();
        try
        {
            await Task.Run(() =>
            {
                var (f, k) = Open();
                var all = ReadAll(f);
                if (value.Length == 0) { if (!all.Remove(key)) return; }
                else all[key] = TlCore.SecretSeal(k, value);
                WriteAll(f, all);
            });
        }
        finally { Gate.Release(); }
    }

    public static Task Delete(string key) => Write(key, "");

    /// After the library opens: the stored cookies into the core. False when the secrets could not be read.
    public static async Task<bool> ApplyStoredCookies()
    {
        try
        {
            var auth = await Read("auth_token");
            var ct0 = await Read("ct0");
            TlCore.SetCookies(auth ?? "", ct0 ?? "");
            return true;
        }
        catch
        {
            TlCore.SetCookies("", "");
            return false;
        }
    }
}
