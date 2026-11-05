#if DEBUG
import Foundation

/// Development self-test, driven by environment variables (debug builds only):
///   TL_IMPORT_DIR=path      import a legacy folder tree
///   TL_SELFTEST=path.json   download the smallest tagger + embedder, tag everything,
///                           run semantic searches, and write a JSON report to path.json
enum SelfTest {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["TL_IMPORT_DIR"] {
            let r = try? Core.importLegacyDirectory(URL(fileURLWithPath: dir))
            NSLog("selftest import: %d posts %d media", r?.posts ?? -1, r?.media ?? -1)
        }
        if let codeFile = env["TL_SYNC_HOST"] { Task { @MainActor in await syncHost(codeFile: codeFile) } }
        if let codeFile = env["TL_SYNC_JOIN"], let out = env["TL_SYNC_REPORT"] { Task { @MainActor in await syncJoin(codeFile: codeFile, report: URL(fileURLWithPath: out)) } }
        guard let out = env["TL_SELFTEST"] else { return }
        Task { @MainActor in await run(report: URL(fileURLWithPath: out)) }
    }

    private static func log(_ r: inout [String: Any], _ k: String, _ v: Any, _ url: URL) {
        r[k] = v
        if let d = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
        NSLog("selftest %@: %@", k, "\(v)")
    }

    @MainActor static func syncHost(codeFile: String) async {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if !SyncService.shared.hasAccount { SyncService.shared.createAccount() }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        SyncService.shared.refreshStatus()
        // "code device-id": the joiner pairs only with this exact device, never with others on the LAN.
        if let code = SyncService.shared.beginPairing(), let dev = SyncService.shared.status?.deviceId {
            try? "\(code) \(dev)".write(toFile: codeFile, atomically: true, encoding: .utf8)
        }
        NSLog("selftest sync host ready")
    }

    @MainActor static func syncJoin(codeFile: String, report url: URL) async {
        var r: [String: Any] = [:]
        let before = (try? Core.feed(FeedRequest(seed: 1)))?.count ?? -1
        log(&r, "items_before", before, url)
        let svc = SyncService.shared
        var code: String?
        var peer: SyncService.Peer?
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 60 {
            let parts = (try? String(contentsOfFile: codeFile, encoding: .utf8))?.split(separator: " ").map(String.init) ?? []
            if parts.count == 2 { code = parts[0] }
            peer = parts.count == 2 ? svc.peers.values.first { $0.device == parts[1] && $0.host != nil } : nil
            if code != nil, peer != nil { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let code, let peer else { log(&r, "result", "no peer/code (peers: \(svc.peers.count))", url); return }
        log(&r, "discovered_after_s", Date().timeIntervalSince(t0), url)
        log(&r, "peer", "\(peer.name) \(peer.host ?? "")", url)
        do { try svc.join(peer: peer, code: code) } catch { log(&r, "result", "join error \(error)", url); return }
        repeat { try? await Task.sleep(nanoseconds: 300_000_000); svc.refreshStatus() } while svc.status?.join.running != false
        if let e = svc.status?.join.error { log(&r, "result", "join failed: \(e)", url); return }
        _ = svc.adoptJoinResultIfAny()
        log(&r, "joined_after_s", Date().timeIntervalSince(t0), url)
        let t1 = Date()
        var after = 0
        var samples: [String] = []
        var firstVisible: Double?
        while Date().timeIntervalSince(t1) < 300 {
            svc.syncAll()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            svc.refreshStatus()
            after = (try? Core.feed(FeedRequest(seed: 1)))?.count ?? 0
            if after > before, firstVisible == nil { firstVisible = Date().timeIntervalSince(t1) }
            if let t = svc.status?.receiving { samples.append("\(t.received)/\(t.total) \(t.bytes / 1_000_000)MB feed=\(after) stats=\(ActivityCenter.shared.statsLine)") }
            if after > before, svc.status?.syncing == 0, svc.status?.receiving == nil { break }
        }
        log(&r, "first_media_visible_after_s", firstVisible ?? -1, url)
        log(&r, "progress_samples", Array(samples.prefix(6)) + (samples.count > 6 ? ["…", samples.last!] : []), url)
        log(&r, "synced_after_s", Date().timeIntervalSince(t1), url)
        log(&r, "items_after", after, url)
        let tagged = (try? Core.feed(FeedRequest(terms: ["白墙"], scope: .both, seed: 1, fuzzy: false)))?.count ?? 0
        log(&r, "items_tagged_白墙", tagged, url)
        let all = (try? Core.feed(FeedRequest(seed: 1))) ?? []
        log(&r, "items_with_ai_sources", all.filter { $0.tags.contains { !$0.models.isEmpty } }.count, url)
        log(&r, "pending_ai_after_sync", Core.aiPending(limit: 100).count, url)
        log(&r, "stats", ActivityCenter.shared.statsLine, url)
        log(&r, "peers_status", svc.status?.peers.map { "\($0.name): last=\($0.lastSync) err=\($0.lastError ?? "-")" } ?? [], url)
        log(&r, "result", after > before ? "ok" : "no data", url)
    }

    /// Uses only models that are already installed — never downloads anything.
    @MainActor static func run(report url: URL) async {
        var r: [String: Any] = ["started": Date().description]
        let store = ModelStore.shared
        store.reload()
        guard let tagger = store.taggers.first?.id else { log(&r, "result", "no tagger installed (self-test never downloads)", url); return }
        log(&r, "models", store.installed.map(\.id), url)
        store.activeTaggerId = tagger
        store.activeEmbedderId = store.embedders.first?.id

        // 1. automatic tagging of untagged media
        var tagged: [[String: Any]] = []
        for m in Core.aiPending(limit: 50) {
            guard let img = AIEngine.stillImage(path: m.path, kind: m.kind) else { continue }
            let t0 = Date()
            do {
                let labels = try await AIEngine.shared.tags(for: img, repo: tagger, postText: m.text)
                try Core.aiApply(mediaId: m.mediaId, model: tagger, labels: labels)
                tagged.append(["media": String(m.mediaId.prefix(8)), "labels": labels, "ms": Int(Date().timeIntervalSince(t0) * 1000)])
            } catch { tagged.append(["media": String(m.mediaId.prefix(8)), "error": "\(error)"]) }
        }
        log(&r, "tagged", tagged, url)
        log(&r, "pending_after", Core.aiPending(limit: 100).count, url)

        // 2. provenance visible on feed items
        let items = (try? Core.feed(FeedRequest(seed: 1))) ?? []
        let withSources = items.filter { $0.tags.contains { !$0.models.isEmpty } }.count
        log(&r, "items_with_ai_sources", "\(withSources)/\(items.count)", url)

        // 3. re-tag with replace keeps endorsed + user tags, drops other unendorsed AI tags
        if let target = items.first(where: { $0.tags.filter(\.isAI).count >= 2 }) {
            let ai = target.tags.filter { $0.isAI && !$0.isUser }.map(\.label)
            let endorse = ai[0]
            try? Core.addTag(endorse, to: target.mediaId)               // endorse one
            try? Core.addTag("我的测试标签", to: target.mediaId)          // a user tag
            try? Core.aiApply(mediaId: target.mediaId, model: tagger, labels: ["自检新标签"], replaceOld: true)
            let after = ((try? Core.feed(FeedRequest(seed: 1))) ?? []).first { $0.mediaId == target.mediaId }?.tags ?? []
            let has = { (l: String) in after.contains { $0.label == l } }
            log(&r, "retag_check", [
                "endorsed_kept": has(endorse), "user_kept": has("我的测试标签"), "new_added": has("自检新标签"),
                "unendorsed_removed": ai.dropFirst().allSatisfy { !has($0) },
                "endorsed_origin": after.first { $0.label == endorse }?.origin ?? 0,
            ], url)
        }

        // 4. changing the default model does not re-trigger tagging
        store.activeTaggerId = store.taggers.last?.id
        log(&r, "pending_after_model_switch", Core.aiPending(limit: 100).count, url)
        store.activeTaggerId = tagger
        log(&r, "result", "ok", url)
    }
}
#endif
