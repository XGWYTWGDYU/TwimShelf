// After a start: the old data folder after a move (when the person chose to delete it), then a newer
// release (at most once a day).
using System.Text.Json.Nodes;

namespace TwimShelf.Services;

public static class StartupChecks
{
    public static async Task Run(MainWindow w)
    {
        if (DataHome.Path != null)
        {
            var f = Path.Combine(DataHome.Path, "delete-after-move.json");
            if (File.Exists(f))
            {
                try
                {
                    var old = (string?)JsonNode.Parse(File.ReadAllText(f))?["path"];
                    if (old != null) await Task.Run(() => DataHome.DeleteOld(old));
                }
                catch { }
                try { File.Delete(f); } catch { }
            }
        }
        await Updates.CheckOnLaunch(w);
        await TwimShelf.Extension.Receiver.CheckUpdateOnLaunch(w);
    }
}
