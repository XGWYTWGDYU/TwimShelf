// Installing for this user only: no administrator rights, nothing outside the user's own folders
// and registry — the same places and records as the Flutter app's setup, so it upgrades over that:
//   %LOCALAPPDATA%\Programs\TwimShelf\…             the program (one folder)
//   …\install-manifest.json                          its files (an update removes those it no longer has)
//   HKCU\…\Uninstall\TwimShelf                       the Settings › Apps entry
//   Start menu (and desktop if asked) shortcuts, and 发送到 (Send To) when the build offers it.
// The uninstaller is the program itself (TwimShelf.exe --uninstall).
using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Microsoft.Win32;

namespace TwimShelf.Setup;

public sealed record Product(string Id, string Name, string Version, string Publisher, string Executable, bool SendTo)
{
    public static Product Read(string file)
    {
        var j = JsonNode.Parse(File.ReadAllText(file))!;
        return new((string)j["id"]!, (string)j["name"]!, (string)j["version"]!, (string?)j["publisher"] ?? "", (string)j["executable"]!, (bool?)j["sendTo"] ?? false);
    }

    public JsonObject ToJson() => new() { ["id"] = Id, ["name"] = Name, ["version"] = Version, ["publisher"] = Publisher, ["executable"] = Executable, ["sendTo"] = SendTo };
}

public sealed record InstalledCopy(string Folder, string? Version);
public enum InstallKind { Fresh, Upgrade, Reinstall, Downgrade, UnknownVersion }

