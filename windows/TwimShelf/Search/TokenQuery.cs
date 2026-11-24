// The search field's capsules as a query, as the other apps read them (SearchQuery.swift,
// flutter/app/lib/search/query.dart): words, condition words (视频, 标签, 我的 …, in any language of the
// catalogs), "-word" to leave out, and a folder. Every filter of 浏览 is a search written as capsules.
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Search;

public enum SearchField { Tags, Text, Author }

public sealed record SearchKeyword(string Id, string Key, string Glyph)
{
    public static readonly SearchKeyword Tags = new("tags", "f:tags", "");
    public static readonly SearchKeyword Text = new("text", "f:text", "");
    public static readonly SearchKeyword Author = new("author", "f:author", "");
    public static readonly SearchKeyword Mine = new("mine", "s:mine", "");
    public static readonly SearchKeyword Ai = new("ai", "s:ai", "");
    public static readonly SearchKeyword Common = new("common", "s:common", "");
    public static readonly SearchKeyword All = new("all", "s:both", "");
    public static readonly SearchKeyword Video = new("video", "k:video", "");
    public static readonly SearchKeyword Photo = new("photo", "k:photo", "");
    public static readonly SearchKeyword Folder = new("folder", "p:folder", "");
    public static readonly SearchKeyword Recent = new("recent", "r:recent", "");
    public static readonly SearchKeyword External = new("external", "x:external", "");
    public static readonly SearchKeyword Album = new("album", "a:album", "");
    public static readonly SearchKeyword Reviewed = new("reviewed", "v:reviewed", "");
    public static readonly SearchKeyword Unreviewed = new("unreviewed", "v:unreviewed", "");
    public static readonly SearchKeyword Damaged = new("damaged", "b:damaged", "");

    public static readonly SearchKeyword[] Values = [Tags, Text, Author, Mine, Ai, Common, All, Video, Photo, Folder, Recent, External, Album, Reviewed, Unreviewed, Damaged];

    string Localized(string suffix) => L($"search.kw.{Id}.{suffix}");
    public string Word => Localized("word");
    public List<string> Aliases => [.. Localized("aliases").Split(',').Select(s => s.Trim()).Where(s => s.Length > 0)];
    public string Hint => Localized("hint");
    public string ExcludeHint => Localized("exclude");
    /// 全部, 相册, 已认可 / 未认可 and 损坏 mean nothing with a minus.
    public bool Excludable => !(this == All || this == Album || this == Reviewed || this == Unreviewed || this == Damaged);
    public bool MatchesPrefix(string q) => new[] { Word }.Concat(Aliases).Any(s => s.ToLowerInvariant().StartsWith(q));

    public static SearchKeyword? From(string value)
    {
        var q = value.Trim().ToLowerInvariant();
        if (q.Length == 0) return null;
        return Values.FirstOrDefault(k => new[] { k.Word }.Concat(k.Aliases).Any(s => s.ToLowerInvariant() == q));
    }
}

public sealed partial class TokenQuery
{
    public IReadOnlyList<string> Keys { get; }
    readonly HashSet<SearchField> _fields = [], _excludedFields = [];
    readonly HashSet<SearchScope> _scopes = [], _excludedScopes = [];
    readonly HashSet<MediaKind> _kinds = [], _excludedKinds = [];
    readonly List<string> _terms = [], _excludedTerms = [], _excludedFolders = [];
    readonly HashSet<ReviewFilter> _reviews = [];
    string? _folder;
    bool _album, _damaged, _recent, _external, _excludeRecent, _excludeExternal;

