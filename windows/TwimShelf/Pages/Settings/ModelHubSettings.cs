// 模型商店: the catalog's models and a search of Hugging Face (GGUF), with how each fits this device;
// a repo's page lists its versions (quantizations) to download, pinned to the revision looked at.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TwimShelf.AI;
using TwimShelf.Controls;
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class ModelHubSettings : SettingsSubpage
{
    readonly TextBox _search = new() { PlaceholderText = L("hub.search.placeholder", LocalModels.SourceName), MinWidth = 280 };
    HubDevice? _device;
    List<HubRepo> _items = [];
    List<HubHidden> _hidden = [];
    string? _next, _error;
    string _query = "";
    bool _loading, _onlyFit = true, _uncensored;
    int _generation;
    bool _started;

    LocalModels Local => LocalModels.Instance;
    public override string Title => L("hub.title");
    bool Browsing => _query.Trim().Length == 0 && !_uncensored;

    public static string Size(long b) => b >= 1e9 ? $"{b / 1e9:0.0} GB" : $"{Math.Round(b / 1e6)} MB";
    static string Memory(long b) => $"{Math.Round(b / (double)(1L << 30))} GB";
    static string Params(long n) => $"{n / 1e9:0.0}B";
    static string Tier(string t) => L("hub.tier." + t);
    static string TierGlyph(string t) => t switch { "recommended" => "", "usable" => "", "tooLarge" => "", _ => "" };

    public ModelHubSettings()
    {
        _search.KeyDown += (_, e) => { if (e.Key == Windows.System.VirtualKey.Enter) { _query = _search.Text; _ = Run(true); } };
        Local.Changed += OnLocal;
    }

    void OnLocal() { if (_search.FocusState == FocusState.Unfocused) Build(); }
    public override void Closed() { Local.Changed -= OnLocal; _generation++; }

    async Task Run(bool fresh)
    {
        var run = fresh ? ++_generation : _generation;
        var next = fresh ? null : _next;
        if (fresh) { _items = []; _hidden = []; _next = null; }
        _loading = true;
        _error = null;
        Build();
        try
        {
            var q = _query;
            var u = _uncensored;
            var p = await TlCore.Run(() => TlCore.HubSearch(LocalModels.Format, q, u, next));
            if (run != _generation) return;
            var seen = _items.Select(r => r.Repo).ToHashSet();
            _items = [.. _items, .. p.Items.Where(r => !seen.Contains(r.Repo))];
            _hidden = [.. _hidden, .. p.Hidden];
            _next = p.Next;
            _device = p.Device;
        }
        catch (Exception e) { if (run == _generation) _error = e.Message; }
        if (run == _generation) { _loading = false; Build(); }
    }

    async Task Offer(CatalogEntry c)
    {
        if (!await Dialogs.Confirm(W, L("models.download.title", L(c.NameKey)), L("models.download.message", L(c.NoteKey), Size(c.Bytes)), L("common.download"))) return;
        try { Local.InstallCurated(c); }
        catch (Exception e) { Dialogs.Toast(W, $"{L("models.download.failed")}: {e.Message}"); }
    }

    public override void Build()
    {
        if (!_started) { _started = true; try { _device = TlCore.HubDevice(); } catch { } _ = Run(true); return; }
        Clear();
        Detach.From(_search);
        var fit = new ToggleButton { Content = L("hub.filter.fit"), IsChecked = _onlyFit };
        fit.Click += (_, _) => { _onlyFit = fit.IsChecked == true; Build(); };
        var unc = new ToggleButton { Content = L("hub.filter.uncensored"), IsChecked = _uncensored };
        unc.Click += (_, _) => { _uncensored = unc.IsChecked == true; _ = Run(true); };
        Card(L("hub.title"), null, "", Detach.Owned(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { _search, fit, unc } }, _search));
        var unknown = L("hub.unknown");
        // what models run on here: the GPU and its memory
        var free = _device?.FreeBytes is { } f ? Size(f) : unknown;
        var memory = _device?.MemoryBytes is { } m ? Memory(m) : unknown;
        var lines = new List<string> { _device?.NoGpu == true ? L("hub.device.noGpu", free)
            : _device?.Gpu is { } gpu ? L("hub.device.gpu", gpu, memory, free) : L("hub.device", memory, free) };
        if (!string.IsNullOrEmpty(Local.Devices)) lines.Add(L("models.local.devices", Local.Devices));
        lines.Add(L("hub.device.footer"));
        Footer(string.Join('\n', lines));
        if (Local.Download is { Running: true } dl)
            Card(dl.Repo.Split('/')[^1], dl.Verifying ? L("models.verifying") : dl.TotalBytes == 0 ? L("models.connecting") : $"{Size(dl.DoneBytes)} / {Size(dl.TotalBytes)}", "");

        if (Browsing)
        {
            Header(L("hub.curated"));
            foreach (var c in Local.Catalog)
            {
                var here = Local.Find(c.Folder) != null;
                var entry = c;
                var card = Card(L(c.NameKey), here ? L("hub.installed") : string.Join(" · ", L(c.NoteKey), Tier(c.Tier), Size(c.Bytes)), here ? "" : TierGlyph(c.Tier));
                if (!here)
                {
                    var b = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = Local.Download?.Running != true };
                    ToolTipService.SetToolTip(b, L("common.download"));
                    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, L("common.download"));
                    b.Click += (_, _) => _ = Offer(entry);
                    card.Content = b;
                }
            }
            Footer(L("hub.curated.footer"));
        }

        Header(Browsing ? L("hub.popular") : L("hub.results"));
        var shown = _onlyFit ? _items.Where(r => r.Tier != "tooLarge").ToList() : _items;
        foreach (var r in shown)
        {
            var parts = new List<string> { Tier(r.Tier) };
            if (r.EstimatedBytes is { } eb) parts.Add(L("hub.estimate", Size(eb)));
            if (r.Params is { } p) parts.Add(Params(p));
            if (r.Architecture != null) parts.Add(r.Architecture);
            if (r.ClaimsUncensored) parts.Add(L("hub.claim"));
            var repo = r.Repo;
            Nav(repo.Split('/')[^1], string.Join(" · ", parts), TierGlyph(r.Tier), () => new ModelHubRepoSettings(repo));
        }
        if (_loading) Card(L("hub.loading"), null, null, new ProgressRing { IsActive = true, Width = 20, Height = 20 });
        if (_error != null)
        {
            Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = _error });
            Action(L("models.retry"), null, "", () => _ = Run(true));
        }
        if (!_loading && _error == null && shown.Count == 0) Card(L("hub.empty"), null, "");
        var over = _items.Count - shown.Count;
        if (over > 0) Action(L("hub.overMemory", over), null, "", () => { _onlyFit = false; Build(); });
        if (_next != null && !_loading) Action(L("hub.more"), null, "", () => _ = Run(false));
        if (_hidden.Count > 0)
        {
            var ex = new SettingsExpander { Header = L("hub.hidden", _hidden.Count), HeaderIcon = Icon("") };
            foreach (var h in _hidden) ex.Items.Add(new SettingsCard { Header = h.Repo, Description = h.Reason });
            Add(ex);
        }
        Footer(L("hub.results.footer", LocalModels.SourceName));
    }
}

