import UIKit
import UniformTypeIdentifiers

/// Installed models (several can coexist), defaults, re-tag all, the model store, and
/// import/export in the standard Hugging Face / MLX folder format.
final class ModelsViewController: FormViewController, UIDocumentPickerDelegate {
    private var observers: [NSObjectProtocol] = []
    private var cards: [Activity.Kind: ActivityCardView] = [:]
    /// The model cards that are open, and the prompt editors they have shown.
    private var expanded: Set<String> = []
    private var editors: [String: ModelPromptEditor] = [:]
    private var lastDownloadRunning = false
    private var remote: [SyncService.RemoteModel] = []
    private var remoteLoading = false
    private var remoteChecked = false
    private var remoteError: String?
    private var remotePeers = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.aiModels")
        navigationItem.largeTitleDisplayMode = .never
        let nc = NotificationCenter.default
        observers = [ActivityCenter.changed, ModelStore.changed, AutoTagger.progressChanged, AIEngine.Prompt.changed, ExternalModels.changed, SyncService.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.tick() }
        }
        build()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    private func tick() {
        let running = Core.modelStatus()?.running ?? false
        if lastDownloadRunning, !running {
            if let s = Core.modelStatus() {
                if s.finished { ModelStore.shared.reload() } else if let e = s.error, e != L("models.cancelled") { alert(L("models.downloadFailed"), e) }
            }
        }
        lastDownloadRunning = running
        let peers = SyncService.shared.reachablePeers.map { $0.device + ($0.host ?? "") + String($0.port ?? 0) }.joined(separator: "|")
        if peers != remotePeers {
            remotePeers = peers
            if !peers.isEmpty, !remoteLoading { loadRemote(); return }
        }
        build()
    }

    private func card(_ a: Activity) -> ActivityCardView {
        let c = cards[a.kind] ?? ActivityCardView()
        cards[a.kind] = c
        c.update(a)
        return c
    }

    private func build() {
        let store = ModelStore.shared
        let counts = AutoTagger.shared.counts
        var s: [Section] = []
        if !AIEngine.isSupported {
            s.append(Section(id: "sim", footer: L("models.simulator.footer"), rows: [
                .value(L("models.simulator"), L("models.manageOnly"), icon: .init("exclamationmark.triangle.fill", .systemOrange))]))
        }
        let acts = ActivityCenter.shared.activities.filter { $0.kind == .tagging || $0.kind == .model }
        if !acts.isEmpty {
            var rows: [Row] = acts.map { .custom("act-\($0.kind.rawValue)", card($0)) }
            if acts.contains(where: { $0.kind == .tagging }) { rows.append(.button(L("models.stopTagging"), icon: .init("stop.fill", .systemRed), destructive: true) { AutoTagger.shared.stop() }) }
            if acts.contains(where: { $0.kind == .model }) { rows.append(.button(L("models.cancelDownload"), icon: .init("xmark", .systemRed), destructive: true) { Core.cancelModelDownload() }) }
            s.append(Section(id: "act", header: L("models.inProgress"), rows: rows))
        }
        var auto: [Row] = [
            .toggle(L("models.autoTag"), store.autoTag, icon: .init("wand.and.stars", .systemPurple)) { on in
                store.autoTag = on
                if on { AutoTagger.shared.startIfEnabled() }
            },
            .value(L("models.analysed"), "\(counts.done) / \(counts.total)", icon: .init("photo.stack.fill", .systemBlue)),
        ]
        if let e = AutoTagger.shared.lastError { auto.append(.value(L("models.error"), e, icon: .init("exclamationmark.octagon.fill", .systemRed))) }
        let failures = Core.aiFailures()
        if !failures.isEmpty {
            // shown, never dropped silently: which media, why, and a way to try again
            auto.append(.navigation(L("models.failures"), detail: L("common.count", failures.count), icon: .init("exclamationmark.triangle.fill", .systemOrange), id: "n:aifail") { [weak self] in
                let lines = failures.prefix(30).map { L("models.failure.line", $0.mediaId.prefix(12), $0.attempts, $0.reason) }
                let a = UIAlertController(title: L("models.failures.title"), message: (lines + (failures.count > 30 ? [L("models.failures.more", failures.count - 30)] : [])).joined(separator: "\n")
                    + L("models.failures.footer"), preferredStyle: .alert)
                a.addAction(UIAlertAction(title: L("models.retry"), style: .default) { _ in Core.aiFailuresClear(); AutoTagger.shared.startIfEnabled(); self?.build() })
                a.addAction(UIAlertAction(title: L("common.ok"), style: .cancel))
                self?.present(a, animated: true)
            })
        }
        if !store.taggerIds.isEmpty {
            auto.append(.button(L("models.retagAllEllipsis"), icon: .init("arrow.clockwise.circle.fill", .systemIndigo)) { [weak self] in self?.retagAll() })
        }
        s.append(Section(id: "auto", header: L("models.tagging"), rows: auto))

        s.append(Section(id: "defaults", header: L("models.defaultModel"), rows: [
            .navigation(L("models.tagging"), detail: store.activeTaggerId.map { store.displayName($0) } ?? L("common.notInstalled"), icon: .init("eye.fill", .systemPink)) { [weak self] in self?.choose(.tagger) },
            .navigation(L("models.semanticSearch"), detail: store.activeEmbedder.map { store.displayName($0.id) } ?? L("common.notInstalled"), icon: .init("text.magnifyingglass", .systemTeal)) { [weak self] in self?.choose(.embedder) },
        ]))

        let installed: [Row] = store.installed.flatMap { m -> [Row] in
            let isDefault = m.id == store.activeTaggerId || m.id == store.activeEmbedderId
            let card = "m:\(m.id)"
            var rows: [Row] = [.expander(store.displayName(m.id), detail: (isDefault ? L("models.defaultPrefix") : "") + ActivityCenter.bytes(m.bytes), expanded: expanded.contains(card),
                                         icon: .init(m.vision ? "eye" : "text.magnifyingglass", m.vision ? .systemPink : .systemTeal), id: card) { [weak self] in self?.toggleCard(card) }]
            guard expanded.contains(card) else { return rows }
            if m.vision { rows.append(.custom("prompt-\(m.id)", promptEditor(m.id))) }
            if m.vision, store.activeTaggerId != m.id {
                rows.append(.button(L("models.setDefaultTagger"), icon: .init("star", .systemYellow), id: "d:\(m.id)") { store.activeTaggerId = m.id })
            }
            if !m.vision, store.activeEmbedderId != m.id {
                rows.append(.button(L("models.setDefaultEmbedder"), icon: .init("star", .systemYellow), id: "e:\(m.id)") { store.activeEmbedderId = m.id })
            }
            rows.append(.button(L("models.exportZip"), icon: .init("square.and.arrow.up", .systemBlue), id: "z:\(m.id)") { [weak self] in self?.export(m) })
            rows.append(.button(L("common.delete"), icon: .init("trash", .systemRed), destructive: true, id: "x:\(m.id)") { [weak self] in self?.confirmDelete(m) })
            return rows
        }
        s.append(Section(id: "installed", header: L("models.installed", store.installed.count),
                         rows: installed.isEmpty ? [.value(L("models.noneInstalled"), nil, icon: .init("tray", .systemGray))] : installed))

        // external models: used exactly like the built-in ones
        var ext: [Row] = ExternalModels.all.flatMap { e -> [Row] in
            let card = "x:\(e.id)"
            var rows: [Row] = [.expander(e.title, detail: (e.id == store.activeTaggerId ? L("models.defaultPrefix") : "") + e.kindLabel, expanded: expanded.contains(card),
                                         icon: .init(e.isLocal ? "server.rack" : "cloud.fill", e.isLocal ? .systemGreen : .systemBlue), id: card) { [weak self] in self?.toggleCard(card) }]
            guard expanded.contains(card) else { return rows }
            rows.append(.custom("prompt-\(e.id)", promptEditor(e.id)))
            if store.activeTaggerId != e.id {
                rows.append(.button(L("models.setDefaultTagger"), icon: .init("star", .systemYellow), id: "d:\(e.id)") { store.activeTaggerId = e.id })
            }
            rows.append(.navigation(L("models.external.connection"), detail: e.host, icon: .init("network", .systemBlue), id: "c:\(e.id)") { [weak self] in
                self?.navigationController?.pushViewController(ExternalModelViewController(model: e), animated: true)
            })
            return rows
        }
        ext.append(.button(L("models.addExternalEllipsis"), icon: .init("plus.circle.fill", .systemBlue), id: "b:addExternal") { [weak self] in
            self?.navigationController?.pushViewController(ExternalModelViewController(model: .new()), animated: true)
        })
        s.append(Section(id: "external", header: L("models.external"), rows: ext))

        s.append(Section(id: "store", header: L("models.available"), rows: [
            .navigation(L("hub.title"), detail: L("hub.entry.detail"), icon: .init("square.grid.2x2.fill", .systemBlue), id: "n:hub") { [weak self] in
                self?.navigationController?.pushViewController(ModelHubViewController(), animated: true)
            },
        ]))
        if SyncService.shared.hasAccount {
            var rows: [Row] = remote.map { r in
                .navigation(store.displayName(r.info.id), detail: "\(r.peer.name) · \(ActivityCenter.bytes(r.info.bytes))",
                            icon: .init("arrow.down.to.line.circle.fill", .systemIndigo), id: "r:\(r.peer.device):\(r.info.id)") { [weak self] in self?.confirmPull(r) }
            }
            if remoteLoading { rows.insert(.value(L("models.peers.querying"), nil, icon: .init("hourglass", .systemGray), id: "r:loading"), at: 0) }
            else if remote.isEmpty { rows.append(.value(remoteError ?? (SyncService.shared.reachablePeers.isEmpty ? (SyncService.shared.discoveredAccountPeers.isEmpty ? L("models.peers.none") : L("models.peers.connecting")) : (remoteChecked ? L("models.peers.nothing") : L("models.peers.tap"))), nil, icon: .init("laptopcomputer.and.iphone", .systemGray), id: "r:none")) }
            rows.append(.button(L("models.peers.query"), icon: .init("arrow.clockwise", .systemBlue), enabled: !remoteLoading, id: "r:refresh") { [weak self] in self?.loadRemote() })
            s.append(Section(id: "remote", header: L("models.peers.title"), footer: L("models.appleOnly"), rows: rows))
        }
        s.append(Section(id: "io", header: L("common.import"), footer: L("models.appleOnly"), rows: [
            .button(L("models.import.button"), icon: .init("square.and.arrow.down.fill", .systemGreen)) { [weak self] in self?.pickModel() },
        ]))
        sections = s
        reloadForm()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !remoteChecked, !SyncService.shared.reachablePeers.isEmpty { loadRemote() }
    }

    private func loadRemote() {
        guard !remoteLoading else { return }
        remoteLoading = true
        remoteError = nil
        build()
        SyncService.shared.remoteModels { [weak self] result in
            guard let self else { return }
            self.remoteLoading = false
            self.remoteChecked = true
            switch result {
            case .success(let list): self.remote = list
            case .failure(let error): self.remote = []; self.remoteError = error.localizedDescription
            }
            self.build()
        }
    }

    private func confirmPull(_ r: SyncService.RemoteModel) {
        if Core.modelStatus()?.running == true { return alert(L("models.busy")) }
        let a = UIAlertController(title: L("models.pull.title", r.peer.name), message: L("models.pull.message", ModelStore.shared.displayName(r.info.id), ActivityCenter.bytes(r.info.bytes)), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("models.pull"), style: .default) { [weak self] _ in
            do { try SyncService.shared.pull(r); self?.remote.removeAll { $0 == r }; self?.build() } catch { self?.alert(L("models.pull.failed"), error.localizedDescription) }
        })
        present(a, animated: true)
    }

    private enum Role { case tagger, embedder }

    private func choose(_ role: Role) {
        let store = ModelStore.shared
        let list = role == .tagger ? store.taggerIds : store.embedders.map(\.id)
        guard !list.isEmpty else { return alert(L("models.none.title"), L("models.none.message")) }
        let sheet = UIAlertController(title: role == .tagger ? L("models.defaultTagger") : L("models.defaultEmbedder"), message: L("models.change.footer"), preferredStyle: .actionSheet)
        for id in list {
            let current = (role == .tagger ? store.activeTaggerId : store.activeEmbedderId) == id
            sheet.addAction(UIAlertAction(title: (current ? "✓ " : "") + store.displayName(id), style: .default) { _ in
                if role == .tagger { store.activeTaggerId = id } else { store.activeEmbedderId = id; Task { await AutoTagger.shared.embedMissingLabels() } }
            })
        }
        sheet.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        anchor(sheet)
        present(sheet, animated: true)
    }

    private func retagAll() {
        let store = ModelStore.shared
        let pickModel = UIAlertController(title: L("models.retagAll"), message: L("models.retagAll.message"), preferredStyle: .actionSheet)
        for id in store.taggerIds {
            pickModel.addAction(UIAlertAction(title: store.displayName(id), style: .default) { [weak self] _ in self?.retagAll(model: id) })
        }
        pickModel.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        anchor(pickModel)
        present(pickModel, animated: true)
    }

    private func retagAll(model: String) {
        let a = UIAlertController(title: L("models.retag.oldTitle"), message: L("models.retag.oldMessage"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("models.retag.keep"), style: .default) { _ in AutoTagger.shared.retagAll(model: model, replaceOld: false) })
        a.addAction(UIAlertAction(title: L("models.retag.replace"), style: .destructive) { _ in AutoTagger.shared.retagAll(model: model, replaceOld: true) })
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        present(a, animated: true)
    }

    private func toggleCard(_ id: String) {
        if !expanded.insert(id).inserted { expanded.remove(id) }
        build()
    }

    /// A model's prompt, kept across updates so what is being typed survives them.
    private func promptEditor(_ model: String) -> ModelPromptEditor {
        if let e = editors[model] { return e }
        let e = ModelPromptEditor(model: model) { [weak self] in self?.promptSaved(model) }
        editors[model] = e
        return e
    }

    private func promptSaved(_ model: String) {
        let a = UIAlertController(title: L("prompt.saved"), message: L("prompt.saved.retag"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("prompt.saved.later"), style: .cancel))
        a.addAction(UIAlertAction(title: L("prompt.saved.now"), style: .default) { [weak self] _ in self?.retagAll(model: model) })
        present(a, animated: true)
    }

    private func confirmDelete(_ m: Core.ModelInfo) {
        let store = ModelStore.shared
        let c = UIAlertController(title: L("models.delete.title", store.displayName(m.id)), message: L("models.delete.message"), preferredStyle: .alert)
        c.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        c.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { [weak self] _ in
            // stop using it, release it, then delete the files (gigabytes) off the main thread
            AutoTagger.shared.stop()
            Task {
                await AIEngine.shared.unloadAll()
                await MainActor.run {
                    self?.runBusy(L("models.deleting"), { try Core.deleteModel(m.id) }) { _ in
                        store.reload(); self?.build(); AutoTagger.shared.startIfEnabled()
                    }
                }
            }
        })
        present(c, animated: true)
    }

    private func anchor(_ sheet: UIAlertController) { anchorSheet(sheet) }

    private func export(_ m: Core.ModelInfo) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(m.id).appendingPathExtension("zip")
        runBusy(L("models.packing"), { try Core.exportModelZip(m.id, to: out) }) { [weak self] in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 80, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }

    private func pickModel() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .zip], asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        runBusy(L("models.importing"), {
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            return try Core.importModel(url)
        }) { [weak self] m in
            ModelStore.shared.reload()
            self?.build()
            self?.alert(L("models.imported"), ModelStore.shared.displayName(m.id))
        }
    }
}