    public TokenQuery(IEnumerable<string>? keys = null)
    {
        Keys = [.. keys ?? []];
        foreach (var k in Keys)
        {
            var key = k;
            var excluded = IsExcluded(key);
            if (excluded) key = key[1..];
            if (key.StartsWith("f:"))
            {
                foreach (var f in Enum.GetValues<SearchField>())
                    if (key == "f:" + f.ToString().ToLowerInvariant()) (excluded ? _excludedFields : _fields).Add(f);
            }
            else if (key.StartsWith("s:"))
            {
                foreach (var s in Enum.GetValues<SearchScope>())
                    if (key == "s:" + s.ToString().ToLowerInvariant() && (!excluded || s != SearchScope.Both)) (excluded ? _excludedScopes : _scopes).Add(s);
            }
            else if (key.StartsWith("t:"))
            {
                var term = key[2..].ToLowerInvariant();
                var target = excluded ? _excludedTerms : _terms;
                if ((!excluded || term.Length > 0) && !target.Contains(term)) target.Add(term);
            }
            else if (key.StartsWith("d:"))
            {
                var name = key[2..];
                if (excluded) { if (!_excludedFolders.Contains(name)) _excludedFolders.Add(name); }
                else _folder = name;
            }
            else if (key == "r:recent") { if (excluded) _excludeRecent = true; else _recent = true; }
            else if (key == "x:external") { if (excluded) _excludeExternal = true; else _external = true; }
            else if (key.StartsWith("k:"))
            {
                if (key == "k:photo") (excluded ? _excludedKinds : _kinds).Add(MediaKind.Photo);
                if (key == "k:video") (excluded ? _excludedKinds : _kinds).Add(MediaKind.Video);
            }
            else if (!excluded && key == "a:album") _album = true;
            else if (!excluded && key == "v:reviewed") _reviews.Add(ReviewFilter.Reviewed);
            else if (!excluded && key == "v:unreviewed") _reviews.Add(ReviewFilter.Unreviewed);
            else if (!excluded && key == "b:damaged") _damaged = true;
        }
    }

    /// What a filter asks for, as capsules.
    public static List<string> KeysFor(FeedFilter f)
    {
        var k = new List<string>();
        var author = f.Author?.Trim() ?? "";
        if (author.Length > 0) k.AddRange([TermKey(author.TrimStart('@').ToLowerInvariant()), SearchKeyword.Author.Key]);
        var labels = f.Labels.Select(l => l.Trim().ToLowerInvariant()).Where(l => l.Length > 0).ToList();
        if (labels.Count > 0) { k.AddRange(labels.Select(TermKey)); k.Add(SearchKeyword.Tags.Key); }
        if (!string.IsNullOrEmpty(f.Folder)) k.Add(FolderKey(f.Folder));
        k.AddRange(f.ExcludeFolders.Where(n => n.Length > 0).Select(n => "-" + FolderKey(n)));
        if (f.Kind != null) k.Add(f.Kind == MediaKind.Video ? SearchKeyword.Video.Key : SearchKeyword.Photo.Key);
        if (f.RecentOnly) k.Add(SearchKeyword.Recent.Key);
        if (f.LooseOnly) k.Add(SearchKeyword.External.Key);
        if (f.AlbumOnly) k.Add(SearchKeyword.Album.Key);
        if (f.Review == ReviewFilter.Reviewed) k.Add(SearchKeyword.Reviewed.Key);
        if (f.Review == ReviewFilter.Unreviewed) k.Add(SearchKeyword.Unreviewed.Key);
        if (f.BadOnly) k.Add(SearchKeyword.Damaged.Key);
        return k;
    }

    /// old with the capsules of added: none twice, one folder (and one of 已认可 / 未认可) at a time.
    public static List<string> Adding(IEnumerable<string> added, IEnumerable<string> old)
    {
        var o = old.ToList();
        foreach (var key in added)
        {
            if (o.Contains(key)) continue;
            if (key.StartsWith("d:")) o.RemoveAll(x => x.StartsWith("d:"));
            if (key.StartsWith("v:")) o.RemoveAll(x => x.StartsWith("v:"));
            o.Add(key);
        }
        return o;
    }

    public static TokenQuery Parse(string text) => new(Split(text + " ").Keys);

