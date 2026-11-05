import Foundation

/// One running task the UI should show progress for.
struct Activity: Equatable, Identifiable {
    enum Kind: String { case download, model, tagging, sync, verify, importing }
    let kind: Kind
    var id: String { kind.rawValue }
    var title: String
    var detail: String
    /// 0…1, or nil for indeterminate.
    var progress: Double?
    /// File to preview (photo or MP4) — the item currently being processed.
    var previewPath: String?
    var previewIsVideo: Bool

    /// A stopped worker is not proof of success. Only an explicit success fills the bar.
    func ended(outcome: String, detail: String? = nil, progress: Double? = nil) -> Activity {
        var result = self
        let prefix: String
        switch outcome {
        case "succeeded": prefix = L("activity.done")
        case "partial": prefix = L("activity.partial")
        case "failed": prefix = L("activity.failed")
        case "cancelled": prefix = L("models.cancelled")
        case "paused": prefix = L("activity.paused")
        default: prefix = L("activity.stopped")
        }
        result.title = prefix + " · " + title.replacingOccurrences(of: L("activity.running"), with: "")
        if let detail { result.detail = detail }
        result.progress = outcome == "succeeded" ? 1 : (progress ?? self.progress)
        return result
    }
}

/// Polls every source of background work (downloads, model downloads, AI tagging, sync) and
/// publishes a single list the progress UI renders on both platforms.
@MainActor
final class ActivityCenter {
    static let shared = ActivityCenter()
    static let changed = Notification.Name("ActivityCenterChanged")
    static let statsChanged = Notification.Name("LibraryStatsChanged")
    private let statsWork = LatestWork()

    private(set) var activities: [Activity] = []
    private(set) var stats: LibraryStats?
    private var timer: Timer?
    private var lastDownloadRunning = false
    private var lastModelRunning = false
    private var lastDownloadRecent: String?
    private var lastVerifyRunning = false

    func start() {
        guard timer == nil else { return }
        // Sync status changes (incl. received media) refresh stats promptly.
        NotificationCenter.default.addObserver(forName: SyncService.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
        refreshStats()
        tick()
        resumeInterruptedDownloads()
    }

    /// Links whose download was cut off by a quit or crash stay queued in the library; they
    /// continue by themselves (with the saved concurrency and interval) a moment after launch.
    private var checkedResume = false
    private func resumeInterruptedDownloads() {
        guard stats != nil, !checkedResume else { return }
        checkedResume = true
        guard (stats?.pendingJobs ?? 0) > 0, ProcessInfo.processInfo.environment["TL_SELFTEST"] == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard Core.downloadStatus()?.running != true, let n = self.stats?.pendingJobs, n > 0 else { return }
            let d = UserDefaults.standard
            let req = DownloadRequest(urls: [], concurrency: d.object(forKey: "dl.concurrency") as? Int ?? 3, intervalMs: UInt64(d.object(forKey: "dl.interval") as? Int ?? 500))
            if (try? Core.startDownload(req)) != nil { AppLog.info("download", L("activity.resume", n)); self.refreshNow() }
        }
    }

    func refreshStats() {
        statsWork.submit { [weak self] isCurrent in
            let s = await Task.detached(priority: .utility) { Core.stats() }.value
            guard let self, isCurrent(), s != self.stats else { return }
            self.stats = s
            NotificationCenter.default.post(name: Self.statsChanged, object: nil)
            NotificationCenter.default.post(name: Self.changed, object: nil)
            self.resumeInterruptedDownloads()
        }
    }

    /// Re-reads the running work now (after starting a download: its progress appears at once).
    func refreshNow() { tick() }

