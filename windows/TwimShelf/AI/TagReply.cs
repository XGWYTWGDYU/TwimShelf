// What a vision model's reply becomes: its tags, or why it gives none (ExternalFailure). On its
// own, with nothing of the app around it, so scripts/checks/ai_tags/windows.cs can check it
// against the cases every app's parser follows.
using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using static TwimShelf.Services.Strings;

namespace TwimShelf.AI;

/// BadTags: the model answered, but not with a list of tags (or with pieces of its syntax as tags);
/// NoTags: its list holds none.
public enum ExternalFailureKind { BadUrl, Http, NoModel, Empty, InvalidResponse, Transport, Timeout, Cancelled, SecretsUnavailable, Unreadable, BadTags, NoTags }

public sealed class ExternalFailure(ExternalFailureKind kind, int? status = null, string detail = "") : Exception(kind.ToString())
{
    public ExternalFailureKind Kind { get; } = kind;
    public int? Status { get; } = status;
    /// Sanitized server text, never a request, header or credential.
    public string Detail { get; } = detail;

    public string MessageKey => Kind switch
    {
        ExternalFailureKind.BadUrl => "models.external.err.url",
        ExternalFailureKind.Http => "models.external.err.status",
        ExternalFailureKind.NoModel => "models.external.err.noModel",
        ExternalFailureKind.Empty or ExternalFailureKind.InvalidResponse => "models.external.err.empty",
        ExternalFailureKind.Unreadable => "ai.err.unreadable",
        ExternalFailureKind.BadTags => "ai.err.badReply",
        ExternalFailureKind.NoTags => "ai.err.noTags",
        _ => "common.notDone",
    };

    public string Text
    {
        get
        {
            var label = Status == null ? L(MessageKey) : L(MessageKey, Status);
            return Detail.Length == 0 ? label : L("format.labelValue", label, Detail);
        }
    }
}

public static partial class TagReply
{
    // what is trimmed from a tag's ends: spaces, quotes, brackets, full stops
    [GeneratedRegex("^[\\s\"'“”\\[\\]()（）。.]+|[\\s\"'“”\\[\\]()（）。.]+$")]
    private static partial Regex Edge();

    /// A model's reply as tags, by the rules every app shares (scripts/checks/ai_tags/cases.json):
    /// a JSON array of strings (after a reasoning block or inside a code fence), or, from a reply
    /// with no JSON in it at all, a list split at commas and the like. Anything else, or a tag that
    /// is a piece of the reply's syntax (`}`, `harley }`), refuses the whole reply (BadTags): a
    /// model saying that is not working, and its other words are no better. An empty list is
    /// NoTags. Either way the analysis failed, and nothing is written.
    public static List<string> Parse(string raw, bool requireArray = false)
    {
        static ExternalFailure Bad() => new(ExternalFailureKind.BadTags);
        var text = raw.Trim();
        var structured = requireArray;
        var delimiters = new[] { ("<think>", "</think>"), ("<|channel>thought", "<channel|>") };
        var explicitDelimiters = delimiters.Where(pair => text.StartsWith(pair.Item1, StringComparison.Ordinal)).ToArray();
        foreach (var (opening, closing) in explicitDelimiters.Length == 0 ? delimiters : explicitDelimiters)
        {
            var end = text.IndexOf(closing, StringComparison.Ordinal);
            if (end >= 0)
            {
                var prefix = text[..end];
                if (prefix.Contains(opening, StringComparison.Ordinal) && !prefix.StartsWith(opening, StringComparison.Ordinal)) throw Bad();
                text = text[(end + closing.Length)..].Trim();
                structured = true;
                break;
            }
            if (text.StartsWith(opening, StringComparison.Ordinal)) throw Bad();
        }
        if (new[] { "<think>", "</think>", "<|channel>", "<channel|>" }
            .Any(marker => text.Contains(marker, StringComparison.Ordinal))) throw Bad();
        if (text.StartsWith("```", StringComparison.Ordinal))
        {
            var nl = text.IndexOf('\n');
            text = nl < 0 ? "" : text[(nl + 1)..].Trim();
            if (text.EndsWith("```", StringComparison.Ordinal)) text = text[..^3].Trim();
            else if (structured) throw Bad();
        }
        List<string> items;
        int a = text.IndexOf('['), b = text.LastIndexOf(']');
        if (a >= 0 || b >= 0)
        {
            if (a < 0 || b < a) throw Bad();
            var outside = text[..a] + text[(b + 1)..];
            if (structured && !string.IsNullOrWhiteSpace(outside)) throw Bad();
            if (outside.IndexOfAny(['[', ']', '{', '}']) >= 0) throw Bad();
            JsonNode? node;
            try { node = JsonNode.Parse(text[a..(b + 1)]); } catch { throw Bad(); }
            if (node is not JsonArray list) throw Bad();
            items = [];
            foreach (var n in list)
            {
                if (n is not JsonValue v || v.GetValueKind() != System.Text.Json.JsonValueKind.String) throw Bad();
                items.Add(v.GetValue<string>());
            }
        }
        else
        {
            if (structured && text.Length != 0) throw Bad();
            if (text.IndexOfAny(['{', '}', ':', '"']) >= 0) throw Bad();
            items = [.. Regex.Split(text, "[,，、;；\n#]")];
        }
        var seen = new HashSet<string>();
        var result = new List<string>();
        foreach (var item in items)
        {
            var clean = Edge().Replace(item, "").ToLowerInvariant();
            if (clean.Length == 0) continue;
            var fragment = clean.Any(c => char.IsControl(c) || "{}[]<>:\"\\`".Contains(c));
            var punctuation = clean.All(c => (c < 128 && (char.IsPunctuation(c) || char.IsSymbol(c))) || char.IsWhiteSpace(c));
            if (fragment || punctuation) throw Bad();
            if (new StringInfo(clean).LengthInTextElements <= 12 && seen.Add(clean)) result.Add(clean);
        }
        if (result.Count == 0) throw new ExternalFailure(ExternalFailureKind.NoTags);
        return result.GetRange(0, Math.Min(12, result.Count));
    }
}
