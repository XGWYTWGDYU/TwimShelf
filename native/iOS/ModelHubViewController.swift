import Combine
import UIKit

private func tierIcon(_ tier: String) -> FormViewController.Icon {
    switch tier {
    case "recommended": .init("checkmark.seal.fill", .systemGreen)
    case "usable": .init("exclamationmark.circle.fill", .systemOrange)
    case "tooLarge": .init("xmark.octagon.fill", .systemRed)
    default: .init("questionmark.circle.fill", .systemGray)
    }
}

/// The model store: the models this app offers, and a search of Hugging Face filtered down to
/// what this device can run. Importing, exporting and pulling stay on the models page.
final class ModelHubViewController: FormViewController, UISearchBarDelegate {
    private let hub = ModelHubModel()
    private var bag: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var cards: [Activity.Kind: ActivityCardView] = [:]
    private var showHidden = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("hub.title")
        navigationItem.largeTitleDisplayMode = .never
        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = L("hub.search.placeholder")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        search.searchBar.delegate = self
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        hub.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.build() }.store(in: &bag)
        observers = [ActivityCenter.changed, ModelStore.changed].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.build() }
        }
        hub.refreshDevice()
        hub.search()
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func searchBarSearchButtonClicked(_ bar: UISearchBar) {
        hub.query = bar.text ?? ""
        hub.search()
        navigationItem.searchController?.searchBar.resignFirstResponder()
    }

    func searchBarCancelButtonClicked(_ bar: UISearchBar) {
        guard !hub.query.isEmpty else { return }
        hub.query = ""
        hub.search()
    }

    private func card(_ a: Activity) -> ActivityCardView {
        let c = cards[a.kind] ?? ActivityCardView()
        cards[a.kind] = c
        c.update(a)
        return c
    }

    private func build() {
        var s: [Section] = [Section(id: "device", footer: L("hub.device.footer"), rows: [
            .value(L("hub.device.title"), ModelHub.deviceLine(hub.device), icon: .init("cpu", .systemIndigo), id: "device"),
            .toggle(L("hub.filter.fit"), hub.onlyFit, icon: .init("checkmark.seal", .systemGreen), id: "fit") { [weak self] on in self?.hub.onlyFit = on },
            .toggle(L("hub.filter.uncensored"), hub.uncensored, icon: .init("tag", .systemPurple), id: "claim") { [weak self] on in
                self?.hub.uncensored = on
                self?.hub.search()
            },
        ])]
        if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .model }) {
            s.append(Section(id: "act", header: L("models.inProgress"), rows: [
                .custom("act-model", card(a)),
                .button(L("models.cancelDownload"), icon: .init("xmark", .systemRed), destructive: true) { Core.cancelModelDownload() },
            ]))
        }
        if let e = ModelHub.lastFailure {
            s.append(Section(id: "failed", rows: [.value(L("models.downloadFailed"), e, icon: .init("exclamationmark.octagon.fill", .systemRed), id: "failed")]))
        }
        if hub.browsing {
            let store = ModelStore.shared
            let rows: [Row] = ModelCatalog.all.map { m in
                let installed = store.isInstalled(repo: m.repo)
                let state = installed ? L("hub.installed") : ModelHub.isDownloading(m.repo) ? L("models.downloading")
                    : ModelHub.partial(m.repo).map { L("models.partial.resume", ActivityCenter.bytes($0), ActivityCenter.bytes(m.bytes)) }
                    ?? "\(ModelHub.tierTitle(m.tier ?? "unknown")) · \(ActivityCenter.bytes(m.bytes))"
                if installed { return .value(m.displayName, state, icon: .init("checkmark.circle.fill", .systemGreen), id: "c:\(m.repo)") }
                return .navigation(m.displayName, detail: state, icon: tierIcon(m.tier ?? "unknown"), id: "c:\(m.repo)") { [weak self] in self?.offer(m) }
            }
            s.append(Section(id: "curated", header: L("hub.curated"), footer: L("hub.curated.footer"), rows: rows))
        }
        var rows: [Row] = hub.shown.map { r in
            .navigation(ModelHub.shortName(r.repo), detail: ModelHub.summary(r), icon: tierIcon(r.tier), id: "r:\(r.repo)") { [weak self] in
                self?.navigationController?.pushViewController(ModelHubRepoViewController(repo: r.repo), animated: true)
            }
        }
        if hub.loading { rows.append(.value(L("hub.loading"), nil, icon: .init("hourglass", .systemGray), id: "loading")) }
        if let e = hub.error {
            rows.append(.value(e, nil, icon: .init("exclamationmark.triangle.fill", .systemOrange), id: "error"))
            rows.append(.button(L("models.retry"), icon: .init("arrow.clockwise", .systemBlue), id: "retry") { [weak self] in self?.hub.search() })
        } else if hub.searched, !hub.loading, rows.isEmpty {
            rows.append(.value(L("hub.empty"), nil, icon: .init("magnifyingglass", .systemGray), id: "empty"))
        }
        if hub.overMemory > 0 {
            rows.append(.button(L("hub.overMemory", hub.overMemory), icon: .init("memorychip", .systemGray), id: "over") { [weak self] in self?.hub.onlyFit = false })
        }
        if hub.canLoadMore { rows.append(.button(L("hub.more"), icon: .init("ellipsis.circle", .systemBlue), id: "more") { [weak self] in self?.hub.loadMore() }) }
        s.append(Section(id: "results", header: hub.browsing ? L("hub.popular") : L("hub.results"), footer: L("hub.results.footer"), rows: rows))
        if !hub.hidden.isEmpty {
            // never left out silently: which ones, and why
            var rows: [Row] = [.expander(L("hub.hidden", hub.hidden.count), expanded: showHidden, icon: .init("eye.slash", .systemGray), id: "hidden") { [weak self] in
                guard let self else { return }
                self.showHidden.toggle()
                self.build()
            }]
            if showHidden { rows += hub.hidden.map { .value($0.repo, $0.reason, id: "h:\($0.repo)") } }
            s.append(Section(id: "hidden", rows: rows))
        }
        sections = s
        reloadForm()
    }

    private func offer(_ m: CatalogModel) {
        if ModelHub.isBusy { return alert(L("models.busy")) }
        let a = UIAlertController(title: L("models.download.title", m.displayName), message: L("models.download.message", m.note, ActivityCenter.bytes(m.bytes)), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.download"), style: .default) { [weak self] _ in
            do { try ModelHub.install(curated: m); self?.build() } catch { self?.alert(L("models.download.failed"), error.localizedDescription) }
        })
        present(a, animated: true)
    }
}