    private func tick() {
        var list: [Activity] = []
        let download = Core.downloadStatus()
        if let d = download, d.running {
            let recent = d.recent.last
            list.append(Activity(kind: .download, title: L("activity.downloadingPosts"),
                                 detail: "\(d.finished) / \(d.total)" + (d.failed > 0 ? L("settings.failedSuffix", d.failed) : "") + (d.active.isEmpty ? "" : L("activity.activeSuffix", d.active.count)),
                                 progress: d.total > 0 ? Double(d.finished) / Double(d.total) : nil,
                                 previewPath: recent, previewIsVideo: recent.map(isVideoPath) ?? false))
            if recent != lastDownloadRecent { lastDownloadRecent = recent; refreshStats() }
        }
        if lastDownloadRunning, download?.running != true {
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
        }
        lastDownloadRunning = download?.running ?? false
        // A model download ending anywhere (not only while the models page is open) installs it:
        // the list is re-read, and a failure goes to the problem log.
        let model = Core.modelStatus()
        let modelRunning = model?.running ?? false
        if lastModelRunning, !modelRunning, let m = model {
            if m.finished { ModelStore.shared.reload() }
            else if let e = m.error, e != L("models.cancelled") { AppLog.error("model", L("activity.modelFailed", m.repo, e)) }
        }
        lastModelRunning = modelRunning
        if let m = model, m.running {
            list.append(Activity(kind: .model, title: L("activity.downloadingModel", ModelCatalog.find(m.repo)?.displayName ?? m.repo),
                                 detail: "\(Self.bytes(m.doneBytes)) / \(Self.bytes(m.totalBytes))",
                                 progress: m.totalBytes > 0 ? Double(m.doneBytes) / Double(m.totalBytes) : nil, previewPath: nil, previewIsVideo: false))
        }
        let t = AutoTagger.shared
        if t.running {
            list.append(Activity(kind: .tagging, title: t.title, detail: "\(t.done) / \(max(t.total, t.done))",
                                 progress: t.total > 0 ? Double(t.done) / Double(t.total) : nil,
                                 previewPath: t.currentPath, previewIsVideo: t.currentKind == "video"))
        }
        if let s = SyncService.shared.status, s.syncing > 0 {
            if let t = s.receiving, t.total > 0 {
                let inFlight = t.currentSize > 0 ? Double(t.currentDone) / Double(t.currentSize) : 0
                let leftFiles = t.total > t.received ? t.total - t.received : 0
                var detail = L("activity.filesLeft", leftFiles)
                if t.totalBytes > 0 {
                    detail += " · \(Self.bytes(t.totalBytes > t.bytes ? t.totalBytes - t.bytes : 0))"
                    detail += L("activity.received", t.received, t.total, Self.bytes(t.bytes), Self.bytes(t.totalBytes))
                } else {
                    detail += L("activity.receivedShort", t.received, t.total, Self.bytes(t.bytes))
                }
                if t.currentSize > 8_000_000 { detail += L("activity.currentFile", Int(inFlight * 100)) }
                let progress = t.totalBytes > 0 ? Double(t.bytes) / Double(t.totalBytes) : (Double(t.received) + inFlight) / Double(t.total)
                list.append(Activity(kind: .sync, title: L("activity.receiving"), detail: detail,
                                     progress: progress,
                                     previewPath: t.lastPath, previewIsVideo: t.lastPath.map(isVideoPath) ?? false))
            } else {
                list.append(Activity(kind: .sync, title: L("activity.syncing"), detail: L("activity.syncDetail"), progress: nil, previewPath: nil, previewIsVideo: false))
            }
        }
        if let i = Core.importStatus(), i.running {
            list.append(Activity(kind: .importing, title: i.waiting == true ? L("activity.importWaiting") : L("activity.importing"),
                                 detail: L("activity.importProgress", i.foldersDone, i.foldersTotal, i.filesDone) + (i.issues > 0 ? L("activity.importIssues", i.issues) : ""),
                                 progress: i.foldersTotal > 0 ? Double(i.foldersDone) / Double(i.foldersTotal) : nil,
                                 previewPath: i.current, previewIsVideo: i.current.map(isVideoPath) ?? false))
        }
        if let v = Core.verifyStatus() {
            if v.running {
                list.append(Activity(kind: .verify, title: L("activity.verifying"),
                                     detail: "\(v.checked) / \(v.total) · \(Self.bytes(v.bytes))" + (v.bad > 0 ? L("activity.foundBad", v.bad) : ""),
                                     progress: v.total > 0 ? Double(v.checked) / Double(v.total) : nil,
                                     previewPath: v.current, previewIsVideo: v.current.map(isVideoPath) ?? false))
            }
            if lastVerifyRunning && !v.running { refreshStats(); NotificationCenter.default.post(name: .libraryChanged, object: nil) }
            lastVerifyRunning = v.running
        }
        list = holdBriefly(list)
        if list != activities {
            activities = list
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    /// When each card first appeared, and the last state of each running one.
    private var shownSince: [Activity.Kind: Date] = [:]
    private var lastRunning: [Activity.Kind: Activity] = [:]
    private var finishedUntil: [Activity.Kind: Date] = [:]
    static let minimumShown: TimeInterval = 2

    /// A card stays at least two seconds, so it is never gone before it can be read: work that
    /// ends sooner retains its actual terminal outcome and progress for the rest of that time, and at least a moment.
    private func holdBriefly(_ running: [Activity]) -> [Activity] {
        let now = Date()
        var out = running
        let live = Set(running.map(\.kind))
        for a in running {
            if shownSince[a.kind] == nil || finishedUntil[a.kind] != nil { shownSince[a.kind] = now }
            finishedUntil[a.kind] = nil
            lastRunning[a.kind] = a
        }
        for (kind, last) in lastRunning where !live.contains(kind) {
            if finishedUntil[kind] == nil {
                let since = shownSince[kind] ?? now
                finishedUntil[kind] = max(since.addingTimeInterval(Self.minimumShown), now.addingTimeInterval(1.2))
            }
            if let until = finishedUntil[kind], now < until {
                out.append(completed(last))
            } else {
                lastRunning[kind] = nil; finishedUntil[kind] = nil; shownSince[kind] = nil
            }
        }
        return out
    }

    private func completed(_ last: Activity) -> Activity {
        switch last.kind {
        case .download:
            guard let d = Core.downloadStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: d.outcome, detail: L("activity.downloadSummary", d.done, d.skipped, d.failed, d.total), progress: d.total > 0 ? Double(d.finished) / Double(d.total) : nil)
        case .model:
            guard let m = Core.modelStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: m.finished ? "succeeded" : (m.error == L("models.cancelled") ? "cancelled" : "failed"), detail: m.error, progress: m.totalBytes > 0 ? Double(m.doneBytes) / Double(m.totalBytes) : nil)
        case .tagging:
            let t = AutoTagger.shared
            return last.ended(outcome: t.outcome, detail: t.lastError ?? "\(t.done) / \(t.total)", progress: t.total > 0 ? Double(t.done) / Double(t.total) : nil)
        case .importing:
            guard let i = Core.importStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: i.outcome, detail: L("activity.importSummary", i.foldersDone, i.foldersTotal, i.filesDone, i.issues), progress: i.foldersTotal > 0 ? Double(i.foldersDone) / Double(i.foldersTotal) : nil)
        case .verify:
            guard let v = Core.verifyStatus() else { return last.ended(outcome: "stopped") }
            return last.ended(outcome: v.outcome, detail: L("activity.verifySummary", v.checked, v.total, v.bad), progress: v.total > 0 ? Double(v.checked) / Double(v.total) : nil)
        case .sync:
            // No aggregate session-success signal: report the observed state without
            // claiming all peers or every file have converged.
            var result = last
            result.title = SyncService.shared.stateText
            result.progress = nil
            result.detail = L("activity.syncSeePage")
            return result
        }
    }

    static func bytes(_ b: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file) }

    /// "帖子 12 · 照片 30 · 视频 4" for cross-device checks.
    var statsLine: String {
        guard let s = stats else { return "" }
        return L("activity.stats", s.posts, s.photos, s.videos)
    }
}