/// One repo of the store: what it is, and its versions to download (those that fit, suggested first).
public sealed partial class ModelHubRepoSettings(string repo) : SettingsSubpage
{
    HubDetail? _detail;
    string? _error;
    bool _started;
    LocalModels Local => LocalModels.Instance;
    public override string Title => repo.Split('/')[^1];

    async Task Load()
    {
        _error = null;
        try { _detail = await TlCore.Run(() => TlCore.HubRepo(LocalModels.Format, repo)); }
        catch (Exception e) { _error = e.Message; }
        Build();
    }

    public override void Build()
    {
        if (!_started) { _started = true; Local.Changed += Rebuild; _ = Load(); }
        Clear();
        var d = _detail;
        Card(L("hub.detail.repo"), null, "", new TextBlock { Text = repo, IsTextSelectionEnabled = true });
        if (d?.Repo.Architecture != null) Card(L("hub.detail.architecture"), null, null, new TextBlock { Text = d.Repo.Architecture });
        if (d?.Repo.Params is { } p) Card(L("hub.detail.parameters"), null, null, new TextBlock { Text = $"{p / 1e9:0.0}B" });
        if (d != null) Card(L("hub.detail.license"), null, null, new TextBlock { Text = d.Repo.License ?? L("hub.unknown") });
        if (d != null) Card(L("hub.detail.downloads"), null, null, new TextBlock { Text = d.Repo.Downloads.ToString("N0") });
        if (d?.Repo.ClaimsUncensored == true) Card(L("hub.claim"), null, "");
        if (d != null) Action(L("hub.detail.openPage", LocalModels.SourceName), null, "", () => _ = Windows.System.Launcher.LaunchUriAsync(new Uri(d.PageUrl)));
        Footer(L("hub.unverified.footer"));
        if (_error != null)
        {
            Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = _error });
            Action(L("models.retry"), null, "", () => _ = Load());
            return;
        }
        if (d == null) { Card(L("hub.loading"), null, null, new ProgressRing { IsActive = true, Width = 20, Height = 20 }); return; }
        if (d.Problem != null) { Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Title = L("hub.detail.cannotInstall"), Message = d.Problem }); return; }
        Header(L("hub.detail.versions"));
        foreach (var v in d.Variants)
        {
            var here = Local.Find(v.Folder) != null;
            var variant = v;
            var card = Card(v.Suggested ? L("hub.variant.suggested", v.Label) : v.Label,
                here ? L("hub.installed") : v.EnoughSpace ? $"{L("hub.tier." + v.Tier)} · {ModelHubSettings.Size(v.Bytes)}" : L("hub.variant.noSpace", ModelHubSettings.Size(v.Bytes)),
                here ? "" : "");
            if (!here && v.EnoughSpace)
            {
                var b = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 }, IsEnabled = Local.Download?.Running != true };
                ToolTipService.SetToolTip(b, L("common.download"));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(b, L("common.download"));
                b.Click += async (_, _) =>
                {
                    if (!await Dialogs.Confirm(W, L("models.download.title", repo.Split('/')[^1]), L("hub.download.message", variant.Label, ModelHubSettings.Size(variant.Bytes)), L("common.download"))) return;
                    try { Local.InstallVariant(d, variant); }
                    catch (Exception e) { Dialogs.Toast(W, $"{L("models.download.failed")}: {e.Message}"); }
                };
                card.Content = b;
            }
        }
        Footer(L("hub.detail.versions.footer"));
        if (d.Skipped.Count > 0)
        {
            Header(L("hub.detail.skipped"));
            foreach (var s in d.Skipped) Card(s.Name, s.Reason);
        }
    }

    void Rebuild() => Build();
    public override void Closed() => Local.Changed -= Rebuild;
}
