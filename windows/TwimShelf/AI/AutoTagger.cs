// Tags media with the chosen model, as the other apps do: new media automatically, or chosen media
// and the whole library when asked. Pause, resume and cancel; three failures in a row stop a run
// (and give the attempts back, so the media are tried again later); progress for the activity panel.
using Microsoft.UI.Dispatching;
using TwimShelf.Core;
using static TwimShelf.Services.Strings;

namespace TwimShelf.AI;

public enum TaggingScope { Untagged, Media, All }

public sealed record TaggingJob(string Model, TaggingScope Scope = TaggingScope.Untagged, IReadOnlyList<MediaRef>? Media = null, bool ReplaceOld = false, string ResumeAfter = "", long DoneBefore = 0)
{
    public IReadOnlyList<MediaRef> Items => Media ?? (IReadOnlyList<MediaRef>)Array.Empty<MediaRef>();
    public bool LibraryRun => Scope != TaggingScope.Media;
    public string Identity => $"{Model}/{Scope}/{ReplaceOld}/{ResumeAfter}/{DoneBefore}/{string.Join(',', Items.Select(m => m.MediaId))}";

    /// What is left of this job; handled: how many of its selected media are through.
    public TaggingJob Resume(string after, long done, int handled = 0) => this with
    {
        Media = Items.Skip(Math.Clamp(handled, 0, Items.Count)).ToList(),
        ResumeAfter = Scope == TaggingScope.All ? after : "",
        DoneBefore = Scope == TaggingScope.All ? done : 0,
    };
}

/// The model a run uses: an external service, or an installed on-device model.
public sealed record TaggingModel(string Id, string Title, ExternalModel? External);

public sealed class AutoTagger
{
    readonly ExternalModels _models;
    readonly ExternalAI _ai;
    readonly Action? _onChanged;
    readonly DispatcherQueue _ui = DispatcherQueue.GetForCurrentThread();
    readonly List<TaggingJob> _queue = [];
    readonly HashSet<string> _givenBack = [];
    TaggingJob? _current, _resumeMarker;
    CancellationTokenSource? _cancel;
    Task? _task;
    bool _paused, _closed, _stopped;
    int _handled;
    string _after = "";

    public event Action? Changed;
    public bool Running => _task != null;
    public bool Paused => _paused;
    public long Done { get; private set; }
    public long Total { get; private set; }
    public string Outcome { get; private set; } = "idle";
    public string? CurrentPath { get; private set; }
    public string CurrentKind { get; private set; } = "photo";
    public string Title { get; private set; } = "";
    public ExternalFailure? LastError { get; private set; }

    public AutoTagger(ExternalModels models, ExternalAI ai, Action? onChanged)
    {
        _models = models;
        _ai = ai;
        _onChanged = onChanged;
    }

    void Post()
    {
        if (_closed) return;
        if (_ui.HasThreadAccess) Changed?.Invoke();
        else _ui.TryEnqueue(() => Changed?.Invoke());
    }

    TaggingModel? ModelOf(string id)
    {
        var e = _models.Find(id);
        if (e != null) return new TaggingModel(e.Id, e.Title, e);
        var m = LocalModels.Instance.Find(id);
        return m is { Vision: true } ? new TaggingModel(m.Id, LocalModels.Instance.Title(m), null) : null;
    }

    Task<List<string>> Infer(TaggingModel model, byte[] jpeg, IReadOnlyList<string> existing, IReadOnlyList<string> vocabulary, string? text, CancellationToken cancel)
    {
        if (model.External != null) return _ai.Tags(model.External, jpeg, existing, vocabulary, text, cancel);
        return Local(model.Id, jpeg, existing, vocabulary, text);
    }

    async Task<List<string>> Local(string id, byte[] jpeg, IReadOnlyList<string> existing, IReadOnlyList<string> vocabulary, string? text)
    {
        var prompt = _models.PromptFor(id);
        try { return await LocalModels.Instance.Tags(id, jpeg, prompt.System, prompt.Question(existing, vocabulary, text)); }
        catch (ExternalFailure) { throw; }
        catch (Exception e) { throw new ExternalFailure(ExternalFailureKind.Transport, detail: e.Message); }
    }