/// One repo of the store: what it is, each version with its real size, and what is not offered.
final class ModelHubRepoViewController: FormViewController {
    private let repo: String
    private var detail: Core.HubDetail?
    private var error: String?
    private var observers: [NSObjectProtocol] = []

    init(repo: String) { self.repo = repo; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ModelHub.shortName(repo)
        navigationItem.largeTitleDisplayMode = .never
        observers = [ActivityCenter.changed, ModelStore.changed].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.build() }
        }
        build()
        load()
    }

    private func load() {
        error = nil
        let repo = repo
        Task { @MainActor [weak self] in
            let r = await Task.detached(priority: .userInitiated) { Result { try Core.hubRepo(format: ModelHubModel.format, repo: repo) } }.value
            switch r {
            case .success(let d): self?.detail = d
            case .failure(let e): self?.error = e.localizedDescription
            }
            self?.build()
        }
    }

    private func build() {
        var s: [Section] = []
        var about: [Row] = [.value(L("hub.detail.repo"), repo, icon: .init("shippingbox", .systemBrown), id: "repo")]
        if let d = detail {
            if let a = d.repo.architecture { about.append(.value(L("hub.detail.architecture"), a, id: "arch")) }
            if let p = d.repo.params { about.append(.value(L("hub.detail.parameters"), ModelHub.parameters(p), id: "params")) }
            about.append(.value(L("hub.detail.license"), d.repo.license ?? L("hub.unknown"), id: "license"))
            about.append(.value(L("hub.detail.downloads"), "\(d.repo.downloads)", id: "downloads"))
            if d.repo.claimsUncensored { about.append(.value(L("hub.claim"), nil, icon: .init("tag", .systemPurple), id: "claim")) }
        }
        about.append(.button(L("hub.detail.openPage"), icon: .init("safari", .systemBlue), id: "page") { [repo] in
            if let u = ModelHub.pageURL(repo) { UIApplication.shared.open(u) }
        })
        s.append(Section(id: "about", footer: L("hub.unverified.footer"), rows: about))

        if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .model }), ModelHub.isDownloading(repo) {
            s.append(Section(id: "act", header: L("models.inProgress"), rows: [
                .value(a.title, a.detail, icon: .init("arrow.down.circle.fill", .systemBlue), id: "act"),
                .button(L("models.cancelDownload"), icon: .init("xmark", .systemRed), destructive: true) { Core.cancelModelDownload() },
            ]))
        }
        if let e = ModelHub.lastFailure, Core.modelStatus()?.repo == repo {
            s.append(Section(id: "failed", rows: [.value(L("models.downloadFailed"), e, icon: .init("exclamationmark.octagon.fill", .systemRed), id: "failed")]))
        }
        if let e = error {
            s.append(Section(id: "error", rows: [
                .value(e, nil, icon: .init("exclamationmark.triangle.fill", .systemOrange), id: "error"),
                .button(L("models.retry"), icon: .init("arrow.clockwise", .systemBlue), id: "retry") { [weak self] in self?.load() },
            ]))
        } else if let d = detail {
            if let p = d.problem {
                s.append(Section(id: "problem", rows: [.value(L("hub.detail.cannotInstall"), p, icon: .init("xmark.octagon.fill", .systemRed), id: "problem")]))
            }
            if !d.variants.isEmpty {
                let installed = Set(ModelStore.shared.installed.map(\.id))
                let rows: [Row] = d.variants.map { v in
                    let title = v.suggested ? L("hub.variant.suggested", v.label) : v.label
                    let line = "\(ModelHub.tierTitle(v.tier)) · \(ActivityCenter.bytes(v.bytes))"
                    if installed.contains(v.folder) { return .value(title, L("hub.installed"), icon: .init("checkmark.circle.fill", .systemGreen), id: "v:\(v.folder)") }
                    if !v.enoughSpace { return .value(title, L("hub.variant.noSpace", ActivityCenter.bytes(v.bytes)), icon: .init("externaldrive.badge.exclamationmark", .systemRed), id: "v:\(v.folder)") }
                    return .navigation(title, detail: line, icon: tierIcon(v.tier), id: "v:\(v.folder)") { [weak self] in self?.offer(v, of: d) }
                }
                s.append(Section(id: "variants", header: L("hub.detail.versions"), footer: L("hub.detail.versions.footer"), rows: rows))
            }
            if !d.skipped.isEmpty {
                s.append(Section(id: "skipped", header: L("hub.detail.skipped"), rows: d.skipped.map { .value($0.name, $0.reason, id: "s:\($0.name)") }))
            }
        } else {
            s.append(Section(id: "loading", rows: [.value(L("hub.loading"), nil, icon: .init("hourglass", .systemGray), id: "loading")]))
        }
        sections = s
        reloadForm()
    }

    private func offer(_ v: Core.HubVariant, of d: Core.HubDetail) {
        if ModelHub.isBusy { return alert(L("models.busy")) }
        let a = UIAlertController(title: L("models.download.title", ModelHub.shortName(repo)), message: L("hub.download.message", v.label, ActivityCenter.bytes(v.bytes)), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.download"), style: .default) { [weak self] _ in
            do { try ModelHub.install(v, of: d); self?.build() } catch { self?.alert(L("models.download.failed"), error.localizedDescription) }
        })
        present(a, animated: true)
    }
}