    public IReadOnlyList<string> Terms => _terms;
    public bool Recent => _recent;
    public string? Folder => _folder;
    public HashSet<MediaKind> AllowedKinds
    {
        get
        {
            var s = _kinds.Count == 0 ? new HashSet<MediaKind> { MediaKind.Photo, MediaKind.Video } : [.. _kinds];
            s.ExceptWith(_excludedKinds);
            return s;
        }
    }
    public MediaKind? Kind => AllowedKinds.Count == 1 ? AllowedKinds.Single() : null;

    public SearchScope Scope
    {
        get
        {
            if (_scopes.Contains(SearchScope.Common)) return SearchScope.Common;
            if (_scopes.Contains(SearchScope.Mine) && _scopes.Contains(SearchScope.Ai)) return SearchScope.Both;
            if (_scopes.Contains(SearchScope.Mine)) return SearchScope.Mine;
            if (_scopes.Contains(SearchScope.Ai)) return SearchScope.Ai;
            return SearchScope.Both;
        }
    }

    public SearchFields Fields
    {
        get
        {
            var tagsOnly = _scopes.Any(s => s != SearchScope.Both);
            return new SearchFields
            {
                Tags = (_fields.Count == 0 || _fields.Contains(SearchField.Tags)) && !_excludedFields.Contains(SearchField.Tags),
                Text = (_fields.Count == 0 ? !tagsOnly : _fields.Contains(SearchField.Text)) && !_excludedFields.Contains(SearchField.Text),
                Author = (_fields.Count == 0 ? !tagsOnly : _fields.Contains(SearchField.Author)) && !_excludedFields.Contains(SearchField.Author),
            };
        }
    }

    /// With no words to find, what the field and tag-origin capsules alone ask for (the core's
    /// `FeedFilter::require`, as in SearchQuery.swift): 标签 / 贴文 / 用户 something in those
    /// fields, 我的 / AI / 共同 / 全部 (also with a minus) a tag that counts. null: nothing of the kind.
    public SearchFields? Require
    {
        get
        {
            if (_terms.Count > 0) return null;
            if (_fields.Count > 0) return Fields;
            if (_scopes.Count > 0 || _excludedScopes.Count > 0) return new SearchFields { Tags = !_excludedFields.Contains(SearchField.Tags), Text = false, Author = false };
            return null;
        }
    }

    public List<int>? Origins
    {
        get
        {
            if (_excludedScopes.Count == 0) return null;
            var mask = Scope switch { SearchScope.Common => 4, SearchScope.Mine => 1, SearchScope.Ai => 2, _ => 3 };
            return [.. new[] { 1, 2, 3 }.Where(o =>
                (mask == 4 ? o == 3 : (o & mask & 3) != 0)
                && !(_excludedScopes.Contains(SearchScope.Mine) && (o & 1) != 0)
                && !(_excludedScopes.Contains(SearchScope.Ai) && (o & 2) != 0)
                && !(_excludedScopes.Contains(SearchScope.Common) && o == 3))];
        }
    }

    public bool IsContradictory
    {
        get
        {
            var f = Fields;
            return AllowedKinds.Count == 0 || _reviews.Count > 1 || (_recent && _excludeRecent) || (_external && _excludeExternal)
                || (_folder != null && _excludedFolders.Contains(_folder)) || (_terms.Count > 0 && !f.Tags && !f.Text && !f.Author);
        }
    }

    public FeedFilter Filter()
    {
        var f = new FeedFilter();
        if (_album) f.AlbumOnly = true;
        if (_damaged) f.BadOnly = true;
        if (_reviews.Count == 1) f.Review = _reviews.Single();
        if (_folder != null) f.Folder = _folder;
        if (_recent) f.RecentOnly = true;
        if (_external) f.LooseOnly = true;
        if (Kind != null) f.Kind = Kind;
        var fields = Fields;
        if (fields.Tags || fields.Text || fields.Author) f.ExcludeTerms = [.. _excludedTerms];
        f.Origins = Origins;
        f.ExcludeFolders = [.. _excludedFolders];
        f.ExcludeRecent = _excludeRecent;
        f.ExcludeLoose = _excludeExternal;
        f.Require = Require;
        return f;
    }

