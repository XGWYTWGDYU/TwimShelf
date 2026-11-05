import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Runs AI tagging work in the background, one job at a time:
///  • automatic: media no model has analysed yet, with the default tagger (changing the default
///    model never re-triggers this — already-analysed media are skipped);
///  • re-tag of chosen media (one photo, or everything) with a chosen model, optionally replacing
///    old unendorsed AI tags. Tags you added or endorsed are never removed (see `rules::retag_plan`).
/// Afterwards it embeds any tag labels the semantic model has not seen. Pauses in the background
/// (iOS does not allow GPU work there).
@MainActor
final class AutoTagger {
    static let shared = AutoTagger()
    static let progressChanged = Notification.Name("AutoTaggerProgress")

    enum Scope: Equatable { case untagged, media([Core.MediaRef]), all }
    struct Job: Equatable {
        var scope: Scope; var model: String; var replaceOld: Bool
        /// Where a paused whole-library re-tag resumes: after this media id (ids are visited in
        /// order, so media added or deleted meanwhile are never skipped or done twice), and how
        /// many it had done (for the progress).
        var resumeAfter = ""
        var doneBefore = 0
        var isLibraryRun: Bool { scope == .all || scope == .untagged }
    }

    private(set) var running = false
    private(set) var outcome = "idle"
    private(set) var done = 0
    private(set) var total = 0
    private(set) var title = ""
    /// The media currently being analysed (for progress previews).
    private(set) var currentPath: String?
    private(set) var currentKind: String = "photo"
    private(set) var lastError: String?
    private var queue: [Job] = []
    private var task: Task<Void, Never>?
    /// Media whose attempts were given back after a run of failures of the model (this launch).
    private var givenBack = Set<String>()
    /// The job running now, and how far a whole-library re-tag got (for pausing and resuming).
    private var current: Job?
    private var currentAfter = ""
    private var active = true
    private let launchedAt = Date()
    private var startScheduled = false

