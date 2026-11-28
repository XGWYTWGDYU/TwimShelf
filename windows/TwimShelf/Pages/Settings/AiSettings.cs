// 打标签: automatic tagging of new media, the model that tags, a run over the whole library, what
// this device could not tag; the on-device models (llama.cpp, GGUF) with the model store; and the
// OpenAI-compatible services added. A model's prompt is edited in its card; a service's connection
// opens as a page.
using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwimShelf.AI;
using TwimShelf.Controls;
using TwimShelf.Core;
using TwimShelf.Models;
using static TwimShelf.Services.Strings;

namespace TwimShelf.Pages;

public sealed partial class AiSettings : SettingsSubpage
{
    readonly LibraryModel _library;
    AiTagging Ai => _library.Ai;
    LocalModels Local => LocalModels.Instance;
    List<AiFailure> _failures = [];
    string _key = "";

    public override string Title => L("models.tagging");

    public AiSettings(LibraryModel library)
    {
        _library = library;
        Ai.Models.Changed += OnChanged;
        Ai.Tagger.Changed += OnChanged;
        Local.Changed += OnChanged;
        _ = LoadFailures();
    }

    public override void Closed()
    {
        foreach (var e in _prompts.Values) e.Release();
        Ai.Models.Changed -= OnChanged;
        Ai.Tagger.Changed -= OnChanged;
        Local.Changed -= OnChanged;
    }

    void OnChanged()
    {
        var t = Ai.Tagger;
        var d = Local.Download;
        var key = string.Join('|', Ai.Models.ActiveTaggerId, Ai.Models.AutoTag, t.Running, t.Paused, t.Done, t.Total, t.Title, t.LastError?.Text,
            string.Join(',', Local.Installed.Select(m => m.Id)), d?.Running, d?.DoneBytes / 1_000_000, d?.Error, string.Join(',', Ai.Models.All.Select(m => m.Id + m.Title + m.Host)), _failures.Count);
        if (key == _key) return;
        Build();
    }

    async Task LoadFailures()
    {
        try { _failures = await TlCore.Run(TlCore.AiFailures); } catch { }
        OnChanged();
    }

    static string Size(long b) => b >= 1e9 ? $"{b / 1e9:0.0} GB" : $"{Math.Round(b / 1e6)} MB";

    async Task RetagAll(string model)
    {
        var c = await Dialogs.Choose(W, L("models.retag.oldTitle"), L("models.retag.oldMessage"), L("models.retag.keep"), L("models.retag.replace"));
        if (c >= 0) Ai.Tagger.RetagAll(model, replaceOld: c == 1);
    }