    /// Built even for a contradiction: the caller returns nothing without asking the core then.
    public FeedRequest Request(bool newestFirst = false, bool wholePosts = false) => new()
    {
        Terms = [.. _terms],
        Scope = Scope,
        NewestFirst = newestFirst,
        // no fuzzy or semantic matching here: a term matches its tag exactly (as in the Flutter app)
        Fuzzy = false,
        Fields = Fields,
        Filter = Filter(),
        WholePosts = wholePosts,
    };

    public SearchMarks Marks => new(_terms, Fields);

    public const string PendingFolder = "p:folder";
    static readonly char[] MinusSigns = ['-', '－', '−', '–'];
    public static string TermKey(string term) => "t:" + term;
    public static string FolderKey(string name) => "d:" + name;
    public static bool IsExcluded(string key) => key.StartsWith('-');
    public static string? Negated(string word) => word.Length > 1 && MinusSigns.Contains(word[0]) ? word[1..] : null;

    public static string KeyFor(string word, string? after = null)
    {
        if (after == PendingFolder) return FolderKey(word);
        if (after == "-" + PendingFolder) return "-" + FolderKey(Negated(word) ?? word);
        var rest = Negated(word);
        if (rest != null)
        {
            var kw = SearchKeyword.From(rest);
            return "-" + (kw != null && kw.Excludable ? kw.Key : TermKey(rest.ToLowerInvariant()));
        }
        return SearchKeyword.From(word)?.Key ?? TermKey(word);
    }

    [GeneratedRegex("[ 　\n\t]")]
    private static partial Regex Separators();

    /// The finished words of what was typed as capsules, and what is still being typed.
    public static (List<string> Keys, string Remaining) Split(string text)
    {
        var matches = Separators().Matches(text);
        if (matches.Count == 0) return ([], text);
        var last = matches[^1];
        var keys = new List<string>();
        foreach (var word in Separators().Split(text[..last.Index]).Where(s => s.Length > 0))
        {
            var previous = keys.Count == 0 ? null : keys[^1];
            var key = KeyFor(word, previous);
            if (previous == PendingFolder || previous == "-" + PendingFolder) keys[^1] = key;
            else keys.Add(key);
        }
        return (keys, text[(last.Index + last.Length)..]);
    }

    public static string Title(string key)
    {
        var bare = IsExcluded(key) ? key[1..] : key;
        if (bare.StartsWith("t:")) return bare[2..];
        if (bare.StartsWith("d:")) return L("search.token.folder", bare[2..]);
        if (bare == PendingFolder) return L("search.token.folderPending");
        return SearchKeyword.Values.FirstOrDefault(k => k.Key == bare)?.Word ?? bare;
    }

    public static string Spoken(string key) => IsExcluded(key) ? L("search.token.excluded", Title(key)) : Title(key);
}

public sealed class SearchMarks(IReadOnlyList<string> terms, SearchFields fields)
{
    public static readonly SearchMarks None = new([], new SearchFields { Tags = true, Text = true, Author = true });
    public IReadOnlyList<string> Terms { get; } = terms;
    public IReadOnlyList<string> Tags => fields.Tags || (!fields.Text && !fields.Author) ? Terms : [];
    public IReadOnlyList<string> Text => fields.Text ? Terms : [];
    public IReadOnlyList<string> Author => fields.Author ? Terms : [];

    static string Fold(string value)
    {
        var source = value.Replace('ﾞ', '゛').Replace('ﾟ', '゜');
        var d = source.Normalize(NormalizationForm.FormKD).ToLowerInvariant();
        var sb = new StringBuilder(d.Length);
        foreach (var c in d) if (c < '̀' || c > 'ͯ') sb.Append(c);
        return sb.ToString().Replace("ß", "ss").Replace('ς', 'σ');
    }