    /// asked: someone asked for it just now (a switch, another try), which ends a 停止标记.
    public async Task StartIfEnabled(bool asked = false)
    {
        if (asked) _stopped = false;
        if (_stopped) return;
        var id = _models.ActiveTaggerId;
        if (_closed || _paused || Running || !_models.AutoTag || id == null || ModelOf(id) == null) return;
        try
        {
            if ((await TlCore.Run(() => TlCore.AiPendingFor(id, 0, 1))).Count > 0 && !_closed && !_paused && !Running)
                Start(new TaggingJob(id));
        }
        catch { }
    }

    public void Start(TaggingJob job)
    {
        if (_closed) return;
        if (ModelOf(job.Model) == null) { LastError = new ExternalFailure(ExternalFailureKind.NoModel); Post(); return; }
        if (_queue.Any(j => j.Identity == job.Identity)) return;
        _queue.Add(job with { Media = job.Items.ToList() });
        Pump();
    }

    public void Retag(IReadOnlyList<MediaRef> media, string model, bool replaceOld = false)
    {
        if (_closed) return;
        var job = new TaggingJob(model, TaggingScope.Media, media.ToList(), replaceOld);
        if (ModelOf(model) == null) { LastError = new ExternalFailure(ExternalFailureKind.NoModel); Post(); return; }
        if (_queue.Any(j => j.Identity == job.Identity)) return;
        _queue.Insert(0, job);
        if (_current is { LibraryRun: true } current && _cancel is { IsCancellationRequested: false })
        {
            _resumeMarker = current.Resume(_after, Done, _handled);
            _queue.Insert(1, _resumeMarker);
            _cancel.Cancel();
        }
        Pump();
    }

    public void RetagAll(string model, bool replaceOld = false)
    {
        if (_closed) return;
        if (ModelOf(model) == null) { LastError = new ExternalFailure(ExternalFailureKind.NoModel); Post(); return; }
        _queue.RemoveAll(j => j.LibraryRun);
        _queue.Insert(0, new TaggingJob(model, TaggingScope.All, null, replaceOld));
        if (_current?.LibraryRun == true) _cancel?.Cancel();
        Pump();
    }

    public void Pause()
    {
        if (_closed || _paused) return;
        _paused = true;
        if (_current != null && _cancel is { IsCancellationRequested: false })
        {
            _resumeMarker = _current.Resume(_after, Done, _handled);
            _queue.Insert(0, _resumeMarker);
        }
        _cancel?.Cancel();
        Post();
    }

    public void Resume()
    {
        if (_closed) return;
        _paused = false;
        Pump();
        Post();
    }

    public void Cancel()
    {
        _queue.Clear();
        _paused = false;
        _cancel?.Cancel();
        Post();
    }

    /// 停止标记: what runs and what waits are given up, and automatic tagging rests.
    public void Stop()
    {
        _stopped = true;
        Cancel();
    }

    void Pump()
    {
        if (_closed || _paused || Running || _queue.Count == 0) return;
        var job = _queue[0];
        _queue.RemoveAt(0);
        _current = job;
        _after = job.ResumeAfter;
        Done = job.Scope == TaggingScope.All ? job.DoneBefore : 0;
        Total = 0;
        _handled = 0;
        var cancel = new CancellationTokenSource();
        _cancel = cancel;
        Outcome = "running";
        LastError = null;
        _task = Task.Run(async () =>
        {
            try { await RunJob(job, cancel.Token); }
            catch { LastError = new ExternalFailure(ExternalFailureKind.Transport); }
        }).ContinueWith(_ => _ui.TryEnqueue(() =>
        {
            if (_resumeMarker is { } marker)
            {
                var i = _queue.IndexOf(marker);
                if (i >= 0) _queue[i] = job.Resume(_after, Done, _handled);
                _resumeMarker = null;
            }
            Outcome = cancel.IsCancellationRequested ? "cancelled" : LastError != null ? Done > 0 ? "partial" : "failed" : "succeeded";
            _task = null;
            _current = null;
            _cancel = null;
            CurrentPath = null;
            Post();
            Pump();
        }));
        Post();
    }