    public override void Build()
    {
        var t = Ai.Tagger;
        var d = Local.Download;
        _key = string.Join('|', Ai.Models.ActiveTaggerId, Ai.Models.AutoTag, t.Running, t.Paused, t.Done, t.Total, t.Title, t.LastError?.Text,
            string.Join(',', Local.Installed.Select(m => m.Id)), d?.Running, d?.DoneBytes / 1_000_000, d?.Error, string.Join(',', Ai.Models.All.Select(m => m.Id + m.Title + m.Host)), _failures.Count);
        Clear();
        var taggers = Local.Installed.Where(m => m.Vision).Select(m => (m.Id, Local.Title(m))).Concat(Ai.Models.All.Select(m => (m.Id, m.Title))).ToList();
        var active = Ai.Models.ActiveTaggerId;
        if (taggers.Count == 0)
        {
            Card(L("models.none.title"), L("models.none.message"), "");
        }
        else
        {
            Header(L("models.tagging"));
            Switch(L("models.autoTag"), null, Sparkle, Ai.Models.AutoTag, async v => { await Ai.Models.SetAutoTag(v); if (v) await t.StartIfEnabled(asked: true); });
            var box = new ComboBox { MinWidth = 220, PlaceholderText = L("models.noneInstalled") };
            foreach (var (id, title) in taggers) box.Items.Add(new ComboBoxItem { Content = title, Tag = id });
            box.SelectedItem = box.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == active);
            box.SelectionChanged += async (_, _) => { if (box.SelectedItem is ComboBoxItem { Tag: string id } && id != Ai.Models.ActiveTaggerId) { await Ai.Models.SetActiveTagger(id); await t.StartIfEnabled(asked: true); } };
            Card(L("models.defaultTagger"), null, "", box);
            if (t.Running || t.Paused)
            {
                var pause = new Button { Content = new FontIcon { Glyph = t.Paused ? "" : "", FontSize = 14 } };
                ToolTipService.SetToolTip(pause, t.Paused ? L("models.tagging.continue") : L("mac.pause"));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(pause, t.Paused ? L("models.tagging.continue") : L("mac.pause"));
                pause.Click += (_, _) => { if (t.Paused) t.Resume(); else t.Pause(); };
                var stop = new Button { Content = new FontIcon { Glyph = "", FontSize = 14 } };
                ToolTipService.SetToolTip(stop, L("models.stopTagging"));
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(stop, L("models.stopTagging"));
                stop.Click += (_, _) => t.Stop();
                var progress = t.Total > 0 ? (t.Paused ? $"{L("activity.paused")} · {t.Done} / {t.Total}" : $"{t.Done} / {t.Total}") : t.Paused ? L("activity.paused") : null;
                Card(t.Title.Length == 0 ? L("models.inProgress") : t.Title, progress, "", new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { pause, stop } });
                if (t.Total > 0) Add(new ProgressBar { Maximum = t.Total, Value = t.Done, Margin = new Thickness(2, 2, 2, 4) });
                Footer(L("models.tagging.controls"));
            }
            if (t.LastError is { } e) Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Message = e.Text });
            if (_failures.Count > 0)
            {
                var c = Action(L("models.failures"), null, "", () => _ = ShowFailures());
                c.Content = new TextBlock { Text = _failures.Count.ToString() };
            }
            if (active != null && !t.Running) Action(L("models.retagAllEllipsis"), null, "", () => _ = RetagAll(active));
        }

        LocalSection(active);

        Header(L("models.external"));
        foreach (var m in Ai.Models.All)
        {
            var model = m;
            var ex = new SettingsExpander { Header = m.Title, Description = m.Id == active ? L("models.defaultPrefix") + m.Host : m.Host, HeaderIcon = TagStyle.MenuIconSparkle() };
            ex.Items.Add(NavCard(L("models.external.connection"), "", () => new ExternalModelSettings(_library, model, false)));
            ex.Items.Add(PromptCard(model.Id));
            Remember(ex, model.Id);
            var del = new SettingsCard { Header = L("models.external.delete"), HeaderIcon = Icon(""), IsClickEnabled = true };
            del.Click += async (_, _) =>
            {
                if (!await Dialogs.Confirm(W, L("mac.models.external.delete.title", model.Title), L("mac.models.external.delete.message"), L("common.delete"), destructive: true)) return;
                await Ai.Models.Remove(model.Id);
                if (Ai.Models.ActiveTaggerId == model.Id) await Ai.Models.SetActiveTagger(null);
            };
            ex.Items.Add(del);
            Add(ex);
        }
        Nav(L("models.addExternalEllipsis"), L("mac.models.external.hint"), "", () => new ExternalModelSettings(_library, ExternalModel.Create(), true), "ai-add");
    }

    // the prompt editors (what is typed stays across rebuilds) and which cards are open
    readonly Dictionary<string, PromptEditor> _prompts = [];
    readonly HashSet<string> _expanded = [];

    SettingsCard PromptCard(string model)
    {
        if (!_prompts.TryGetValue(model, out var editor)) _prompts[model] = editor = new PromptEditor(_library, model);
        var card = new SettingsCard { ContentAlignment = ContentAlignment.Vertical, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        card.Content = Detach.From(editor);
        Detach.Owned(card, editor);
        return card;
    }

    void Remember(SettingsExpander ex, string id)
    {
        ex.IsExpanded = _expanded.Contains(id);
        ex.Expanded += (_, _) => _expanded.Add(id);
        ex.Collapsed += (_, _) => _expanded.Remove(id);
    }

    SettingsCard NavCard(string header, string glyph, Func<SettingsSubpage> page)
    {
        var c = new SettingsCard { Header = header, HeaderIcon = Icon(glyph), IsClickEnabled = true, ActionIcon = new FontIcon { Glyph = "" } };
        c.Click += (_, _) => Host?.Push(page());
        return c;
    }

    /// What is installed here, a download under way, and the way to the model store.
    void LocalSection(string? active)
    {
        Header(L("models.local"));
        if (!Local.Supported) { Card(L("models.local.unsupported"), null, ""); return; }
        void Installed(ModelInfo m, string title, string? note)
        {
            var parts = new List<string>();
            if (note != null) parts.Add(note);
            parts.Add(L("models.installed", Size(m.Bytes)));
            if (m.Id == active) parts.Add(L("models.defaultPrefix").Trim().TrimEnd('·').Trim());
            var ex = new SettingsExpander { Header = title, Description = string.Join(" · ", parts), HeaderIcon = TagStyle.MenuIconSparkle() };
            if (m.Vision) ex.Items.Add(PromptCard(m.Id));
            Remember(ex, m.Id);
            var del = new SettingsCard { Header = L("common.delete"), HeaderIcon = Icon(""), IsClickEnabled = true };
            del.Click += async (_, _) =>
            {
                if (!await Dialogs.Confirm(W, L("models.delete.title", title), L("models.delete.message"), L("common.delete"), destructive: true)) return;
                await Local.Delete(m.Id);
                if (m.Id == Ai.Models.ActiveTaggerId) await Ai.Models.SetActiveTagger(null);
            };
            ex.Items.Add(del);
            Add(ex);
        }
        foreach (var c in Local.Catalog)
            if (Local.Find(c.Folder) is { } m) Installed(m, L(c.NameKey), L(c.NoteKey));
        foreach (var m in Local.Installed.Where(m => Local.CatalogFor(m.Id) == null)) Installed(m, Local.Title(m), null);
        if (Local.Download is { Running: true } dl)
        {
            var cancel = new Button { Content = new FontIcon { Glyph = "", FontSize = 12 } };
            ToolTipService.SetToolTip(cancel, L("models.cancelDownload"));
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(cancel, L("models.cancelDownload"));
            cancel.Click += (_, _) => Local.CancelDownload();
            Card(dl.Repo.Split('/')[^1], dl.Verifying ? L("models.verifying") : dl.TotalBytes == 0 ? L("models.connecting") : $"{Size(dl.DoneBytes)} / {Size(dl.TotalBytes)}", "", cancel);
            Add(new ProgressBar { IsIndeterminate = dl.TotalBytes == 0 || dl.Verifying, Maximum = Math.Max(1, dl.TotalBytes), Value = dl.DoneBytes, Margin = new Thickness(2, 2, 2, 4) });
        }
        else if (Local.Download is { Running: false, Error: { } err })
            Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error, Title = L("models.downloadFailed"), Message = err });
        Nav(L("hub.title"), L("hub.entry.detail"), "", () => new ModelHubSettings(), "local-store");
        var source = new Segmented { MinWidth = 240 };
        foreach (var (_, name) in LocalModels.Sources) source.Items.Add(new SegmentedItem { Content = name });
        var current = TlCore.ModelSource();
        source.SelectedIndex = Array.FindIndex(LocalModels.Sources, x => x.Id == current);
        // by index: a value kept in Tag does not come back through WinRT (AOT)
        source.SelectionChanged += (_, _) => { if (source.SelectedIndex is var i and >= 0) TlCore.SetModelSource(LocalModels.Sources[i].Id); };
        Card(L("models.source"), L("models.source.footer"), "", source);
        var footer = new List<string> { L("models.local.footer.gguf") };
        if (!string.IsNullOrEmpty(Local.Devices)) footer.Add(L("models.local.devices", Local.Devices));
        Footer(string.Join('\n', footer));
        TransferSection();
    }

    /// Models between devices of the same kind: pull one from another device of the account on the LAN.
    void TransferSection()
    {
        Header(L("models.peers.title"));
        var query = new Button { Content = _querying ? L("models.peers.querying") : L("models.peers.query"), IsEnabled = !_querying };
        query.Click += async (_, _) => await QueryPeers();
        Card(L("models.peers.query"), _offers == null ? null : _offers.Count == 0 ? L("models.peers.nothing") : null, "\uE8F1", query);
        foreach (var (peer, model) in _offers ?? [])
        {
            var pull = new SettingsCard { Header = Local.Title(model), Description = $"{peer.Name} · {Size(model.Bytes)}", HeaderIcon = Icon("\uE896"), IsClickEnabled = true };
            pull.Click += async (_, _) => await Pull(peer, model);
            Add(pull);
        }
        Footer(L("models.appleOnly.footer"));
    }

    bool _querying;
    List<(DiscoveredPeer Peer, ModelInfo Model)>? _offers;

    async Task QueryPeers()
    {
        _querying = true;
        Build();
        var have = Local.Installed.Select(m => m.Id).ToHashSet();
        var offers = new List<(DiscoveredPeer Peer, ModelInfo Model)>();
        foreach (var p in _library.Sync.AccountPeers.Where(p => p.Reachable))
        {
            try
            {
                foreach (var m in await TlCore.Run(() => TlCore.SyncPeerModels(p.Host!, p.Port!.Value)))
                    if (!have.Contains(m.Id) && !offers.Any(o => o.Model.Id == m.Id)) offers.Add((p, m));
            }
            catch { }
        }
        _offers = offers;
        _querying = false;
        Build();
    }

    async Task Pull(DiscoveredPeer peer, ModelInfo model)
    {
        if (!await Dialogs.Confirm(W, L("models.pull.title", peer.Name), L("models.pull.message", Local.Title(model), Size(model.Bytes)), L("models.pull"))) return;
        _offers?.RemoveAll(o => o.Model.Id == model.Id);
        Local.Watch();
        try { await TlCore.Run(() => TlCore.SyncPullModel(peer.Host!, peer.Port!.Value, model.Id, Local.Title(model), (ulong)model.Bytes)); }
        catch (Exception e) { await Dialogs.Alert(W, L("models.pull.failed"), e.Message); }
        await Local.Refresh();
    }

    /// 这台设备无法分析: the media given up on, why, and another try for all of them.
    async Task ShowFailures()
    {
        var lines = _failures.Take(30).Select(f => L("models.failure.line", f.MediaId[..Math.Min(12, f.MediaId.Length)], f.Attempts, f.Reason)).ToList();
        if (_failures.Count > 30) lines.Add(L("models.failures.more", _failures.Count - 30));
        var d = new ContentDialog
        {
            Title = L("models.failures.title"),
            Content = new ScrollViewer { MaxHeight = 420, Content = new TextBlock { Text = string.Join('\n', lines) + L("models.failures.footer"), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } },
            PrimaryButtonText = L("models.retry"),
            CloseButtonText = L("common.close"),
        };
        if (await Dialogs.ShowAsync(W, d) != ContentDialogResult.Primary) return;
        await TlCore.Run(TlCore.AiFailuresClear);
        await LoadFailures();
        // another try runs now even with 自动标记 off (cleared, they are untagged again)
        if (Ai.Models.AutoTag) await Ai.Tagger.StartIfEnabled(asked: true);
        else if (Ai.Models.ActiveTaggerId is { } id) Ai.Tagger.Start(new TaggingJob(id));
    }
}

