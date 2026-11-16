// What the search field suggests while typing (flutter/app/lib/search/suggestions.dart): condition
// words, the term itself, matching tags, folders, recent searches; with a minus, what to leave out.
using TwimShelf.Core;
using TwimShelf.Services;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Search;

public enum SuggestionKind { Keyword, Term, Tag, Folder, History, ClearHistory, Empty }
public enum SuggestionTint { Accent, Folder, Secondary, Exclude }

public sealed record Suggestion(string Id, SuggestionKind Kind, string Label, string? Detail = null, string? Key = null, string Glyph = "",
    SuggestionTint Tint = SuggestionTint.Accent, bool Destructive = false);

public sealed record SuggestionSection(string Title, List<Suggestion> Rows);

public static class Suggestions
{
    const string Minus = "", FolderGlyph = "", TagGlyph = "", Clock = "";

    public static List<SuggestionSection> Sections(string raw, IReadOnlyList<string> keys, IReadOnlyList<TagCount> tags, IReadOnlyList<(string Name, long Count)> folders, IReadOnlyList<string> history, bool offerDamaged)
    {
        var typed = raw.Trim();
        var present = keys.ToHashSet();
        var terms = keys.Where(s => s.StartsWith("t:")).Select(s => s[2..].ToLowerInvariant()).ToHashSet();
        var lone = typed.Length == 1 && "-－−–".Contains(typed[0]);
        var negative = lone || TokenQuery.Negated(typed) != null;
        var q = (lone ? "" : TokenQuery.Negated(typed) ?? typed).ToLowerInvariant();

        List<TagCount> MatchingTags(bool excluding) => [.. tags
            .Where(t => t.Label.ToLowerInvariant().Contains(q) && (excluding ? t.Label != q : !terms.Contains(t.Label)))
            .OrderByDescending(t => t.Count).Take(excluding ? 6 : 8)];

        Suggestion FolderRow((string Name, long Count) f, bool excluding, bool picking = false) => new(
            (excluding && !picking ? "folder-minus-" : "folder-") + f.Name, SuggestionKind.Folder, f.Name,
            L(picking || excluding ? "search.row.mediaCount" : "search.row.onlyFolder", f.Count),
            (excluding ? "-" : "") + TokenQuery.FolderKey(f.Name), excluding ? Minus : FolderGlyph, excluding ? SuggestionTint.Exclude : SuggestionTint.Folder);

        if (keys.Count > 0 && (keys[^1] == TokenQuery.PendingFolder || keys[^1] == "-" + TokenQuery.PendingFolder))
        {
            var excluding = keys[^1] != TokenQuery.PendingFolder;
            var shown = folders.Where(f => q.Length == 0 || f.Name.ToLowerInvariant().Contains(q)).ToList();
            return
            [
                new(L(excluding ? "search.section.pickExcludedFolder" : "search.section.pickFolder"), shown.Count == 0
                    ? [new("noFolder", SuggestionKind.Empty, L(folders.Count == 0 ? "search.noFolders" : "search.noMatchingFolders"), Glyph: FolderGlyph)]
                    : [.. shown.Select(f => FolderRow(f, excluding, picking: true))]),
            ];
        }
        var o = new List<SuggestionSection>();
        var keywords = SearchKeyword.Values.Where(kw => (!negative || kw.Excludable) && (kw != SearchKeyword.Damaged || offerDamaged)
            && !present.Contains((negative ? "-" : "") + kw.Key) && kw.MatchesPrefix(q)).ToList();
        if (keywords.Count > 0)
            o.Add(new(L(negative ? "search.section.exclude" : "search.section.conditions"), [.. keywords.Select(kw => new Suggestion(
                "kw-" + (negative ? "minus-" : "") + kw.Id, SuggestionKind.Keyword, negative ? "−" + kw.Word : kw.Word,
                negative ? kw.ExcludeHint : kw.Hint, (negative ? "-" : "") + kw.Key, negative ? Minus : kw.Glyph, negative ? SuggestionTint.Exclude : SuggestionTint.Accent))]));
        if (negative)
        {
            if (q.Length > 0)
            {
                var rows = new List<Suggestion> { new("term-minus", SuggestionKind.Term, L("search.row.exclude", q), null, "-" + TokenQuery.TermKey(q), Minus, SuggestionTint.Exclude) };
                rows.AddRange(MatchingTags(true).Select(t => new Suggestion("tag-minus-" + t.Label, SuggestionKind.Tag, L("search.row.excludeTag", t.Label),
                    L("search.row.mediaCount", t.Count), "-" + TokenQuery.TermKey(t.Label.ToLowerInvariant()), TagGlyph, SuggestionTint.Exclude)));
                o.Add(new(L("search.section.content"), rows));
                var shown = folders.Where(f => f.Name.ToLowerInvariant().Contains(q) && !present.Contains("-" + TokenQuery.FolderKey(f.Name))).ToList();
                if (shown.Count > 0) o.Add(new(L("search.section.folders"), [.. shown.Select(f => FolderRow(f, true))]));
            }
            return o;
        }
        if (typed.Length > 0)
        {
            var rows = new List<Suggestion> { new("term", SuggestionKind.Term, L("search.row.searchFor", typed), null, TokenQuery.TermKey(q)) };
            rows.AddRange(MatchingTags(false).Select(t => new Suggestion("tag-" + t.Label, SuggestionKind.Tag, t.Label, L("search.row.mediaCount", t.Count), TokenQuery.TermKey(t.Label.ToLowerInvariant()), TagGlyph)));
            o.Add(new(L("search.section.content"), rows));
            var shown = folders.Where(f => f.Name.ToLowerInvariant().Contains(q)).ToList();
            if (shown.Count > 0) o.Add(new(L("search.section.folders"), [.. shown.Select(f => FolderRow(f, false))]));
        }
        else
        {
            var recent = history.Where(t => !terms.Contains(t)).Take(6).ToList();
            if (recent.Count > 0)
            {
                var rows = recent.Select(t => new Suggestion("recent-" + t, SuggestionKind.History, t, null, TokenQuery.TermKey(t), Clock, SuggestionTint.Secondary)).ToList();
                rows.Add(new("clearHistory", SuggestionKind.ClearHistory, L("search.clearHistory"), Glyph: "", Destructive: true));
                o.Add(new(L("search.section.recent"), rows));
            }
        }
        return o;
    }
}

/// This device's recent searches (the other apps' key, at most 12, newest first).
public static class SearchHistory
{
    const string Key = "search.history";
    public static List<string> Items => Prefs.Instance.Raw(Key) is System.Text.Json.Nodes.JsonArray a ? [.. a.Select(n => (string?)n ?? "").Where(s => s.Length > 0)] : [];

    public static void Add(string value)
    {
        var text = value.Trim();
        if (text.Length == 0) return;
        var next = new[] { text }.Concat(Items.Where(s => s != text)).Take(12);
        Prefs.Instance.Set(Key, new System.Text.Json.Nodes.JsonArray([.. next.Select(s => (System.Text.Json.Nodes.JsonNode?)System.Text.Json.Nodes.JsonValue.Create(s))]), notify: false);
    }

    public static void Clear() => Prefs.Instance.Set(Key, null, notify: false);
}