    async Task RunJob(TaggingJob job, CancellationToken cancel)
    {
        var epoch = await TlCore.Run(TlCore.Epoch);
        var model = ModelOf(job.Model);
        if (model == null) { LastError = new ExternalFailure(ExternalFailureKind.NoModel); return; }
        var counts = await TlCore.Run(TlCore.AiCounts);
        Done = job.Scope == TaggingScope.All ? job.DoneBefore : 0;
        Total = job.Scope switch
        {
            TaggingScope.Untagged => counts.Total - counts.Done,
            TaggingScope.Media => job.Items.Count,
            _ => Math.Max(counts.Total, Done),
        };
        Title = L(job.Scope switch { TaggingScope.Untagged => "ai.activity.new", TaggingScope.Media => "ai.activity.retag", _ => "ai.activity.retagAll" }, model.Title);
        Post();
        var runStart = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 1;
        var first = true;
        var after = job.ResumeAfter;
        int sinceVocabulary = 10, changed = 0;
        var vocabulary = new List<string>();
        var failed = new List<string>();
        // pictures that could not be prepared, one after the other, before any success: a few are
        // damaged files (the run goes on past them), all of them is this device (it stops)
        var unreadableRun = new List<string>();
        var anySuccess = false;
        var counted = job.Scope == TaggingScope.Untagged;
        ExternalFailure? skipped = null;
        async Task Undo(string id) { if (counted) await TlCore.Run(() => TlCore.AiAttempt(AiAttemptStep.Undo, id, job.Model)); }
        try
        {
            while (!cancel.IsCancellationRequested)
            {
                var batch = job.Scope switch
                {
                    TaggingScope.Untagged => await TlCore.Run(() => TlCore.AiPendingFor(job.Model, runStart, 8)),
                    TaggingScope.Media => first ? [.. job.Items] : [],
                    _ => await TlCore.Run(() => TlCore.MediaPage(after, 16)),
                };
                first = false;
                if (batch.Count == 0) break;
                after = batch[^1].MediaId;
                if (counted)
                {
                    var c = await TlCore.Run(TlCore.AiCounts);
                    var gaveUp = await TlCore.Run(() => TlCore.AiFailures().Count);
                    Total = Done + Math.Max(0, c.Total - c.Done - gaveUp);
                    Post();
                }
                foreach (var media in batch)
                {
                    if (cancel.IsCancellationRequested) break;
                    CurrentPath = media.Path;
                    CurrentKind = media.Kind;
                    Post();
                    if (sinceVocabulary >= 10)
                    {
                        vocabulary = await TlCore.Run(() => TlCore.AllTags().Take(150).Select(t => t.Label).ToList());
                        sinceVocabulary = 0;
                    }
                    sinceVocabulary++;
                    var existing = await TlCore.Run(() => TlCore.MediaTags(media.MediaId));
                    if (cancel.IsCancellationRequested) break;
                    if (counted) await TlCore.Run(() => TlCore.AiAttempt(AiAttemptStep.Begin, media.MediaId, job.Model));
                    List<string> labels = [];
                    ExternalFailure? failure = null;
                    var unreadable = false;
                    try
                    {
                        var jpeg = await TaggingImage.Prepare(media);
                        cancel.ThrowIfCancellationRequested();
                        if (jpeg == null) { unreadable = true; failure = new ExternalFailure(ExternalFailureKind.Unreadable); }
                        else labels = await Infer(model, jpeg, existing, vocabulary, media.Text, cancel);
                    }
                    catch (ExternalFailure e) when (e.Kind == ExternalFailureKind.Cancelled) { await Undo(media.MediaId); return; }
                    catch (OperationCanceledException) { await Undo(media.MediaId); return; }
                    catch (ExternalFailure e) { failure = e; }
                    catch { failure = new ExternalFailure(ExternalFailureKind.Transport); }
                    if (cancel.IsCancellationRequested) { await Undo(media.MediaId); return; }
                    if (failure != null)
                    {
                        _handled++;
                        if (!counted) skipped = failure;
                        if (counted) await TlCore.Run(() => TlCore.AiAttempt(AiAttemptStep.Failed, media.MediaId, job.Model, failure.Text));
                        if (unreadable && !anySuccess)
                        {
                            unreadableRun.Add(media.MediaId);
                            if (unreadableRun.Count >= 10)
                            {
                                if (counted)
                                    foreach (var id in unreadableRun.Where(_givenBack.Add).ToList()) await Undo(id);
                                LastError = failure;
                                Post();
                                return;
                            }
                        }
                        if (!unreadable)
                        {
                            failed.Add(media.MediaId);
                            if (failed.Count >= 3)
                            {
                                if (counted)
                                    foreach (var id in failed.Where(_givenBack.Add).ToList()) await Undo(id);
                                LastError = failure;
                                Post();
                                return;
                            }
                        }
                        if (job.Scope == TaggingScope.All) _after = media.MediaId;
                        Post();
                        continue;
                    }
                    failed.Clear();
                    anySuccess = true;
                    try
                    {
                        await TlCore.Run(() => TlCore.AiApply(media.MediaId, job.Model, labels, job.ReplaceOld && labels.Count > 0, epoch));
                    }
                    catch
                    {
                        await Undo(media.MediaId);
                        LastError = new ExternalFailure(ExternalFailureKind.Transport);
                        Post();
                        return;
                    }
                    Done++;
                    changed++;
                    _handled++;
                    if (job.Scope == TaggingScope.All) _after = media.MediaId;
                    Post();
                    if (changed >= 12)
                    {
                        changed = 0;
                        if (!_closed) _ui.TryEnqueue(() => _onChanged?.Invoke());
                    }
                }
            }
            if (skipped != null && !cancel.IsCancellationRequested) LastError = skipped;
        }
        finally
        {
            if (!_closed && changed > 0) _ui.TryEnqueue(() => _onChanged?.Invoke());
        }
    }