/// An external service's connection: on the page that adds one, and from its card. 测试连接 sends a
/// small grey picture.
public sealed partial class ExternalModelSettings(LibraryModel library, ExternalModel model, bool isNew) : SettingsSubpage
{
    readonly TextBox _name = new() { Header = L("models.external.name"), Text = model.Name };
    readonly TextBox _url = new() { Header = L("models.external.field.url"), Text = model.Url, PlaceholderText = L("models.external.urlPlaceholder") };
    readonly TextBox _model = new() { Header = L("models.external.model"), Text = model.Model };
    readonly PasswordBox _key = new() { Header = L("models.external.key") };
    readonly InfoBar _result = new() { IsClosable = false };
    bool _hasKey;
    CancellationTokenSource? _test;
    bool _built;

    public override string Title => isNew ? L("models.addExternal") : model.Title;

    public override void Build()
    {
        if (_built) return;
        _built = true;
        if (!isNew) _ = Task.Run(async () =>
        {
            try { var k = await library.Ai.Models.ApiKey(model); _hasKey = !string.IsNullOrEmpty(k); DispatcherQueue.TryEnqueue(() => _key.PlaceholderText = _hasKey ? "••••••" : ""); } catch { }
        });
        Header(L("models.external.connection"));
        var form = Detach.Owned(new StackPanel { Spacing = 12, Padding = new Thickness(16), Children = { Detach.From(_name), Detach.From(_url), Detach.From(_model), Detach.From(_key) } }, _name, _url, _model, _key);
        Add(new Border { Child = form, CornerRadius = new CornerRadius(4), Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"], BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"], BorderThickness = new Thickness(1) });
        Footer(L("models.external.connection.footer"));
        var test = new Button { Content = L("models.external.test") };
        var save = new Button { Content = L("common.save"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        test.Click += async (_, _) =>
        {
            if (!await Save()) return;
            _test?.Cancel();
            var c = _test = new CancellationTokenSource();
            test.IsEnabled = false;
            test.Content = L("models.external.testing");
            try
            {
                var tags = await library.Ai.Client.Test(Edited, c.Token);
                Show(true, L("models.external.successColon") + (tags.Count == 0 ? L("models.external.noTags") : string.Join(L("list.separator"), tags)));
            }
            catch (ExternalFailure e) { Show(false, L("models.external.failureColon") + e.Text); }
            catch { Show(false, L("models.external.failureColon") + L("common.notDone")); }
            test.IsEnabled = true;
            test.Content = L("models.external.test");
        };
        save.Click += async (_, _) => { if (await Save() && isNew) Host?.Pop(); };
        Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0), Children = { test, save } });
        Add(Detach.From(_result));
    }

    ExternalModel Edited => model with { Name = _name.Text.Trim(), Url = _url.Text.Trim(), Model = _model.Text.Trim() };

    void Show(bool ok, string text)
    {
        _result.Severity = ok ? InfoBarSeverity.Success : InfoBarSeverity.Error;
        _result.Message = text;
        _result.IsOpen = true;
    }

    async Task<bool> Save()
    {
        if (_url.Text.Trim().Length == 0) { Show(false, L("models.external.needURL")); return false; }
        if ((_key.Password.Length > 0 || _hasKey) && _model.Text.Trim().Length == 0) { Show(false, L("models.external.needModel")); return false; }
        try
        {
            var m = Edited;
            await library.Ai.Models.Save(m);
            if (_key.Password.Length > 0)
            {
                await library.Ai.Models.SetApiKey(m, _key.Password.Trim());
                _key.Password = "";
                _hasKey = true;
                _key.PlaceholderText = "••••••";
            }
            return true;
        }
        catch (ExternalFailure e) { Show(false, e.Text); }
        catch { Show(false, L("models.external.err.url")); }
        return false;
    }

    public override void Closed() => _test?.Cancel();
}

