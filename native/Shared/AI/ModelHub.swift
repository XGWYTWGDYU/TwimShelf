import Combine
import Foundation

/// The model store's state, for the iOS and the Mac page: what was searched, what came back, what
/// is left out and why. The searching, checking and ranking are the core's, the same on every app.
@MainActor
final class ModelHubModel: ObservableObject {
    /// MLX on Apple devices: the same format the Flutter app's Apple builds use.
    nonisolated static let format = "mlx"

    /// The debug tour's picture of a search.
    nonisolated(unsafe) static var debugQuery: String?

    @Published var query = ModelHubModel.debugQuery ?? ""
    @Published var uncensored = false
    @Published var onlyFit = true
    @Published private(set) var items: [Core.HubRepo] = []
    @Published private(set) var hidden: [Core.HubHidden] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var searched = false
    @Published private(set) var device: Core.HubDevice?
    private var next: String?
    /// An answer to an earlier search that arrives late is not shown over a newer one.
    private var generation = 0

    var canLoadMore: Bool { next != nil && !loading }
    var shown: [Core.HubRepo] { onlyFit ? items.filter { $0.tier != "tooLarge" } : items }
    var overMemory: Int { onlyFit ? items.count - shown.count : 0 }
    /// The store's first page: the curated models lead until a search is made.
    var browsing: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty && !uncensored }

    func refreshDevice() { device = Core.hubDevice() }

    func search() {
        generation += 1
        items = []; hidden = []; next = nil
        run(next: nil, generation: generation)
    }

    func loadMore() {
        guard let n = next, !loading else { return }
        run(next: n, generation: generation)
    }

    private func run(next page: String?, generation run: Int) {
        loading = true
        error = nil
        let (q, u) = (query, uncensored)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Core.hubSearch(format: Self.format, query: q, uncensored: u, next: page) }
            await self?.finish(result, generation: run)
        }
    }

    private func finish(_ result: Result<Core.HubPage, Error>, generation run: Int) {
        guard run == generation else { return }
        loading = false
        searched = true
        switch result {
        case .success(let p):
            let seen = Set(items.map(\.repo))
            items += p.items.filter { !seen.contains($0.repo) }
            hidden += p.hidden
            next = p.next
            device = p.device
        case .failure(let e):
            error = e.localizedDescription
        }
    }
}

/// Words and checks both Apple pages share.
@MainActor
enum ModelHub {
    static func tierTitle(_ tier: String) -> String { L("hub.tier." + tier) }   // i18n-keys: hub.tier.*

    static func parameters(_ n: UInt64) -> String { String(format: "%.1fB", Double(n) / 1e9) }   // i18n-exempt: unit symbol

    /// How the store sums up a repo in a list. A size here is an estimate; the repo's page has the real one.
    static func summary(_ r: Core.HubRepo) -> String {
        var parts = [tierTitle(r.tier)]
        if let b = r.estimatedBytes { parts.append(L("hub.estimate", ActivityCenter.bytes(b))) }
        if let p = r.params { parts.append(parameters(p)) }
        return parts.joined(separator: " · ")
    }

    static func shortName(_ repo: String) -> String { repo.components(separatedBy: "/").last ?? repo }

    static func deviceLine(_ d: Core.HubDevice?) -> String {
        // as the device is sold: 24 GB, not 25.77
        let memory = d?.memoryBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) } ?? L("hub.unknown")
        let free = d?.freeBytes.map { ActivityCenter.bytes($0) } ?? L("hub.unknown")
        return L("hub.device", memory, free)
    }

    static func pageURL(_ repo: String) -> URL? { URL(string: "https://huggingface.co/" + repo) }

    static func isDownloading(_ repo: String) -> Bool { Core.modelStatus().map { $0.running && $0.repo == repo } ?? false }
    static var isBusy: Bool { Core.modelStatus()?.running ?? false }
    /// How much of `repo` an interrupted download left: downloading again continues from it.
    static func partial(_ repo: String) -> UInt64? { Core.interruptedModels().first { $0.repo == repo }?.bytes }

    /// The last download's failure, to say on the page that started it.
    static var lastFailure: String? {
        guard let s = Core.modelStatus(), !s.running, !s.finished, let e = s.error, e != L("models.cancelled") else { return nil }
        return e
    }

    static func install(curated m: CatalogModel) throws {
        try Core.hubInstall(.init(format: format, repo: m.repo, revision: nil, weights: nil, projector: nil, bytes: m.bytes, folder: m.repo.replacingOccurrences(of: "/", with: "--")))
    }

    static func install(_ v: Core.HubVariant, of d: Core.HubDetail) throws {
        try Core.hubInstall(.init(format: format, repo: d.repo.repo, revision: d.revision, weights: v.weights, projector: v.projector, bytes: v.bytes, folder: v.folder))
    }

    private static var format: String { ModelHubModel.format }
}
