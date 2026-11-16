// Numbers as the other apps write them.
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Services;

public static class Format
{
    /// Bytes in decimal units (1 KB = 1000 B), as the other apps' formatters.
    public static string Bytes(long b)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double v = b;
        var u = 0;
        while (v >= 1000 && u < units.Length - 1) { v /= 1000; u++; }
        return u == 0 ? $"{b} B" : $"{v:0.0} {units[u]}";
    }

    /// What an export left out, for its summary (at most 15 named).
    public static string Skipped(ExportReport r)
    {
        if (r.Skipped.Count == 0) return "";
        var more = L("export.skipped", r.Skipped.Count);
        foreach (var s in r.Skipped.Take(15))
            more += L("export.skip.line", s.PostId.StartsWith("loose:") ? L("card.loose") : L("common.post", s.PostId), s.MediaId.Length > 10 ? s.MediaId[..10] : s.MediaId, s.Reason);
        if (r.Skipped.Count > 15) more += L("export.skip.more", r.Skipped.Count - 15);
        return more;
    }

    public static string Date(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).LocalDateTime.ToString("g");
}