    private init() {
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        // iOS allows no GPU work in the background: pause (a whole-library re-tag keeps its place
        // and its queue) and resume on return, instead of silently dropping the run
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.active = false; self.pause() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.active = true; self.pump(); self.startIfEnabled() }
        }
        #endif
        // New media (download, import, sync) → analyse it; ignore our own notifications.
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { n in
            MainActor.assumeIsolated { if n.object as AnyObject? !== self, !self.running { self.startIfEnabled() } }
        }
    }

    /// (analysed by any model, total media).
    var counts: (done: Int, total: Int) { Core.aiCounts() }

    /// Starts automatic tagging of not-yet-analysed media if enabled.
    func startIfEnabled() {
        guard ModelStore.shared.autoTag, active, let model = ModelStore.shared.activeTaggerId, AIEngine.canRun(model) else { return }
        #if os(iOS)
        // not while the app is starting (sync, thumbnails and the first screens need the memory
        // then): loading a model on top of them got the app ended by iOS on every launch
        let settle = 20 - Date().timeIntervalSince(launchedAt)
        if settle > 0 {
            if !startScheduled {
                startScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + settle) { self.startScheduled = false; self.startIfEnabled() }
            }
            return
        }
        #endif
        // a model that does not fit in memory here is never loaded (iOS would end the app):
        // say so, and leave the work to the other devices
        if let e = AIEngine.memoryCheck(model) {
            if lastError != e.localizedDescription { lastError = e.localizedDescription; AppLog.warn("ai", e.localizedDescription); post() }
            return
        }
        // Deleting, undoing or moving to folders also posts libraryChanged; those never make
        // media unanalysed, so only start (and show the card) when something is really new.
        Task {
            // media this device gave up on do not count (another device can analyse them)
            let pending = await Task.detached { !Core.aiPending(model: model, since: 0, limit: 1).isEmpty }.value
            if pending { self.enqueue(Job(scope: .untagged, model: model, replaceOld: false)) }
        }
    }

    /// Re-tags specific media (e.g. from a photo's context menu) right away: a running
    /// whole-library run pauses after the current image and resumes afterwards.
    func retag(_ media: [Core.MediaRef], model: String, replaceOld: Bool) {
        enqueue(Job(scope: .media(media), model: model, replaceOld: replaceOld), front: true)
        if let c = current, c.isLibraryRun {
            queue.insert(resumable(c), at: min(1, queue.count))
            task?.cancel()
        }
    }

    /// Re-tags the whole library with `model` (e.g. after the prompt changed). A new run
    /// replaces any whole-library run that is running or waiting — it never queues behind it.
    func retagAll(model: String, replaceOld: Bool) {
        queue.removeAll { $0.isLibraryRun }
        let wasRunning = current?.isLibraryRun == true
        enqueue(Job(scope: .all, model: model, replaceOld: replaceOld), front: true)
        if wasRunning { task?.cancel() }
    }

    func stop() { queue.removeAll(); task?.cancel() }

    /// Stops after the current image; a whole-library run is queued again from where it got.
    private func pause() {
        if let c = current, c.isLibraryRun { queue.insert(resumable(c), at: 0) }
        task?.cancel()
    }

    private func resumable(_ c: Job) -> Job {
        var r = c
        if c.scope == .all { r.resumeAfter = currentAfter; r.doneBefore = done }
        return r
    }

    private func enqueue(_ job: Job, front: Bool = false) {
        guard AIEngine.canRun(job.model) else { lastError = AIEngine.EngineError.simulator.localizedDescription; post(); return }
        if queue.contains(job) { return }
        if front { queue.insert(job, at: 0) } else { queue.append(job) }
        pump()
    }

    private func pump() {
        guard !running, active, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        running = true
        outcome = "running"
        lastError = nil
        current = job
        currentAfter = job.resumeAfter
        task = Task {
            await run(job)
            outcome = Task.isCancelled ? "cancelled" : (lastError != nil ? (done > 0 ? "partial" : "failed") : "succeeded")
            running = false
            current = nil
            currentPath = nil
            post()
            if queue.isEmpty { await embedMissingLabels() }
            pump()
        }
    }

    private func post() { NotificationCenter.default.post(name: Self.progressChanged, object: nil) }

    private func run(_ job: Job) async {
        guard let epoch = try? Core.epoch() else { return }
        let name = ModelStore.shared.displayName(job.model)
        var changedSinceReload = 0
        done = 0
        switch job.scope {
        case .untagged: let c = Core.aiCounts(); total = c.total - c.done; title = L("ai.activity.new", name)
        case .media(let m): total = m.count; title = L("ai.activity.retag", name)
        case .all: done = job.doneBefore; total = max(Core.aiCounts().total, done); title = L("ai.activity.retagAll", name)
        }
        post()
        var after = job.resumeAfter
        var first = true
        // Failures of single images never stop the run or block the queue: each is recorded on
        // this device only (never synced, so another device can still analyse it), skipped for
        // the rest of this run, and skipped for good on this device after
        // `rules::MAX_AI_ATTEMPTS` attempts. An attempt is counted before the model runs, so a
        // crash during it counts too. Several failures of the model in a row mean the model or
        // the device is the problem, not the images: those attempts are taken back and the run
        // stops. A file that cannot be read says nothing about the model: it never counts toward
        // that, so a few damaged files never stop the run from reaching the ones behind them.
        let runStart = Int(Date().timeIntervalSince1970) - 1
        var failedInARow: [String] = []
        // The library's tags (current names after renames), refreshed as the run goes on so new
        // tags and renames made meanwhile are used right away.
        var vocabulary: [String] = []
        var sinceVocab = Int.max
        while !Task.isCancelled {
            let batch: [Core.MediaRef]
            switch job.scope {
            case .untagged: batch = await Task.detached { Core.aiPending(model: job.model, since: runStart, limit: 8) }.value
            case .media(let m): batch = first ? m : []
            case .all: batch = await Task.detached { [after] in Core.mediaPage(after: after, limit: 16) }.value
            }
            first = false
            if let last = batch.last { after = last.mediaId }
            if batch.isEmpty { break }
            // Media imported, synced or deleted meanwhile change what is left to do.
            if job.scope == .untagged {
                let (c, skipped) = await Task.detached { (Core.aiCounts(), Core.aiFailures().count) }.value
                total = done + max(0, c.total - c.done - skipped)
                post()
            }
            for m in batch {
                if Task.isCancelled { break }
                currentPath = m.path
                currentKind = m.kind
                post()
                var labels: [String] = []
                if sinceVocab >= 10 {
                    vocabulary = await Task.detached { Array(Core.allTags().prefix(150).map(\.label)) }.value
                    sinceVocab = 0
                }
                sinceVocab += 1
                let existing = await Task.detached { Core.mediaTags(m.mediaId) }.value
                let counted = job.scope == .untagged
                if counted { await Task.detached { Core.aiAttempt(.begin, mediaId: m.mediaId, model: job.model) }.value }
                let failure: String?
                var unreadable = false
                if let img = await Task.detached(priority: .utility, operation: { AIEngine.stillImage(path: m.path, kind: m.kind) }).value {
                    do { labels = try await AIEngine.shared.tags(for: img, repo: job.model, postText: m.text, existing: existing, vocabulary: vocabulary); failure = nil }
                    catch is CancellationError {
                        if counted { await Task.detached { Core.aiAttempt(.undo, mediaId: m.mediaId, model: job.model) }.value }
                        return
                    }
                    catch let e as AIEngine.EngineError {
                        // the model or the device, not this image: nothing is counted against it
                        if counted { await Task.detached { Core.aiAttempt(.undo, mediaId: m.mediaId, model: job.model) }.value }
                        lastError = e.localizedDescription
                        post()
                        return
                    }
                    catch { failure = error.localizedDescription }
                } else { failure = L("ai.err.unreadable"); unreadable = true }
                if let failure {
                    AppLog.error("ai", L("ai.err.analyze", m.mediaId.prefix(12), failure))
                    if counted { await Task.detached { Core.aiAttempt(.failed, mediaId: m.mediaId, model: job.model, reason: failure) }.value }
                    if !unreadable {
                        failedInARow.append(m.mediaId)
                        if failedInARow.count >= 3 {
                            // not these images: the model or the device. Take the attempts back, but only once
                            // for the same media (this launch): the next run would pick the same ones first, and
                            // images the model cannot handle would hold up every run behind them for good.
                            if counted {
                                let ids = failedInARow.filter { !givenBack.contains($0) }
                                givenBack.formUnion(ids)
                                await Task.detached { for id in ids { Core.aiAttempt(.undo, mediaId: id, model: job.model) } }.value
                            }
                            lastError = failure
                            post()
                            return
                        }
                    }
                    if job.scope == .all { currentAfter = m.mediaId }
                    post()
                    continue
                }
                failedInARow = []
                // (written off the main thread: it is a database write plus a log entry)
                let replace = job.replaceOld && !labels.isEmpty
                if Task.isCancelled {
                    if counted { await Task.detached { Core.aiAttempt(.undo, mediaId: m.mediaId, model: job.model) }.value }
                    return
                }
                do {
                    try await Task.detached { [labels] in try Core.aiApply(mediaId: m.mediaId, model: job.model, labels: labels, replaceOld: replace, epoch: epoch) }.value
                } catch {
                    if counted { await Task.detached { Core.aiAttempt(.undo, mediaId: m.mediaId, model: job.model) }.value }
                    lastError = error.localizedDescription
                    post()
                    return
                }
                done += 1
                if job.scope == .all { currentAfter = m.mediaId }
                changedSinceReload += 1
                post()
                if changedSinceReload >= 12 { changedSinceReload = 0; NotificationCenter.default.post(name: .libraryChanged, object: self) }
            }
        }
        if changedSinceReload > 0 { NotificationCenter.default.post(name: .libraryChanged, object: self) }
    }

    /// Computes vectors for every tag label the default embedder has not seen.
    func embedMissingLabels() async {
        guard let repo = ModelStore.shared.activeEmbedderId, AIEngine.isSupported else { return }
        guard let epoch = try? Core.epoch() else { return }
        let missing = Core.labelsMissingVectors(model: repo)
        guard !missing.isEmpty else { return }
        for chunk in stride(from: 0, to: missing.count, by: 64).map({ Array(missing[$0..<min($0 + 64, missing.count)]) }) {
            if Task.isCancelled { return }
            do {
                let vecs = try await AIEngine.shared.embed(chunk, repo: repo)
                try Task.checkCancellation()
                try Core.setVectors(model: repo, items: Array(zip(chunk, vecs)), epoch: epoch)
            } catch {
                lastError = error.localizedDescription
                post()
                return
            }
        }
    }
}

extension Notification.Name {
    /// Posted when library contents changed outside the feed (downloads, AI tags, sync).
    static let libraryChanged = Notification.Name("LibraryChanged")
}
