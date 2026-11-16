import AppKit
import SwiftUI

// MARK: - State

private struct ExternalDraft: Identifiable {
    var model: ExternalModel
    var isNew: Bool
    var id: String { model.id }
}

/// A model's prompt, in its card. Saved, it applies from now on or to everything right away.
private struct ModelPromptEditor: View {
    let model: String
    let retag: () -> Void
    @EnvironmentObject private var env: PaneEnv
    @State private var field = PromptField.system
    @State private var saved: AIEngine.Prompt?
    @State private var texts: [PromptField: String] = [:]

    private func fill(_ p: AIEngine.Prompt) {
        texts = [.system: p.system, .question: p.prompt, .existing: p.existing, .vocabulary: p.vocabulary, .context: p.context]
    }
    private var edited: AIEngine.Prompt {
        AIEngine.Prompt(system: texts[.system], prompt: texts[.question], context: texts[.context], existing: texts[.existing], vocabulary: texts[.vocabulary])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("models.promptSection")).font(.system(size: 13, weight: .semibold))
            // five names do not fit a narrow pane side by side
            ViewThatFits(in: .horizontal) {
                fieldPicker.pickerStyle(.segmented)
                fieldPicker.pickerStyle(.menu).fixedSize()
            }
            PlaceholderEditor(text: Binding(get: { texts[field] ?? "" }, set: { texts[field] = $0 }), placeholder: field.title, minHeight: 130)
                .id(field)
            Text(field.note).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button(L("mac.prompt.reset")) { fill(AIEngine.Prompt.defaults) }
                Button(L("mac.prompt.save")) { save() }.buttonStyle(.borderedProminent).accessibilityIdentifier("promptSave-" + model)
            }
        }
        .onAppear {
            let p = ModelPrompts.prompt(forModel: model)
            saved = p
            fill(p)
        }
    }

    private var fieldPicker: some View {
        Picker("", selection: $field) {
            ForEach(PromptField.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
    }

    private func save() {
        let p = edited
        guard p != saved else { return }
        saved = p
        ModelPrompts.save(p, forModel: model)
        macChoose(env.window, title: L("prompt.saved"), message: L("prompt.saved.retag"), options: [L("prompt.saved.later"), L("prompt.saved.now")]) { i in
            if i == 1 { retag() }
        }
    }
}

private enum PromptField: CaseIterable {
    case system, question, existing, vocabulary, context
    var title: String {
        switch self {
        case .system: L("prompt.system")
        case .question: L("prompt.question")
        case .existing: L("prompt.existing")
        case .vocabulary: L("prompt.libraryTags")
        case .context: L("prompt.postText")
        }
    }
    var note: String {
        switch self {
        case .system: L("mac.prompt.system.detail")
        case .question: L("mac.prompt.question.detail")
        case .existing: L("mac.prompt.existing.detail")
        case .vocabulary: L("mac.prompt.tags.detail")
        case .context: L("mac.prompt.text.detail")
        }
    }
}

@MainActor
final class ModelsModel: ObservableObject {
    /// The model cards that are open.
    @Published var expanded: Set<String> = debugOpenAll ? Set(ModelStore.shared.installed.map(\.id) + ExternalModels.all.map(\.id)) : []
    /// The debug tour's picture of an open card.
    nonisolated(unsafe) static var debugOpenAll = false
    @Published fileprivate var externalTests: [String: String] = [:]
    @Published fileprivate var draft: ExternalDraft?
    @Published var remote: [SyncService.RemoteModel] = []
    @Published var remoteError: String?
    private var remotePeers = ""
    @Published var remoteState = "idle"     // idle | loading | done
    private var wasDownloading = false

    /// A model download that ended: a failure is said (the list is re-read elsewhere).
    func tick(_ window: NSWindow?) {
        let d = Core.modelStatus()
        if wasDownloading, d?.running == false, d?.finished != true, let e = d?.error, e != L("models.cancelled") { macAlert(window, L("models.downloadFailed"), e) }
        wasDownloading = d?.running ?? false
        let peers = SyncService.shared.reachablePeers.map { $0.device + ($0.host ?? "") + String($0.port ?? 0) }.joined(separator: "|")
        if peers != remotePeers {
            remotePeers = peers
            if !peers.isEmpty, remoteState != "loading" { loadRemote() }
        }
    }

    func loadRemote() {
        guard remoteState != "loading" else { return }
        remoteError = nil
        remoteState = "loading"
        SyncService.shared.remoteModels { [weak self] result in
            switch result {
            case .success(let list): self?.remote = list; self?.remoteState = "done"
            case .failure(let error): self?.remote = []; self?.remoteError = error.localizedDescription; self?.remoteState = "error"
            }
        }
    }

    // MARK: Tagging and models

    func retagAll(_ window: NSWindow?) {
        let store = ModelStore.shared
        let ids = store.taggerIds
        guard !ids.isEmpty else { return }
        macChoose(window, title: L("models.retagAll"), message: L("models.retagAll.message"), options: ids.map { store.displayName($0) }) { i in
            let model = ids[i]
            macChoose(window, title: L("models.retag.oldTitle"), message: L("models.retag.oldMessage"),
                      options: [L("models.retag.keep"), L("models.retag.replace")]) { j in
                AutoTagger.shared.retagAll(model: model, replaceOld: j == 1)
            }
        }
    }

    func delete(_ m: Core.ModelInfo, _ window: NSWindow?) {
        macChoose(window, title: L("models.delete.title", ModelStore.shared.displayName(m.id)), message: L("models.delete.message"), options: [L("common.delete")]) { _ in
            // stop using it, release it, then delete the files (gigabytes) off the main thread
            AutoTagger.shared.stop()
            Task {
                await AIEngine.shared.unloadAll()
                await MainActor.run {
                    macRun(window, { try Core.deleteModel(m.id) }) { _ in ModelStore.shared.reload(); AutoTagger.shared.startIfEnabled() }
                }
            }
        }
    }

    func export(_ m: Core.ModelInfo, _ window: NSWindow?) {
        macSavePanel(m.id + ".zip") { url in
            macRun(window, { try Core.exportModelZip(m.id, to: url) }) { macAlert(window, L("mac.models.exported"), url.lastPathComponent) }
        }
    }

    func importModel(_ window: NSWindow?) {
        macOpenPanel([.zip, .folder], directories: true) { u in
            macRun(window, { try Core.importModel(u) }) { m in ModelStore.shared.reload(); macAlert(window, L("models.imported"), ModelStore.shared.displayName(m.id)) }
        }
    }

    // MARK: External models

    func test(_ e: ExternalModel) {
        externalTests[e.id] = L("mac.models.testing", e.title)
        Task { @MainActor [weak self] in
            let r: String
            do { let t = try await ExternalAI.test(e); r = L("mac.models.testOK") + (t.isEmpty ? L("models.external.noTags") : t.joined(separator: L("list.separator"))) }
            catch { r = L("mac.models.testFailed") + error.localizedDescription }
            self?.externalTests[e.id] = r
        }
    }

    func edit(_ e: ExternalModel) { draft = ExternalDraft(model: e, isNew: ExternalModels.find(e.id) == nil) }

    func deleteExternal(_ e: ExternalModel, _ window: NSWindow?) {
        macChoose(window, title: L("mac.models.external.delete.title", e.title), message: L("mac.models.external.delete.message"), options: [L("common.delete")]) { [weak self] _ in
            ExternalModels.remove(e.id); ModelStore.shared.adoptInstalled(); self?.objectWillChange.send()
        }
    }
}

// MARK: - Page

struct ModelsPageView: View {
    @EnvironmentObject private var env: PaneEnv
    @StateObject private var live = LiveTick()
    @StateObject private var m = ModelsModel()

    var body: some View {
        let _ = live.count
        let store = ModelStore.shared
        SettingsCanvas {
            runningCard
            hero(store)
            installed(store)
            external(store)
            hubEntry
            remote(store)

            Card(spacing: 0) {
                CardRow(symbol: "square.and.arrow.down.fill", color: .green, title: L("mac.models.import"), detail: L("models.appleOnly")) {
                    Button(L("mac.importEllipsis")) { m.importModel(env.window) }
                }
            }
        }
        .onAppear {
            live.onTick = { [weak m] in m?.tick(env.window) }
            live.start(every: 1)
            if m.remoteState == "idle", !SyncService.shared.reachablePeers.isEmpty { m.loadRemote() }
        }
        .onDisappear { live.stop() }
        .sheet(item: $m.draft) { d in ExternalEditor(draft: d) { m.draft = nil } }
    }

    // MARK: Blocks

    /// What is running (tagging, a model download), with the buttons that stop it.
    @ViewBuilder private var runningCard: some View {
        let acts = ActivityCenter.shared.activities.filter { $0.kind == .tagging || $0.kind == .model }
        if !acts.isEmpty {
            Card(tint: .accentColor, spacing: 14) {
                ForEach(acts) { ActivityRow(activity: $0) }
                HStack(spacing: 8) {
                    Spacer()
                    if acts.contains(where: { $0.kind == .tagging }) { Button(L("models.stopTagging")) { AutoTagger.shared.stop() } }
                    if acts.contains(where: { $0.kind == .model }) { Button(L("models.cancelDownload")) { Core.cancelModelDownload() } }
                }
            }
        }
    }

    /// The tagging at a glance: a ring of how much is analysed, the switch, the default models.
    private func hero(_ store: ModelStore) -> some View {
        let c = AutoTagger.shared.counts
        let failures = Core.aiFailures()
        let value = c.total > 0 ? Double(c.done) / Double(c.total) : 0
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 22) {
                ZStack {
                    ProgressRing(value: value, lineWidth: 11, color: .purple)
                    VStack(spacing: 0) {
                        Text("\(Int((value * 100).rounded()))%").font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(L("models.analysed")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("mac.models.tagging")).font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(L("mac.models.analysedCount", c.done, c.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Toggle(isOn: Binding(get: { store.autoTag }, set: { store.autoTag = $0; if $0 { AutoTagger.shared.startIfEnabled() } })) {
                        Text(L("models.autoTag")).font(.system(size: 13.5, weight: .medium))
                    }
                    .toggleStyle(.switch)
                }
            }

            HStack(spacing: 12) {
                defaultPicker(L("mac.models.tagger"), symbol: "eye.fill", color: .purple, ids: store.taggerIds, selected: store.activeTaggerId, name: { store.displayName($0) }) { store.activeTaggerId = $0 }
                defaultPicker(L("mac.models.embedder"), symbol: "magnifyingglass", color: .teal, ids: store.embedders.map(\.id), selected: store.activeEmbedderId, name: { store.displayName($0) }) {
                    store.activeEmbedderId = $0; Task { await AutoTagger.shared.embedMissingLabels() }
                }
            }

            if let e = AutoTagger.shared.lastError { Banner(text: e, symbol: "exclamationmark.octagon.fill", color: .red) }
            if !failures.isEmpty {
                // shown, never dropped silently: which media, why, and a way to try again
                let reasons = Dictionary(grouping: failures, by: \.reason).sorted { $0.value.count > $1.value.count }
                HStack(alignment: .top, spacing: 10) {
                    Banner(text: L("mac.models.failures", failures.count) + reasons.prefix(2).map { L("mac.models.failures.group", $0.value.count, $0.key) }.joined(separator: L("list.semicolon")) + L("mac.models.failures.tail"))
                    VStack(spacing: 6) {
                        Button(L("mac.detailsEllipsis")) {
                            let lines = failures.prefix(30).map { L("models.failure.line", $0.mediaId.prefix(12), $0.attempts, $0.reason) }
                            macAlert(env.window, L("models.failures.title"), (lines + (failures.count > 30 ? [L("models.failures.more", failures.count - 30)] : [])).joined(separator: "\n")
                                     + L("models.failures.footer"))
                        }
                        Button(L("models.retry")) { Core.aiFailuresClear(); AutoTagger.shared.startIfEnabled(); NotificationCenter.default.post(name: AutoTagger.progressChanged, object: nil) }
                    }
                }
            }
            if !store.taggerIds.isEmpty {
                HStack { Spacer(); Button { m.retagAll(env.window) } label: { Label(L("models.retagAllEllipsis"), systemImage: "arrow.triangle.2.circlepath") } }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            shape.fill(LinearGradient(colors: [Color.purple.opacity(0.18), Color.indigo.opacity(0.08), Color.blue.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: Color.purple.opacity(0.12), radius: 16, y: 6)
        }
    }

    private func defaultPicker(_ title: String, symbol: String, color: Color, ids: [String], selected: String?, name: @escaping (String) -> String, set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, color: color, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                if ids.isEmpty { Text(L("common.notInstalled")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary) }
                else {
                    Picker("", selection: Binding(get: { selected ?? "" }, set: { if !$0.isEmpty { set($0) } })) {
                        if selected == nil { Text(L("mac.notChosen")).tag("") }
                        ForEach(ids, id: \.self) { Text(name($0)).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A model the whole width of the page: what it is, whether it is the default and its menu in
    /// one row. Its prompt opens below, where a prompt has the room it needs.
    private func modelCard<Pills: View, Menu: View>(id: String, symbol: String, color: Color, title: String, isDefault: Bool, setDefault: @escaping () -> Void, canOpen: Bool = true,
                                                    @ViewBuilder pills: () -> Pills, @ViewBuilder menu: () -> Menu, @ViewBuilder details: () -> some View = { EmptyView() }, @ViewBuilder prompt: () -> some View) -> some View {
        Card(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 5) { pills() }
                }
                Spacer(minLength: 8)
                if isDefault { Pill(text: L("prompt.default"), color: .yellow, symbol: "star.fill") }
                else { Button(L("mac.models.setDefault"), action: setDefault) }
                menu()
                if canOpen {
                    Button {
                        withAnimation(.snappy) { if !m.expanded.insert(id).inserted { m.expanded.remove(id) } }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(m.expanded.contains(id) ? 180 : 0))
                            .frame(width: 24, height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(L("models.expand"))
                    .accessibilityIdentifier("card-" + id)
                }
            }
            details()
            if canOpen, m.expanded.contains(id) {
                Divider()
                prompt()
            }
        }
    }

    private func moreMenu(@ViewBuilder _ items: () -> some View) -> some View {
        Menu { items() } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)) }
            .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Models

    @ViewBuilder private func installed(_ store: ModelStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("models.installed", store.installed.count), note: L("mac.models.installed.detail"))
            if store.installed.isEmpty {
                Card { Text(L("mac.models.none")).foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 12) {
                    ForEach(store.installed, id: \.id) { mi in
                        modelCard(id: mi.id, symbol: mi.vision ? "eye.fill" : "magnifyingglass", color: mi.vision ? .purple : .teal, title: store.displayName(mi.id),
                                  isDefault: mi.vision ? store.activeTaggerId == mi.id : store.activeEmbedderId == mi.id,
                                  setDefault: {
                                      if mi.vision { store.activeTaggerId = mi.id } else { store.activeEmbedderId = mi.id; Task { await AutoTagger.shared.embedMissingLabels() } }
                                  },
                                  canOpen: mi.vision,
                                  pills: {
                                      Pill(text: mi.vision ? L("mac.models.role.tagger") : L("models.semanticSearch"), color: mi.vision ? .purple : .teal)
                                      Pill(text: ActivityCenter.bytes(mi.bytes), color: .secondary)
                                  },
                                  menu: {
                                      moreMenu {
                                          Button(L("mac.models.exportZip")) { m.export(mi, env.window) }
                                          Button(L("mac.showInFinder")) { NSWorkspace.shared.activateFileViewerSelecting([mi.url]) }
                                          Divider()
                                          Button(L("mac.deleteEllipsis"), role: .destructive) { m.delete(mi, env.window) }
                                      }
                                  },
                                  prompt: { ModelPromptEditor(model: mi.id) { m.retagAll(env.window) } })
                    }
                }
            }
        }
    }

    @ViewBuilder private func external(_ store: ModelStore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("models.external"))
            VStack(spacing: 12) {
                ForEach(ExternalModels.all, id: \.id) { e in
                    modelCard(id: e.id, symbol: e.isLocal ? "desktopcomputer" : "cloud.fill", color: .blue, title: e.title, isDefault: e.id == store.activeTaggerId,
                              setDefault: { store.activeTaggerId = e.id },
                              pills: {
                                  Pill(text: e.kindLabel, color: .blue)
                                  if !e.host.isEmpty { Pill(text: e.host, color: .secondary) }
                                  if !e.model.isEmpty { Text(e.model).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                              },
                              menu: {
                                  moreMenu {
                                      Button(L("mac.models.test")) { m.test(e) }
                                      Button(L("mac.editEllipsis")) { m.edit(e) }
                                      Divider()
                                      Button(L("mac.deleteEllipsis"), role: .destructive) { m.deleteExternal(e, env.window) }
                                  }
                              },
                              details: {
                                  if let r = m.externalTests[e.id] { Text(r).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                              },
                              prompt: { ModelPromptEditor(model: e.id) { m.retagAll(env.window) } })
                }
                Button { m.edit(.new()) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(.tint)
                        Text(ExternalModels.all.isEmpty ? L("models.addExternal") : L("mac.models.addAnother")).font(.system(size: 13.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.secondary.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var hubEntry: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(L("models.available"))
            Card(spacing: 0) {
                CardRow(symbol: "square.grid.2x2.fill", color: .blue, title: L("hub.title"), detail: L("hub.entry.detail")) {
                    Button(L("hub.open")) { env.open(L("hub.title"), MacSettingsPages.modelHub()) }
                        .accessibilityIdentifier("openModelHub")
                }
            }
        }
    }

    @ViewBuilder private func remote(_ store: ModelStore) -> some View {
        if SyncService.shared.hasAccount {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(L("models.peers.title"), note: L("models.appleOnly"),
                               trailing: AnyView(Button(L("mac.models.query")) { m.loadRemote() }.disabled(m.remoteState == "loading")))
                Card(spacing: 10) {
                    if m.remoteState == "loading" { Text(L("models.peers.querying")).foregroundStyle(.secondary) }
                    else if m.remote.isEmpty {
                        Text(m.remoteError ?? (SyncService.shared.reachablePeers.isEmpty ? (SyncService.shared.discoveredAccountPeers.isEmpty ? L("models.peers.none") : L("models.peers.connecting")) : (m.remoteState == "done" ? L("models.peers.nothing") : L("mac.models.peers.tap")))).foregroundStyle(.secondary)
                    }
                    ForEach(m.remote, id: \.info.id) { r in
                        CardRow(symbol: "laptopcomputer.and.iphone", color: .indigo, title: store.displayName(r.info.id), detail: "\(r.peer.name) · \(ActivityCenter.bytes(r.info.bytes))") {
                            Button(L("models.pull")) {
                                do { try SyncService.shared.pull(r); m.remote.removeAll { $0 == r } }
                                catch { macAlert(env.window, L("models.pull.failed"), error.localizedDescription) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - External model editor

/// Add or edit an external model: name, address, key, model name.
private struct ExternalEditor: View {
    let draft: ExternalDraft
    let close: () -> Void
    @State private var name: String
    @State private var url: String
    @State private var key: String
    @State private var model: String
    @State private var error: String?

    init(draft: ExternalDraft, close: @escaping () -> Void) {
        self.draft = draft
        self.close = close
        _name = State(initialValue: draft.model.name)
        _url = State(initialValue: draft.model.url)
        _key = State(initialValue: draft.model.apiKey ?? "")
        _model = State(initialValue: draft.model.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconTile(symbol: "network", color: .blue, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.isNew ? L("models.addExternal") : L("mac.models.edit", draft.model.title)).font(.system(size: 17, weight: .semibold))
                    Text(L("mac.models.external.hint")).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 10) {
                TextField(L("models.external.name"), text: $name).accessibilityIdentifier("extName")
                TextField(L("mac.models.external.urlPlaceholder"), text: $url).accessibilityIdentifier("extURL")
                SecureField(L("models.external.key"), text: $key).accessibilityIdentifier("extKey")
                TextField(L("models.external.model"), text: $model).accessibilityIdentifier("extModel")
            }
            .textFieldStyle(.roundedBorder)
            if let error { Banner(text: error, symbol: "exclamationmark.triangle.fill", color: .red) }
            HStack {
                Spacer()
                Button(L("common.cancel"), role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                Button(L("common.save")) { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func save() {
        var m = draft.model
        m.name = name.trimmingCharacters(in: .whitespaces)
        m.url = url.trimmingCharacters(in: .whitespaces)
        m.model = model.trimmingCharacters(in: .whitespaces)
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !m.url.isEmpty, ExternalAI.endpoint(m.url, "models") != nil else { error = L("models.external.needURL"); return }
        if !k.isEmpty, m.model.isEmpty { error = L("models.external.needModel"); return }
        m.apiKey = k.isEmpty ? nil : k
        ExternalModels.save(m)
        if ModelStore.shared.activeTaggerId == nil { ModelStore.shared.activeTaggerId = m.id }
        close()
    }
}
