// The data folder: everything the app keeps — the library, its models, settings, secrets, logs,
// caches — lives in one folder the person chose, so it can be backed up, moved or deleted as one
// thing. Exactly the Flutter app's layout, so an upgrade from it finds everything:
//   %APPDATA%\TwimShelf\location.json   {"path": "<data>"}     the only file outside it
//   <data>\twimshelf-data.json          the mark of a data folder
//   <data>\App\Library                  the library
//   <data>\App\Models                   on-device models
//   <data>\App\shared_preferences.json  this device's preferences
//   <data>\App\secrets.json, secrets.key
//   <data>\Cache                        caches
// A run on a synthetic library (TL_LIBRARY_DIR) never touches the pointer.
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TwimShelf.Services;

public static class DataHome
{
    public static string? Path { get; private set; }

    static string? Override => Environment.GetEnvironmentVariable("TL_LIBRARY_DIR");

    static string PointerFile => System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TwimShelf", "location.json");

    /// Where the app keeps its own files: <data>\App (or beside a synthetic library).
    public static string AppDir => Override != null ? System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Override.TrimEnd('\\'))!, "App") : System.IO.Path.Combine(Path!, "App");
    public static string CacheDir => Override != null ? System.IO.Path.Combine(System.IO.Path.GetDirectoryName(Override.TrimEnd('\\'))!, "Cache") : System.IO.Path.Combine(Path!, "Cache");
    public static string LibraryDir => Override ?? System.IO.Path.Combine(AppDir, "Library");
    public static string ModelsDir => Environment.GetEnvironmentVariable("TL_MODELS_DIR") ?? System.IO.Path.Combine(AppDir, "Models");

    /// A sensible first suggestion: a folder in Documents.
    public static string Suggested
    {
        get
        {
            var docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return System.IO.Path.Combine(Directory.Exists(docs) ? docs : home, "TwimShelf Data");
        }
    }

    /// Reads the pointer; true when the data folder is known (and now in use).
    public static bool Locate()
    {
        if (Override != null) return true;
        try
        {
            var j = JsonNode.Parse(File.ReadAllText(PointerFile));
            var p = (string?)j?["path"];
            if (p == null || !Directory.Exists(p)) return false;
            Path = p;
            return true;
        }
        catch
        {
            return false;
        }
    }

    public static bool IsDataFolder(string folder) => File.Exists(System.IO.Path.Combine(folder, "twimshelf-data.json"));

    /// The program's own folder (where this exe runs): uninstalling or updating removes it.
    public static string ProgramDir => System.IO.Path.GetFullPath(AppContext.BaseDirectory).TrimEnd('\\');

    /// folder is the program's folder or inside it: never a place for the data.
    public static bool InsideProgram(string folder)
    {
        try
        {
            var f = System.IO.Path.GetFullPath(folder).TrimEnd('\\');
            var p = ProgramDir;
            return string.Equals(f, p, StringComparison.OrdinalIgnoreCase) || f.StartsWith(p + "\\", StringComparison.OrdinalIgnoreCase);
        }
        catch { return false; }
    }

    /// The data in use is in the program's folder (an older version allowed it): it has to move.
    public static bool InProgramFolder => Override == null && Path != null && InsideProgram(Path);

    /// A folder can hold the data: it is new, empty, or already a data folder, and not in the
    /// program's folder. Null when it can, else the datahome.* message key.
    public static string? Problem(string folder)
    {
        if (InsideProgram(folder)) return "datahome.inProgram";
        if (!Directory.Exists(folder)) return null;
        if (IsDataFolder(folder)) return null;
        return Directory.EnumerateFileSystemEntries(folder).Any() ? "datahome.notEmpty" : null;
    }

    /// A folder the data can move to: new or empty only (never another library, whose files it
    /// would overwrite), and not in the program's folder. Null when it can.
    public static string? MoveProblem(string folder)
    {
        if (InsideProgram(folder)) return "datahome.inProgram";
        if (!Directory.Exists(folder)) return null;
        if (IsDataFolder(folder)) return "datahome.moveExisting";
        return Directory.EnumerateFileSystemEntries(folder).Any() ? "datahome.notEmpty" : null;
    }

    /// Uses folder from now on (made when missing, marked as a data folder).
    public static void Choose(string folder)
    {
        Directory.CreateDirectory(System.IO.Path.Combine(folder, "App"));
        var mark = System.IO.Path.Combine(folder, "twimshelf-data.json");
        if (!File.Exists(mark)) File.WriteAllText(mark, new JsonObject { ["created"] = DateTime.UtcNow.ToString("O") }.ToJsonString());
        WritePointer(folder);
        Path = folder;
    }

    static void WritePointer(string folder)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(PointerFile)!);
        var tmp = PointerFile + ".partial";
        File.WriteAllText(tmp, new JsonObject { ["path"] = folder }.ToJsonString());
        File.Move(tmp, PointerFile, true);
    }

    /// Moves everything to target (new or empty): copied, checked file by file (sizes), then used
    /// from the next start. The old folder is left as it was. The database is not copied as files
    /// (a running one is spread over several): snapshot writes a consistent copy, first, and then
    /// the files are listed and copied, so every media the copied database knows of is among them
    /// (a file is always written before the database refers to it).
    public static async Task MoveTo(string target, Func<string, Task> snapshot, string databaseFile, IProgress<(int Done, int Total)>? progress = null)
    {
        var from = (Path ?? throw new InvalidOperationException("dataHome.none")).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        if (MoveProblem(target) is { } problem) throw new IOException(Strings.L(problem));
        var sep = System.IO.Path.DirectorySeparatorChar;
        if (string.Equals(target, from, StringComparison.OrdinalIgnoreCase) || target.StartsWith(from + sep, StringComparison.OrdinalIgnoreCase))
            throw new IOException("dataHome.inside");
        var copy = System.IO.Path.Combine(target, databaseFile[(from.Length + 1)..]);
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(copy)!);
        await snapshot(copy);
        if (!File.Exists(copy) || new FileInfo(copy).Length == 0) throw new IOException("dataHome.copyFailed: " + copy);
        await Task.Run(() =>
        {
            var files = Directory.EnumerateFiles(from, "*", new EnumerationOptions { RecurseSubdirectories = true, AttributesToSkip = FileAttributes.ReparsePoint }).ToList();
            var done = 0;
            foreach (var f in files)
            {
                // the snapshot is the database: the running one's files never go over it
                if (new[] { "", "-wal", "-shm" }.Any(end => string.Equals(f, databaseFile + end, StringComparison.OrdinalIgnoreCase))) { done++; continue; }
                var rel = f[(from.Length + 1)..];
                var dst = System.IO.Path.Combine(target, rel);
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(dst)!);
                File.Copy(f, dst, true);
                if (new FileInfo(dst).Length != new FileInfo(f).Length) throw new IOException("dataHome.copyFailed: " + rel);
                progress?.Report((++done, files.Count));
            }
        });
        WritePointer(target);
    }

    /// The previous data folder, after a move (deleted only when the person agrees).
    public static void DeleteOld(string folder)
    {
        if (!IsDataFolder(folder) || string.Equals(folder, Path, StringComparison.OrdinalIgnoreCase)) return;
        Directory.Delete(folder, true);
    }

    /// Starts this program again (after a move, a new colour). This one lets go of the single-instance
    /// lock first, and the new one (--after <pid>) waits for this one to end and retries the lock for
    /// a while: finding it taken, it would hand over to this one and quit, leaving nothing running.
    public static void Restart()
    {
        var p = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false };
        p.ArgumentList.Add("--after");
        p.ArgumentList.Add(Environment.ProcessId.ToString());
        App.ReleasePrimary();
        Process.Start(p);
        Environment.Exit(0);
    }

    /// The --after of a restart: waits (a few seconds at most) for the old one to end.
    public static void WaitForPrevious(string[] argv)
    {
        var i = Array.IndexOf(argv, "--after");
        if (i < 0 || i + 1 >= argv.Length || !int.TryParse(argv[i + 1], out var pid)) return;
        try { using var old = Process.GetProcessById(pid); old.WaitForExit(10000); } catch { /* gone already */ }
    }
}
