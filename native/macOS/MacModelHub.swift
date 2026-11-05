import AppKit
import SwiftUI

private func tierColor(_ tier: String) -> Color {
    switch tier {
    case "recommended": .green
    case "usable": .orange
    case "tooLarge": .red
    default: .secondary
    }
}

/// The model store: the models this app offers, and a search of Hugging Face filtered down to
/// what this device can run. Importing, exporting and pulling stay on the models page.
struct ModelHubPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var hub = ModelHubModel()
    @State private var showHidden = ModelHubModel.debugQuery != nil

    var body: some View {
        let _ = live.count
        SettingsCanvas {
            header
            downloadCard
            if hub.browsing { curated }
            results
            if !hub.hidden.isEmpty { hiddenCard }
        }
        .onAppear {
            live.start(every: 1)
            hub.refreshDevice()
            if !hub.searched { hub.search() }
        }
        .onDisappear { live.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                TextField(L("hub.search.placeholder"), text: $hub.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { hub.search() }
                    .accessibilityIdentifier("hubSearch")
                Button(L("hub.search")) { hub.search() }.disabled(hub.loading)
            }
            FlowLayout(spacing: 8) {
                ChipButton(title: L("hub.filter.fit"), symbol: "checkmark.seal", selected: hub.onlyFit) { hub.onlyFit.toggle() }
                ChipButton(title: L("hub.filter.uncensored"), symbol: "tag", selected: hub.uncensored) {
                    hub.uncensored.toggle()
                    hub.search()
                }
            }
            Text(ModelHub.deviceLine(hub.device) + "\n" + L("hub.device.footer")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var downloadCard: some View {
        if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .model }) {
            Card(tint: .accentColor, spacing: 12) {
                ActivityRow(activity: a)
                HStack { Spacer(); Button(L("models.cancelDownload")) { Core.cancelModelDownload() } }
            }
        } else if let e = ModelHub.lastFailure {
            Banner(text: L("hub.line", L("models.downloadFailed"), e), symbol: "exclamationmark.octagon.fill", color: .red)
        }
    }

    private var curated: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("hub.curated"), note: L("hub.curated.footer"))
            Card(spacing: 12) {
                ForEach(Array(ModelCatalog.all.enumerated()), id: \.element.repo) { i, m in
                    if i > 0 { RowDivider() }
                    curatedRow(m)
                }
            }
        }
    }

    private func curatedRow(_ m: CatalogModel) -> some View {
        let part = ModelHub.partial(m.repo)
        return CardRow(symbol: m.role == .tagger ? "eye.fill" : "magnifyingglass", color: m.role == .tagger ? .purple : .teal, title: m.displayName,
                       detail: part.map { L("mac.models.partial", ActivityCenter.bytes($0), ActivityCenter.bytes(m.bytes)) } ?? "\(m.note) · \(ActivityCenter.bytes(m.bytes))") {
            if ModelStore.shared.isInstalled(repo: m.repo) {
                Pill(text: L("hub.installed"), color: .green, symbol: "checkmark")
            } else {
                Pill(text: ModelHub.tierTitle(m.tier ?? "unknown"), color: tierColor(m.tier ?? "unknown"))
                Button(ModelHub.isDownloading(m.repo) ? L("models.downloading") : part != nil ? L("settings.resume") : L("common.download")) {
                    macChoose(env.window, title: L("models.download.title", m.displayName), message: L("mac.models.download.message", ActivityCenter.bytes(m.bytes)), options: [L("common.download")]) { _ in
                        do { try ModelHub.install(curated: m) } catch { macAlert(env.window, L("models.download.failed"), error.localizedDescription) }
                    }
                }
                .disabled(ModelHub.isBusy)
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(hub.browsing ? L("hub.popular") : L("hub.results"), note: L("hub.results.footer"))
            if let e = hub.error {
                HStack(alignment: .top, spacing: 10) {
                    Banner(text: e)
                    Button(L("models.retry")) { hub.search() }
                }
            }
            if hub.searched, !hub.loading, hub.shown.isEmpty, hub.error == nil {
                Card { Text(L("hub.empty")).foregroundStyle(.secondary) }
            }
            ForEach(hub.shown, id: \.repo) { r in repoCard(r) }
            if hub.loading {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("hub.loading")).foregroundStyle(.secondary) }.padding(.horizontal, 4)
            }
            HStack {
                if hub.overMemory > 0 { Button(L("hub.overMemory", hub.overMemory)) { hub.onlyFit = false }.buttonStyle(.link) }
                Spacer()
                if hub.canLoadMore { Button(L("hub.more")) { hub.loadMore() } }
            }
            .padding(.horizontal, 4)
        }
    }

    private func repoCard(_ r: Core.HubRepo) -> some View {
        Card(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: "cube.fill", color: tierColor(r.tier) == .secondary ? .gray : tierColor(r.tier), size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ModelHub.shortName(r.repo)).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    Text(r.repo.components(separatedBy: "/").first ?? "").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 5) {
                        Pill(text: ModelHub.tierTitle(r.tier), color: tierColor(r.tier))
                        if let b = r.estimatedBytes { Pill(text: L("hub.estimate", ActivityCenter.bytes(b))) }
                        if let p = r.params { Pill(text: ModelHub.parameters(p)) }
                        if let a = r.architecture { Pill(text: a) }
                        if r.claimsUncensored { Pill(text: L("hub.claim"), color: .purple) }
                    }
                }
                Spacer(minLength: 8)
                Button(L("hub.view")) {
                    env.open(ModelHub.shortName(r.repo), MacSettingsPages.modelHubRepo(r.repo))
                }
            }
        }
    }

    private var hiddenCard: some View {
        Card(spacing: 8) {
            Button {
                withAnimation(.snappy) { showHidden.toggle() }
            } label: {
                HStack {
                    Image(systemName: "eye.slash")
                    Text(L("hub.hidden", hub.hidden.count))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showHidden ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            if showHidden {
                ForEach(hub.hidden, id: \.repo) { h in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(h.repo).font(.caption.weight(.medium)).textSelection(.enabled)
                        Text(h.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// One repo of the store: what it is, each version with its real size, and what is not offered.
struct ModelHubRepoPageView: View {
    let repo: String
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @State private var detail: Core.HubDetail?
    @State private var error: String?

    var body: some View {
        let _ = live.count
        SettingsCanvas {
            about
            if let a = ActivityCenter.shared.activities.first(where: { $0.kind == .model }), ModelHub.isDownloading(repo) {
                Card(tint: .accentColor, spacing: 12) {
                    ActivityRow(activity: a)
                    HStack { Spacer(); Button(L("models.cancelDownload")) { Core.cancelModelDownload() } }
                }
            } else if let e = ModelHub.lastFailure, Core.modelStatus()?.repo == repo {
                Banner(text: L("hub.line", L("models.downloadFailed"), e), symbol: "exclamationmark.octagon.fill", color: .red)
            }
            if let error {
                HStack(alignment: .top, spacing: 10) {
                    Banner(text: error)
                    Button(L("models.retry")) { load() }
                }
            } else if let detail {
                if let p = detail.problem { Banner(text: L("hub.line", L("hub.detail.cannotInstall"), p), symbol: "xmark.octagon.fill", color: .red) }
                if !detail.variants.isEmpty { versions(detail) }
                if !detail.skipped.isEmpty { skipped(detail) }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("hub.loading")).foregroundStyle(.secondary) }
            }
        }
        .onAppear {
            live.start(every: 1)
            if detail == nil { load() }
        }
        .onDisappear { live.stop() }
    }

    private func load() {
        error = nil
        let repo = repo
        Task { @MainActor in
            let r = await Task.detached(priority: .userInitiated) { Result { try Core.hubRepo(format: ModelHubModel.format, repo: repo) } }.value
            switch r {
            case .success(let d): detail = d
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private var about: some View {
        Card(spacing: 10) {
            CardRow(symbol: "cube.fill", color: .indigo, title: repo, detail: L("hub.unverified.footer")) {
                Button(L("hub.detail.openPage")) { if let u = ModelHub.pageURL(repo) { NSWorkspace.shared.open(u) } }
            }
            if let d = detail {
                FlowLayout(spacing: 5) {
                    if let a = d.repo.architecture { Pill(text: a) }
                    if let p = d.repo.params { Pill(text: ModelHub.parameters(p)) }
                    Pill(text: L("hub.line", L("hub.detail.license"), d.repo.license ?? L("hub.unknown")))
                    Pill(text: L("hub.line", L("hub.detail.downloads"), "\(d.repo.downloads)"))
                    if d.repo.claimsUncensored { Pill(text: L("hub.claim"), color: .purple) }
                }
            }
        }
    }

    private func versions(_ d: Core.HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("hub.detail.versions"), note: L("hub.detail.versions.footer"))
            Card(spacing: 12) {
                ForEach(Array(d.variants.enumerated()), id: \.element.folder) { i, v in
                    if i > 0 { RowDivider() }
                    versionRow(v, d)
                }
            }
        }
    }

    private func versionRow(_ v: Core.HubVariant, _ d: Core.HubDetail) -> some View {
        CardRow(title: v.label, detail: ActivityCenter.bytes(v.bytes)) {
            if ModelStore.shared.installed.contains(where: { $0.id == v.folder }) {
                Pill(text: L("hub.installed"), color: .green, symbol: "checkmark")
            } else {
                if v.suggested { Pill(text: L("hub.variant.suggestedShort"), color: .blue, symbol: "hand.thumbsup.fill") }
                Pill(text: ModelHub.tierTitle(v.tier), color: tierColor(v.tier))
                if v.enoughSpace {
                    Button(L("common.download")) {
                        macChoose(env.window, title: L("models.download.title", ModelHub.shortName(repo)), message: L("hub.download.message", v.label, ActivityCenter.bytes(v.bytes)), options: [L("common.download")]) { _ in
                            do { try ModelHub.install(v, of: d) } catch { macAlert(env.window, L("models.download.failed"), error.localizedDescription) }
                        }
                    }
                    .disabled(ModelHub.isBusy)
                } else {
                    Pill(text: L("hub.variant.noSpace", ActivityCenter.bytes(v.bytes)), color: .red)
                }
            }
        }
    }

    private func skipped(_ d: Core.HubDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("hub.detail.skipped"))
            Card(spacing: 8) {
                ForEach(d.skipped, id: \.name) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.name).font(.caption.weight(.medium)).textSelection(.enabled)
                        Text(s.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
