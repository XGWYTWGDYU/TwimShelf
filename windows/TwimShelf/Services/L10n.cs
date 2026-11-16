// The app's strings: the same catalogs as every other app (flutter/app/assets/l10n, exported
// from Apple/Resources/Localizable.xcstrings by scripts/to_flutter.py), embedded in the exe.
// Formats are Apple's (%@, %d, %1$@ …), read as the Flutter app reads them.
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace TwimShelf.Services;

public static partial class L10n
{
    public static readonly string[] Languages = ["en", "zh-Hans", "zh-Hant", "ja"];
    public const string AppName = "TwimShelf";

    static readonly Dictionary<string, Dictionary<string, JsonElement>> Catalogs = [];
    public static string LanguageTag { get; private set; } = "en";

    /// The language of a Windows locale name (zh-CN, zh-Hant-TW, ja-JP …).
    public static string TagFor(string name)
    {
        var parts = name.Split('-');
        var language = parts[0].ToLowerInvariant();
        if (language == "zh")
        {
            if (parts.Any(p => p.Equals("Hant", StringComparison.OrdinalIgnoreCase))) return "zh-Hant";
            if (parts.Any(p => p.Equals("Hans", StringComparison.OrdinalIgnoreCase))) return "zh-Hans";
            return parts.Skip(1).Any(p => p is "TW" or "HK" or "MO") ? "zh-Hant" : "zh-Hans";
        }
        return language == "ja" ? "ja" : "en";
    }

    public static void Load()
    {
        var asm = typeof(L10n).Assembly;
        foreach (var language in Languages)
        {
            using var s = asm.GetManifestResourceStream($"l10n.{language}.json");
            if (s == null) continue;
            using var doc = JsonDocument.Parse(s);
            Catalogs[language] = doc.RootElement.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.Clone());
        }
        LanguageTag = TagFor(CultureInfo.CurrentUICulture.Name);
    }

    public static bool Has(string key) => Catalogs.TryGetValue(LanguageTag, out var c) && c.ContainsKey(key) || Catalogs.TryGetValue("en", out var e) && e.ContainsKey(key);

    static string Template(string key, string language, object?[] args)
    {
        JsonElement value;
        if (!(Catalogs.TryGetValue(language, out var c) && c.TryGetValue(key, out value))
            && !(Catalogs.TryGetValue("en", out var en) && en.TryGetValue(key, out value)))
            return key;
        if (value.ValueKind == JsonValueKind.String) return value.GetString() ?? key;
        if (value.ValueKind == JsonValueKind.Object)
        {
            long? count = null;
            foreach (var a in args)
                if (a is int or long) { count = Convert.ToInt64(a); break; }
            var form = language == "en" && count == 1 ? "one" : "other";
            foreach (var f in new[] { form, "other", "one" })
                if (value.TryGetProperty(f, out var v) && v.ValueKind == JsonValueKind.String) return v.GetString() ?? key;
        }
        return key;
    }

    public static string Format(string key, params object?[] args) => Apply(Template(key, LanguageTag, args), args).Replace("{app}", AppName);

    /// Every language's wording of a key (search words typed in any language).
    public static List<string> EveryLanguage(string key)
    {
        var values = new List<string> { Format(key) };
        foreach (var language in Languages)
            if (Catalogs.TryGetValue(language, out var c) && c.ContainsKey(key))
            {
                var v = Apply(Template(key, language, []), []);
                if (!values.Contains(v)) values.Add(v);
            }
        return values;
    }

    [GeneratedRegex(@"%%|%(?:(\d+)\$)?([-+ #0']*)(\d*)(?:\.(\d+))?(?:ll|hh|[lhqztj])?([@diufFeEgGxXo])")]
    private static partial Regex Specifier();

    static string Apply(string template, object?[] args)
    {
        // Swift returns the untranslated format verbatim when there are no arguments.
        if (args.Length == 0) return template;
        var next = 0;
        return Specifier().Replace(template, m =>
        {
            if (m.Value == "%%") return "%";
            var index = m.Groups[1].Success ? int.Parse(m.Groups[1].Value) - 1 : next++;
            if (index < 0 || index >= args.Length) return m.Value;
            var arg = args[index];
            var kind = m.Groups[5].Value[0];
            int? precision = m.Groups[4].Success && m.Groups[4].Value.Length > 0 ? int.Parse(m.Groups[4].Value) : null;
            string value;
            if (kind == '@') value = Convert.ToString(arg, CultureInfo.CurrentCulture) ?? "";
            else if ("fFeEgG".Contains(kind))
            {
                var d = arg is IConvertible c ? c.ToDouble(CultureInfo.InvariantCulture) : 0;
                if (!double.IsFinite(d)) d = 0;
                value = char.ToLowerInvariant(kind) switch
                {
                    'e' => d.ToString("E" + (precision ?? 6), CultureInfo.InvariantCulture),
                    'g' => d.ToString("G" + (precision ?? 6), CultureInfo.InvariantCulture),
                    _ => d.ToString("F" + (precision ?? 6), CultureInfo.InvariantCulture),
                };
                if (char.IsLower(kind)) value = value.ToLowerInvariant();
            }
            else
            {
                long n = arg switch
                {
                    null => 0,
                    double dd => double.IsFinite(dd) ? (long)dd : 0,
                    float ff => float.IsFinite(ff) ? (long)ff : 0,
                    IConvertible c => long.TryParse(Convert.ToString(c, CultureInfo.InvariantCulture), out var p) ? p : c.ToInt64(CultureInfo.InvariantCulture),
                    _ => 0,
                };
                value = kind switch
                {
                    'x' => n.ToString("x"),
                    'X' => n.ToString("X"),
                    'o' => Convert.ToString(n, 8),
                    _ => n.ToString(CultureInfo.InvariantCulture),
                };
            }
            var flags = m.Groups[2].Value;
            if (kind != '@' && !value.StartsWith('-'))
            {
                if (flags.Contains('+')) value = "+" + value;
                else if (flags.Contains(' ')) value = " " + value;
            }
            var width = m.Groups[3].Value.Length > 0 ? int.Parse(m.Groups[3].Value) : 0;
            if (flags.Contains('-')) return value.PadRight(width);
            if (flags.Contains('0') && kind != '@' && value.Length > 0)
            {
                if ("-+ ".Contains(value[0])) return value[0] + value[1..].PadLeft(Math.Max(0, width - 1), '0');
                return value.PadLeft(width, '0');
            }
            return value.PadLeft(width);
        });
    }
}

public static class Strings
{
    /// L("key", args…): a string of the catalogs, as in the other apps.
    public static string L(string key, params object?[] args) => L10n.Format(key, args);
}