/// A model's prompt, in its card (as the Mac app's): one of its five parts at a time, chosen above
/// the field. Saved, it applies from now on or to everything right away. Kept across the page's
/// rebuilds (what is typed stays).
public sealed partial class PromptEditor : StackPanel
{
    readonly LibraryModel _library;
    readonly string _model;
    readonly string[] _texts = new string[5];
    readonly Segmented _parts = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly TextBox _field = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 130, MaxHeight = 300 };
    readonly TextBlock _note = new() { TextWrapping = TextWrapping.Wrap, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] };
    static readonly (string Title, string Note)[] Parts =
    [
        ("prompt.system", "prompt.system.footer"), ("prompt.question", "prompt.question.footer"), ("prompt.existing", "prompt.existing.footer"),
        ("prompt.libraryTags", "prompt.libraryTags.footer"), ("prompt.postText", "prompt.postText.footer"),
    ];
    int _part;
    AiPrompt _saved;

    public PromptEditor(LibraryModel library, string model)
    {
        _library = library;
        _model = model;
        _saved = library.Ai.Models.PromptFor(model);
        Spacing = 10;
        Fill(_saved);
        Children.Add(new TextBlock { Text = L("models.promptSection"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        foreach (var (title, _) in Parts) _parts.Items.Add(new SegmentedItem { Content = L(title) });
        _parts.SelectedIndex = 0;
        _parts.SelectionChanged += (_, _) => { if (_parts.SelectedIndex >= 0) { _part = _parts.SelectedIndex; Show(); } };
        _field.TextChanged += (_, _) => _texts[_part] = _field.Text;
        Children.Add(new ScrollViewer { Content = _parts, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled });
        Children.Add(_field);
        Children.Add(_note);
        var reset = new Button { Content = L("mac.prompt.reset") };
        reset.Click += (_, _) => { Fill(library.Ai.Models.Defaults); Show(); };
        var save = new Button { Content = L("mac.prompt.save"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(save, "promptSave-" + model);
        save.Click += async (_, _) => await Save();
        Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { reset, save } });
        Show();
        // another device's change comes in: it shows, unless something is being typed here
        library.Ai.Models.Changed += Incoming;
            }

    void Fill(AiPrompt p)
    {
        _texts[0] = p.System; _texts[1] = p.Prompt; _texts[2] = p.Existing; _texts[3] = p.Vocabulary; _texts[4] = p.Context;
    }

    void Show()
    {
        _field.Text = _texts[_part] ?? "";
        _field.PlaceholderText = L(Parts[_part].Title);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(_field, L(Parts[_part].Title));
        _note.Text = L(Parts[_part].Note);
    }

    AiPrompt Edited => new(_texts[0], _texts[1], _texts[4], _texts[2], _texts[3]);

    void Incoming()
    {
        var now = _library.Ai.Models.PromptFor(_model);
        if (now == _saved) return;
        if (Edited == _saved) { Fill(now); Show(); }
        _saved = now;
    }

    async Task Save()
    {
        var p = Edited;
        if (p == _saved) return;
        _saved = p;
        await _library.Ai.Models.SavePromptFor(_model, p);
        var w = MainWindow.Current!;
        var c = await Dialogs.Choose(w, L("prompt.saved"), L("prompt.saved.retag"), L("prompt.saved.now"), L("prompt.saved.later"));
        if (c != 0) return;
        var r = await Dialogs.Choose(w, L("models.retag.oldTitle"), L("models.retag.oldMessage"), L("models.retag.keep"), L("models.retag.replace"));
        if (r >= 0) _library.Ai.Tagger.RetagAll(_model, replaceOld: r == 1);
    }

    public void Release() => _library.Ai.Models.Changed -= Incoming;
}