/// Edits the AI tagging prompt (an app setting). Saving applies to all future tagging; the user
/// can also re-tag the whole library right away.
/// A model's prompt, in its card. Saved, it applies from now on or to everything right away.
final class ModelPromptEditor: UIStackView {
    private let model: String
    private let onSaved: () -> Void
    private var saved: AIEngine.Prompt
    private let system = PlaceholderTextView(placeholder: L("prompt.system"))
    private let prompt = PlaceholderTextView(placeholder: L("prompt.question.title"))
    private let existing = PlaceholderTextView(placeholder: L("prompt.existing.title"))
    private let vocabulary = PlaceholderTextView(placeholder: L("prompt.tags.title"))
    private let context = PlaceholderTextView(placeholder: L("prompt.text.title"))

    init(model: String, onSaved: @escaping () -> Void) {
        self.model = model
        self.onSaved = onSaved
        saved = ModelPrompts.prompt(forModel: model)
        super.init(frame: .zero)
        axis = .vertical
        spacing = 6
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = .init(top: 8, left: 0, bottom: 8, right: 0)
        let title = UILabel()
        title.text = L("models.promptSection")
        title.font = .preferredFont(forTextStyle: .headline)
        addArrangedSubview(title)
        for (view, name, help) in [(system, L("prompt.system"), L("prompt.system.footer")), (prompt, L("prompt.question"), L("prompt.question.footer")),
                                   (existing, L("prompt.existing"), L("prompt.existing.footer")), (vocabulary, L("prompt.libraryTags"), L("prompt.libraryTags.footer")),
                                   (context, L("prompt.postText"), L("prompt.postText.footer"))] {
            let label = UILabel()
            label.text = name
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            let note = UILabel()
            note.text = help
            note.numberOfLines = 0
            note.font = .preferredFont(forTextStyle: .caption1)
            note.textColor = .tertiaryLabel
            view.isScrollEnabled = false
            [label, view, note].forEach(addArrangedSubview)
            setCustomSpacing(12, after: note)
        }
        var reset = UIButton.Configuration.plain()
        reset.title = L("mac.prompt.reset")
        var save = UIButton.Configuration.borderedProminent()
        save.title = L("mac.prompt.save")
        let resetButton = UIButton(configuration: reset, primaryAction: UIAction { [weak self] _ in self?.fill(AIEngine.Prompt.defaults) })
        let saveButton = UIButton(configuration: save, primaryAction: UIAction { [weak self] _ in self?.save() })
        saveButton.accessibilityIdentifier = "promptSave"
        let row = UIStackView(arrangedSubviews: [resetButton, UIView(), saveButton])
        addArrangedSubview(row)
        fill(saved)
    }
    required init(coder: NSCoder) { fatalError() }

