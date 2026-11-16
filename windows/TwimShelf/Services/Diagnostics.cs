// The app's own log lines (warnings, errors), beside the core's in the library's logs folder, so
// 导出诊断信息 carries both.
namespace TwimShelf.Services;

public static class Diagnostics
{
    /// Before the data folder is known (and for a crash at start): the temporary folder.
    static string? _file = Path.Combine(Path.GetTempPath(), "TwimShelf-start.log");
    static readonly Lock Gate = new();

    public static void Start()
    {
        try
        {
            var dir = Path.Combine(DataHome.LibraryDir, "logs");
            Directory.CreateDirectory(dir);
            _file = Path.Combine(dir, "windows.log");
            if (File.Exists(_file) && new FileInfo(_file).Length > 2_000_000) File.Move(_file, _file + ".1", true);
        }
        catch { _file = null; }
    }

    public static void Log(string line)
    {
        var f = _file;
        if (f == null) return;
        lock (Gate)
        {
            try { File.AppendAllText(f, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}\n"); } catch { }
        }
    }
}