    /// Before 清除所有数据: nothing queued, and the current work over.
    public async Task StopForWipe()
    {
        _paused = false;
        Cancel();
        // (the task ends before the window's queue clears it: the queue has to get its turn)
        while (_task is { } t) { await t; await Task.Delay(15); }
    }

    public void Close()
    {
        if (_closed) return;
        Cancel();
        _closed = true;
    }
}

/// The library's tagging: the services, the client, the runner and the on-device models.
public sealed class AiTagging
{
    public ExternalModels Models { get; } = new();
    public ExternalAI Client { get; }
    public AutoTagger Tagger { get; }
    public LocalModels Local => LocalModels.Instance;

    AiTagging(TwimShelf.Models.LibraryModel library)
    {
        Client = new ExternalAI(Models);
        // the tags it wrote show, and reach the other devices; tagging itself is already going
        Tagger = new AutoTagger(Models, Client, () => _ = library.Refresh(startTagging: false));
    }

    public static async Task<AiTagging> Create(TwimShelf.Models.LibraryModel library)
    {
        var a = new AiTagging(library);
        try
        {
            await a.Local.Start();
            // a tagger is chosen when one is installed and none is, or the chosen one has gone
            void Adopt() => _ = a.Models.AdoptInstalled(a.Local);
            a.Local.Changed += Adopt;
            Adopt();
        }
        catch { }
        return a;
    }

    public Task StartIfEnabled() => Tagger.StartIfEnabled();
    public Task StopForWipe() => Tagger.StopForWipe();
    public async Task Forget(bool settings)
    {
        await Models.Forget(settings);
        Local.Watch();
    }
    public void Close() => Tagger.Close();
}