    private func fill(_ p: AIEngine.Prompt) { system.text = p.system; prompt.text = p.prompt; existing.text = p.existing; vocabulary.text = p.vocabulary; context.text = p.context }

    private func save() {
        endEditing(true)
        let p = AIEngine.Prompt(system: system.text, prompt: prompt.text, context: context.text, existing: existing.text, vocabulary: vocabulary.text)
        guard p != saved else { return }
        saved = p
        ModelPrompts.save(p, forModel: model)
        onSaved()
    }

    /// Another device's change comes in: it shows, unless something is being typed here.
    func refresh() {
        let now = ModelPrompts.prompt(forModel: model)
        guard now != saved else { return }
        let edited = AIEngine.Prompt(system: system.text, prompt: prompt.text, context: context.text, existing: existing.text, vocabulary: vocabulary.text)
        if edited == saved { fill(now) }
        saved = now
    }
}

/// One field of a form: what it is above, what is typed below, with room around them.
private final class LabeledFieldRow: UIStackView {
    init(title: String, field: UITextField) {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 4
        isLayoutMarginsRelativeArrangement = true
        layoutMargins = .init(top: 6, left: 0, bottom: 6, right: 0)
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        [label, field].forEach(addArrangedSubview)
    }
    required init(coder: NSCoder) { fatalError() }
}