public sealed class Installer(Product product)
{
    static string Local => Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static string AppData => Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
    public string DefaultFolder => Path.Combine(Local, "Programs", product.Name);
    string UninstallKey => @"Software\Microsoft\Windows\CurrentVersion\Uninstall\" + product.Id;
    string StartMenu => Path.Combine(AppData, @"Microsoft\Windows\Start Menu\Programs", product.Name + ".lnk");
    string Desktop => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), product.Name + ".lnk");
    string SendTo => Path.Combine(AppData, @"Microsoft\Windows\SendTo", product.Name + ".lnk");

    /// Compares dotted versions (1.2, 1.2.0+3; a build number counts as one more part). Null when unreadable.
    public static int? Compare(string a, string b)
    {
        static List<long>? Parts(string v)
        {
            var o = new List<long>();
            foreach (var p in v.Trim().Split('.', '+')) { if (!long.TryParse(p, out var n)) return null; o.Add(n); }
            return o;
        }
        var x = Parts(a);
        var y = Parts(b);
        if (x == null || y == null) return null;
        for (var i = 0; i < Math.Max(x.Count, y.Count); i++)
        {
            var d = (i < x.Count ? x[i] : 0).CompareTo(i < y.Count ? y[i] : 0);
            if (d != 0) return d;
        }
        return 0;
    }

    public static InstallKind KindOf(InstalledCopy? copy, string incoming)
    {
        if (copy == null) return InstallKind.Fresh;
        var order = copy.Version == null ? null : Compare(copy.Version, incoming);
        return order switch { null => InstallKind.UnknownVersion, 0 => InstallKind.Reinstall, < 0 => InstallKind.Upgrade, _ => InstallKind.Downgrade };
    }

    /// The copy installed now (null: not installed).
    public InstalledCopy? Installed()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(UninstallKey);
            var p = k?.GetValue("InstallLocation") as string;
            var v = k?.GetValue("DisplayVersion") as string;
            return p != null && Directory.Exists(p) ? new InstalledCopy(p, v ?? ManifestVersion(p)) : null;
        }
        catch { return null; }
    }

    static string? ManifestVersion(string folder)
    {
        try { return (string?)JsonNode.Parse(File.ReadAllText(Path.Combine(folder, "install-manifest.json")))?["version"]; }
        catch { return null; }
    }

    public bool HasDesktopShortcut() => File.Exists(Desktop);

    /// Asks a running copy to close (it would keep its files locked).
    public async Task CloseRunning(int except)
    {
        var name = Path.GetFileNameWithoutExtension(product.Executable);
        // asked first (it ends as 退出 does, also hidden in the background), then its window closed
        if (Services.SingleInstance.AskToQuit())
            foreach (var p in Process.GetProcessesByName(name))
                try { if (p.Id != except) p.WaitForExit(8000); } catch { }
        foreach (var p in Process.GetProcessesByName(name))
        {
            if (p.Id == except) continue;
            try { p.CloseMainWindow(); if (!p.WaitForExit(3000)) p.Kill(); } catch { }
        }
        await Task.Delay(500);
    }

    /// A folder the program can go into: new, empty, or a copy of it already (never a folder with
    /// someone's other files, which an uninstall would have been in the way of), and not holding the
    /// data folder. Null when it can, else a setup string key.
    public static string? FolderProblem(string folder)
    {
        try
        {
            var data = DataFolder();
            if (data != null)
            {
                var f = Path.GetFullPath(folder).TrimEnd('\\');
                var d = Path.GetFullPath(data).TrimEnd('\\');
                if (string.Equals(f, d, StringComparison.OrdinalIgnoreCase) || d.StartsWith(f + "\\", StringComparison.OrdinalIgnoreCase)) return "folderHasData";
            }
            if (!Directory.Exists(folder) || !Directory.EnumerateFileSystemEntries(folder).Any()) return null;
            return File.Exists(Path.Combine(folder, "install-manifest.json")) ? null : "folderInUse";
        }
        catch { return "folderInUse"; }
    }

    /// Copies payload into folder (replacing an older version there), then the shortcuts and the
    /// uninstall entry. progress gets the share done (0–1). The files it replaces or removes are
    /// moved aside first: when anything fails part way, they go back and the older version still
    /// runs as before.
    public async Task Install(string payload, string folder, bool desktopShortcut, IProgress<double> progress)
    {
        await CloseRunning(Environment.ProcessId);
        await Task.Run(() =>
        {
            Directory.CreateDirectory(folder);
            // what a previous run could not clear (a file still in use then)
            foreach (var stale in Directory.EnumerateDirectories(folder, ".setup-backup-*"))
                try { Directory.Delete(stale, true); } catch { }
            var files = Directory.EnumerateFiles(payload, "*", SearchOption.AllDirectories).ToList();
            long total = files.Sum(f => new FileInfo(f).Length), done = 0;
            var manifest = new List<string>();
            var previous = Path.Combine(folder, "install-manifest.json");
            var old = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                if (File.Exists(previous))
                    foreach (var f in JsonNode.Parse(File.ReadAllText(previous))!["files"]!.AsArray()) old.Add((string)f!);
            }
            catch { }
            var backup = Path.Combine(folder, ".setup-backup-" + DateTime.UtcNow.Ticks);
            var movedAside = new List<string>(); // relative paths now in backup
            var added = new List<string>();      // relative paths that were not there before
            void Aside(string rel)
            {
                var src = Path.Combine(folder, rel);
                var dst = Path.Combine(backup, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                File.Move(src, dst); // a file in use can still be renamed
                movedAside.Add(rel);
            }
            try
            {
                foreach (var f in files)
                {
                    var rel = f[(payload.Length + 1)..];
                    var dst = Path.Combine(folder, rel);
                    Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                    if (File.Exists(dst)) Aside(rel); else added.Add(rel);
                    File.Copy(f, dst, false);
                    manifest.Add(rel);
                    old.Remove(rel);
                    done += new FileInfo(f).Length;
                    progress.Report(total == 0 ? 0.9 : 0.9 * done / total);
                }
                // what an older version had and this one has not (only in its own folder)
                foreach (var rel in old)
                    if (File.Exists(Path.Combine(folder, rel))) Aside(rel);
                // the Flutter version's separate uninstaller: the program uninstalls itself now
                var oldUninstall = Path.Combine(folder, "uninstall");
                if (Directory.Exists(oldUninstall))
                    foreach (var f in Directory.EnumerateFiles(oldUninstall, "*", SearchOption.AllDirectories)) Aside(f[(folder.Length + 1)..]);
                File.WriteAllText(Path.Combine(folder, "install-manifest.json"), new JsonObject
                {
                    ["version"] = product.Version,
                    ["files"] = new JsonArray([.. manifest.Select(m => (JsonNode?)JsonValue.Create(m))]),
                }.ToJsonString());
                File.WriteAllText(Path.Combine(folder, "payload.json"), product.ToJson().ToJsonString());
            }
            catch
            {
                // back as it was: what was added goes, what was moved aside returns
                foreach (var rel in added) try { File.Delete(Path.Combine(folder, rel)); } catch { }
                var restored = true;
                foreach (var rel in movedAside)
                    try { var dst = Path.Combine(folder, rel); if (File.Exists(dst)) File.Delete(dst); File.Move(Path.Combine(backup, rel), dst); } catch { restored = false; }
                // (a file that could not go back has its only copy there)
                if (restored) try { Directory.Delete(backup, true); } catch { }
                throw;
            }
            try { Directory.Delete(backup, true); } catch { /* in use still: cleared next time */ }
            RemoveEmptyFolders(folder);
        });
        progress.Report(0.95);
        var exe = Path.Combine(folder, Path.GetFileName(product.Executable));
        await Shortcut(StartMenu, exe, folder, "");
        if (desktopShortcut) await Shortcut(Desktop, exe, folder, "");
        else if (File.Exists(Desktop)) File.Delete(Desktop);
        if (product.SendTo) await Shortcut(SendTo, exe, folder, "--import");
        else if (File.Exists(SendTo)) File.Delete(SendTo);
        using (var k = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            k.SetValue("DisplayName", product.Name);
            k.SetValue("DisplayVersion", product.Version);
            k.SetValue("Publisher", product.Publisher);
            k.SetValue("DisplayIcon", exe);
            k.SetValue("InstallLocation", folder);
            k.SetValue("UninstallString", $"\"{exe}\" --uninstall");
            k.SetValue("EstimatedSize", (int)(Directory.EnumerateFiles(folder, "*", SearchOption.AllDirectories).Sum(f => new FileInfo(f).Length) / 1024), RegistryValueKind.DWord);
            k.SetValue("NoModify", 1, RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        progress.Report(1);
    }

    static void RemoveEmptyFolders(string root)
    {
        foreach (var d in Directory.EnumerateDirectories(root, "*", SearchOption.AllDirectories).OrderByDescending(d => d.Length))
            try { if (!Directory.EnumerateFileSystemEntries(d).Any()) Directory.Delete(d); } catch { }
    }

    /// The data folder the app uses (from its pointer) when it carries the app's mark.
    public static string? DataFolder()
    {
        try
        {
            var p = (string?)JsonNode.Parse(File.ReadAllText(Path.Combine(AppData, "TwimShelf", "location.json")))?["path"];
            return p != null && File.Exists(Path.Combine(p, "twimshelf-data.json")) ? p : null;
        }
        catch { return null; }
    }

    /// Removes the program, its shortcuts and its entry; the data folder only when asked. Only the
    /// files it installed (its manifest) go, and the folder when nothing else is left in it: files
    /// someone put there themselves stay. The program's files go once this process has ended (it
    /// runs from them); the Settings › Apps entry goes only after they did, and when some could not
    /// be removed, it stays (to try again) and a message says so.
    public async Task Uninstall(string folder, string? dataFolder, string leftoversMessage, IProgress<double> progress)
    {
        await CloseRunning(Environment.ProcessId);
        foreach (var s in new[] { StartMenu, Desktop, SendTo }) try { if (File.Exists(s)) File.Delete(s); } catch { }
        progress.Report(0.2);
        Services.LaunchAtLogin.Remove();
        progress.Report(0.4);
        await Task.Run(() =>
        {
            if (dataFolder != null && File.Exists(Path.Combine(dataFolder, "twimshelf-data.json")))
            {
                Directory.Delete(dataFolder, true);
                var pointer = Path.Combine(AppData, "TwimShelf", "location.json");
                if (File.Exists(pointer)) File.Delete(pointer);
            }
        });
        progress.Report(0.9);
        static string Q(string v) => "'" + v.Replace("'", "''") + "'";
        var script = $$"""
            $ErrorActionPreference = 'SilentlyContinue'
            Wait-Process -Id {{Environment.ProcessId}}
            Start-Sleep -Milliseconds 500
            $root = {{Q(folder)}}
            $manifest = Join-Path $root 'install-manifest.json'
            function Gone($p) { for ($i = 0; $i -lt 40 -and (Test-Path -LiteralPath $p); $i++) { Remove-Item -LiteralPath $p -Force -Recurse; if (Test-Path -LiteralPath $p) { Start-Sleep -Milliseconds 250 } }; -not (Test-Path -LiteralPath $p) }
            $left = @()
            if (Test-Path -LiteralPath $manifest) {
                $files = @((Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json).files) + @('payload.json', 'uninstall')
                foreach ($f in $files) { $p = Join-Path $root $f; if (-not (Gone $p)) { $left += $f } }
                if ($left.Count -eq 0 -and -not (Gone $manifest)) { $left += 'install-manifest.json' }
                Get-ChildItem -LiteralPath $root -Directory -Force -Filter '.setup-backup-*' | ForEach-Object { Gone $_.FullName | Out-Null }
                Get-ChildItem -LiteralPath $root -Directory -Recurse -Force | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object { if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force } }
                if (-not (Get-ChildItem -LiteralPath $root -Force)) { Remove-Item -LiteralPath $root -Force }
            } else {
                # no list of what was installed: the program goes, and the folder may hold anything else
                foreach ($f in @({{Q(Path.GetFileName(product.Executable))}}, 'payload.json')) { $p = Join-Path $root $f; if (-not (Gone $p)) { $left += $f } }
            }
            if ($left.Count -eq 0) {
                Remove-Item -LiteralPath {{Q(@"HKCU:\" + UninstallKey)}} -Recurse -Force
            } else {
                Add-Type -AssemblyName PresentationFramework
                [System.Windows.MessageBox]::Show({{Q(leftoversMessage)}} + "`n`n" + (($left | Select-Object -First 8) -join "`n"), {{Q(product.Name)}}) | Out-Null
            }
            Remove-Item -LiteralPath $PSCommandPath -Force
            """;
        var file = Path.Combine(Path.GetTempPath(), $"twimshelf-uninstall-{Environment.ProcessId}.ps1");
        File.WriteAllText(file, script, new UTF8Encoding(true));
        Process.Start(new ProcessStartInfo("powershell", $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{file}\"") { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath() });
        progress.Report(1);
    }

    /// A .lnk through the shell's own scripting object (nothing extra needed).
    static async Task Shortcut(string link, string target, string dir, string args)
    {
        static string Q(string s) => s.Replace("'", "''");
        Directory.CreateDirectory(Path.GetDirectoryName(link)!);
        var script = $"$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{Q(link)}');$s.TargetPath='{Q(target)}';$s.Arguments='{Q(args)}';$s.WorkingDirectory='{Q(dir)}';$s.IconLocation='{Q(target)},0';$s.Save()";
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        using var p = Process.Start(new ProcessStartInfo("powershell", $"-NoProfile -NonInteractive -EncodedCommand {encoded}") { UseShellExecute = false, CreateNoWindow = true })!;
        await p.WaitForExitAsync();
        if (p.ExitCode != 0) throw new IOException("shortcut: " + link);
    }
}
