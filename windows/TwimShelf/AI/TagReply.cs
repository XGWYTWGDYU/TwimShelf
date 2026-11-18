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

    // a label before a plain list ("Tags: cat, dog")
    [GeneratedRegex("^[^,，、;；\n:：{}\"]{1,24}[:：]\\s*")]
    private static partial Regex Label();

    /// A model's reply as tags, by the rules every app shares (scripts/checks/ai_tags/cases.json):
    /// a list in brackets (after a reasoning block, inside a code fence or a `{"tags": …}`, cut off
    /// by the length limit, with single quotes), or, from a reply with no brackets at all, a list
    /// split at commas and the like. What is no tag in a good list (`}`, a number) is left out. A
    /// reply that is no list, or holds nothing but such pieces, is BadTags; an empty list is
    /// NoTags. Either way the analysis failed, and nothing is written.
    public static List<string> Parse(string raw)
    {
        static ExternalFailure Bad() => new(ExternalFailureKind.BadTags);
        var text = WithoutThinking(raw).Trim();
        if (text.StartsWith("```", StringComparison.Ordinal))
        {
            var nl = text.IndexOf('\n');
            text = nl < 0 ? "" : text[(nl + 1)..].Trim();
            if (text.EndsWith("```", StringComparison.Ordinal)) text = text[..^3].Trim();
        }
        List<string> items;
        int a = text.IndexOf('['), b = text.LastIndexOf(']');
        if (a >= 0 || b >= 0)
        {
            if (a < 0 || (b >= 0 && b < a)) throw Bad();
            char[] brackets = ['[', ']', '{', '}'];
            var before = text[..a].Trim();
            var after = b < 0 ? "" : text[(b + 1)..].Trim();
            var wrapped = before.StartsWith('{') && before[1..].IndexOfAny(brackets) < 0 && (after == "}" || b < 0);
            if (!wrapped && (before + after).IndexOfAny(brackets) >= 0) throw Bad();
            items = ListItems(text[(a + 1)..(b < 0 ? text.Length : b)], b < 0);
        }
        else
        {
            if (ThinkingAloud().IsMatch(text)) throw Bad();
            text = Label().Replace(text, "", 1);
            if (text.IndexOfAny(['{', '}', ':', '"']) >= 0) throw Bad();
            items = [.. Regex.Split(text, "[,，、;；\n#]")];
        }
        var seen = new HashSet<string>();
        var result = new List<string>();
        var pieces = false;
        foreach (var item in items)
        {
            var clean = Edge().Replace(item, "").ToLowerInvariant();
            if (clean.Length == 0) continue;
            var fragment = clean.Any(c => char.IsControl(c) || "{}[]<>:\"\\`".Contains(c));
            var punctuation = clean.All(c => (c < 128 && (char.IsPunctuation(c) || char.IsSymbol(c))) || char.IsWhiteSpace(c));
            if (fragment || punctuation) { pieces = true; continue; }
            if (new StringInfo(clean).LengthInTextElements <= 12 && seen.Add(clean)) result.Add(clean);
            if (result.Count == 12) break;
        }
        if (result.Count == 0) throw new ExternalFailure(pieces ? ExternalFailureKind.BadTags : ExternalFailureKind.NoTags);
        return result;
    }

    // How models mark their reasoning, and a plain reply that is reasoning without any mark.
    static readonly string[] ThinkingEnds = ["</think>", "</thinking>", "</reasoning>", "</reason>", "[/think]", "◁/think▷", "</seed:think>", "<channel|>", "<|end_of_thought|>", "<|channel|>final<|message|>"];
    static readonly string[] ThinkingStarts = ["<think>", "<thinking>", "<reasoning>", "<reason>", "[think]", "◁think▷", "<seed:think>", "<|channel>thought", "<|channel|>analysis", "<|begin_of_thought|>"];
    [GeneratedRegex("^((thinking process|thinking|thoughts?|reasoning|analysis)\\s*[:：]|let me|let's|okay,|ok,|hmm|the user|the image|this image|思考|嗯|好的|首先|用户)", RegexOptions.IgnoreCase)]
    private static partial Regex ThinkingAloud();

    /// What follows the model's reasoning. Reasoning that never ended (the length limit) is no answer.
    static string WithoutThinking(string raw)
    {
        var text = raw;
        foreach (var end in ThinkingEnds)
        {
            var at = text.LastIndexOf(end, StringComparison.OrdinalIgnoreCase);
            if (at >= 0) text = text[(at + end.Length)..];
        }
        if (ThinkingStarts.Any(s => text.Contains(s, StringComparison.OrdinalIgnoreCase))) throw new ExternalFailure(ExternalFailureKind.BadTags);
        return text;
    }

    /// The entries between a list's brackets. `cutOff`: the reply stopped inside the list, and what
    /// it was still writing is left out.
    static List<string> ListItems(string c, bool cutOff)
    {
        var items = new List<string>();
        var i = 0;
        while (i < c.Length)
        {
            if (c[i] == ',' || char.IsWhiteSpace(c[i])) { i++; continue; }
            var close = c[i] switch { '"' => '"', '\'' => '\'', '“' => '”', '‘' => '’', _ => '\0' };
            if (close != '\0')
            {
                var word = new System.Text.StringBuilder();
                int j = i + 1;
                var closed = false;
                while (j < c.Length)
                {
                    if (c[j] == '\\' && j + 1 < c.Length)
                    {
                        var e = c[j + 1];
                        if (e is 'n' or 't' or 'r') { word.Append(' '); j += 2; }
                        else if (e == 'u')
                        {
                            if (j + 5 >= c.Length || !int.TryParse(c.AsSpan(j + 2, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var v)) throw new ExternalFailure(ExternalFailureKind.BadTags);
                            word.Append((char)v);
                            j += 6;
                        }
                        else { word.Append(e); j += 2; }
                        continue;
                    }
                    if (c[j] == close)
                    {
                        // an apostrophe inside a word in single quotes (dog's) is not the end
                        var k = j + 1;
                        while (k < c.Length && char.IsWhiteSpace(c[k])) k++;
                        if (close != '\'' || k >= c.Length || c[k] == ',') { closed = true; j++; break; }
                    }
                    word.Append(c[j]);
                    j++;
                }
                if (!closed) break;
                items.Add(word.ToString());
                i = j;
            }
            else
            {
                var j = c.IndexOf(',', i);
                if (j < 0) j = c.Length;
                var word = c[i..j].Trim();
                if (word.IndexOfAny(['[', ']', '{', '}']) >= 0) throw new ExternalFailure(ExternalFailureKind.BadTags);
                if (!(cutOff && j == c.Length) && !double.TryParse(word, NumberStyles.Float, CultureInfo.InvariantCulture, out _) && word is not ("null" or "true" or "false")) items.Add(word);
                i = j;
            }
        }
        return items;
    }
}