/// Adds or edits an external model: where it is and what it is called; for a cloud service, its
/// key and model; default; a test request; delete.
final class ExternalModelViewController: FormViewController, UITextFieldDelegate {
    private var model: ExternalModel
    private let nameField = UITextField(), urlField = UITextField(), keyField = UITextField(), modelField = UITextField()
    private lazy var urlRow = LabeledFieldRow(title: L("models.external.field.url"), field: urlField)
    private lazy var nameRow = LabeledFieldRow(title: L("models.external.field.name"), field: nameField)
    private lazy var keyRow = LabeledFieldRow(title: L("models.external.field.key"), field: keyField)
    private lazy var modelRow = LabeledFieldRow(title: L("models.external.field.model"), field: modelField)
    private var testResult: String?
    private var testing = false

    init(model: ExternalModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    private var isNew: Bool { ExternalModels.find(model.id) == nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? L("models.addExternal") : model.title
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: L("common.save"), primaryAction: UIAction { [weak self] _ in self?.save() })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "externalSave"
        for (f, ph, id, text) in [(urlField, L("models.external.field.url.hint"), "extURL", model.url), (nameField, L("models.external.field.optional"), "extName", model.name),
                                  (keyField, L("models.external.field.key.hint"), "extKey", model.apiKey ?? ""), (modelField, L("models.external.field.model.hint"), "extModel", model.model)] {
            f.placeholder = ph; f.text = text; f.accessibilityIdentifier = id
            f.autocapitalizationType = .none; f.autocorrectionType = .no; f.clearButtonMode = .whileEditing
            f.delegate = self
            f.returnKeyType = f === modelField ? .done : .next
        }
        urlField.keyboardType = .URL
        keyField.isSecureTextEntry = true
        build()
    }