    /// Where the terms are in text: case, width and accents folded, mapped back to whole characters.
    public static List<(int Start, int End)> Ranges(IReadOnlyList<string> terms, string text)
    {
        if (terms.Count == 0 || text.Length == 0) return [];
        var buffer = new StringBuilder();
        var starts = new List<int>();
        var ends = new List<int>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext())
        {
            var g = (string)e.Current;
            var offset = e.ElementIndex;
            IEnumerable<string> pieces = g.Contains('ﾞ') || g.Contains('ﾟ') ? g.Select(c => c.ToString()) : [g];
            foreach (var piece in pieces)
            {
                var folded = Fold(piece);
                buffer.Append(folded);
                for (var i = 0; i < folded.Length; i++) { starts.Add(offset); ends.Add(offset + piece.Length); }
                offset += piece.Length;
            }
        }
        var haystack = buffer.ToString();
        var ranges = new List<(int, int)>();
        foreach (var term in terms.Select(s => s.Trim()).Where(s => s.Length > 0).Distinct())
        {
            var needle = Fold(term);
            if (needle.Length == 0) continue;
            var from = 0;
            while (from < haystack.Length)
            {
                var found = haystack.IndexOf(needle, from, StringComparison.Ordinal);
                if (found < 0) break;
                var end = found + needle.Length;
                if (end < haystack.Length && haystack[end] is '゙' or '゚') { from = end; continue; }
                ranges.Add((starts[found], ends[end - 1]));
                from = end;
            }
        }
        ranges.Sort();
        var merged = new List<(int Start, int End)>();
        foreach (var r in ranges)
        {
            if (merged.Count > 0 && r.Item1 < merged[^1].End) merged[^1] = (merged[^1].Start, Math.Max(r.Item2, merged[^1].End));
            else merged.Add(r);
        }
        return merged;
    }
}

/// Random feed order from the system's generator, as the other apps' FeedOrder: each media (or post)
/// gets a random rank the first time it is seen and keeps it until the next reshuffle.
public sealed class FeedOrder
{
    readonly Dictionary<string, long> _rank = [];
    static long Draw() => System.Security.Cryptography.RandomNumberGenerator.GetInt32(int.MaxValue) * (long)int.MaxValue + System.Security.Cryptography.RandomNumberGenerator.GetInt32(int.MaxValue);

    public void Reshuffle() => _rank.Clear();

    /// Posts in the order of items (the core's), each post's media in their order.
    public static List<List<FeedItem>> PostsInPlace(IEnumerable<FeedItem> items)
    {
        var byPost = new Dictionary<string, List<FeedItem>>();
        var order = new List<List<FeedItem>>();
        foreach (var i in items)
        {
            if (!byPost.TryGetValue(i.PostId, out var list)) { list = []; byPost[i.PostId] = list; order.Add(list); }
            list.Add(i);
        }
        foreach (var m in order) m.Sort((a, b) => a.Ordinal.CompareTo(b.Ordinal));
        return order;
    }

    /// Posts, each with one random rank of its own (never "the best of its media").
    public List<List<FeedItem>> Posts(IEnumerable<FeedItem> items)
    {
        var byPost = PostsInPlace(items);
        long Rank(string k) => _rank.TryGetValue(k, out var r) ? r : _rank[k] = Draw();
        return [.. byPost.Select(p => (Rank("post:" + p[0].PostId), p)).OrderBy(x => x.Item1).Select(x => x.p)];
    }

    public List<FeedItem> Apply(IEnumerable<FeedItem> items)
    {
        long Rank(string k) => _rank.TryGetValue(k, out var r) ? r : _rank[k] = Draw();
        return [.. items.Select(i => (Rank(i.MediaId), i)).OrderBy(x => x.Item1).Select(x => x.i)];
    }
}