    /// Return goes through the fields in the order they are shown.
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        let order = [urlField, nameField, keyField, modelField]
        if let i = order.firstIndex(of: field), i + 1 < order.count { order[i + 1].becomeFirstResponder() } else { field.resignFirstResponder() }
        return false
    }

    private func read() -> ExternalModel {
        var m = model
        m.name = (nameField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.url = (urlField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.model = (modelField.text ?? "").trimmingCharacters(in: .whitespaces)
        return m
    }

    private func build() {
        let store = ModelStore.shared
        var s: [Section] = [
            Section(id: "conn", header: L("models.external.section.service"), footer: L("models.external.section.service.footer"),
                    rows: [.custom("url", urlRow), .custom("name", nameRow)]),
            Section(id: "cloud", header: L("models.external.section.cloud"), footer: L("models.external.section.cloud.footer"),
                    rows: [.custom("key", keyRow), .custom("model", modelRow)]),
        ]
        if !isNew {
            s.append(Section(id: "use", header: L("models.external.use"), rows: [
                store.activeTaggerId == model.id
                    ? .value(L("models.defaultTagger"), L("common.yes"), icon: .init("star.fill", .systemYellow), id: "v:default")
                    : .button(L("models.setDefaultTagger"), icon: .init("star", .systemYellow), id: "b:default") { [weak self] in guard let self else { return }; store.activeTaggerId = self.model.id; self.build() },
            ]))
        }
        var test: [Row] = [.button(testing ? L("models.external.testing") : L("models.external.test"), icon: .init("bolt.horizontal.fill", .systemGreen), enabled: !testing, id: "b:test") { [weak self] in self?.runTest() }]
        if let r = testResult { test.append(.value(r, nil, icon: .init(r.hasPrefix(L("models.external.success")) ? "checkmark.circle.fill" : "xmark.octagon.fill", r.hasPrefix(L("models.external.success")) ? .systemGreen : .systemRed), id: "v:test")) }
        s.append(Section(id: "test", footer: L("models.external.test.footer"), rows: test))
        if !isNew {
            s.append(Section(id: "del", rows: [.button(L("models.external.delete"), icon: .init("trash", .systemRed), destructive: true, id: "b:deleteExternal") { [weak self] in
                guard let self else { return }
                ExternalModels.remove(self.model.id)
                ModelStore.shared.adoptInstalled()
                self.navigationController?.popViewController(animated: true)
            }]))
        }
        sections = s
        reloadForm(animated: false)
    }

    private func save() {
        view.endEditing(true)
        let m = read()
        guard !m.url.isEmpty, ExternalAI.endpoint(m.url, "models") != nil else { return alert(L("models.external.needURL")) }
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespaces)
        if !key.isEmpty, m.model.isEmpty { return alert(L("models.external.needModel")) }
        m.apiKey = key.isEmpty ? nil : key
        ExternalModels.save(m)
        model = m
        if ModelStore.shared.activeTaggerId == nil { ModelStore.shared.activeTaggerId = m.id }
        navigationController?.popViewController(animated: true)
    }

    private func runTest() {
        view.endEditing(true)
        let m = read()
        let key = (keyField.text ?? "").trimmingCharacters(in: .whitespaces)
        m.apiKey = key.isEmpty ? nil : key   // the test uses what is typed (saved with 保存)
        testing = true; testResult = nil; build()
        Task { @MainActor in
            do {
                let tags = try await ExternalAI.test(m)
                testResult = L("models.external.successColon") + (tags.isEmpty ? L("models.external.noTags") : tags.joined(separator: L("list.separator")))
            } catch { testResult = L("models.external.failureColon") + error.localizedDescription }
            if isNew { m.apiKey = nil }
            testing = false
            build()
        }
    }
}
