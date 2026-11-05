import AppKit
import SwiftUI

/// The settings window: the same iOS-style panel (a grouped list that opens sub-pages, with a
/// back button), in a window of its own next to the main one. ⌘, or the toolbar button opens and
/// closes it; it remembers its size and place. Its pages refresh only while it is open.
final class MacSettingsWindowController: NSWindowController, NSWindowDelegate {
    let panel = MacSettingsPanel()
    static let width: CGFloat = 440

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 720),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: true)
        w.title = L("place.settings")
        // the page's own header sits in the title bar, beside the window buttons (the red one
        // closes the window, so the page has no close button of its own)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.titlebarSeparatorStyle = .none
        let bar = NSToolbar(identifier: "settings")
        bar.showsBaselineSeparator = false
        w.toolbar = bar
        w.toolbarStyle = .unified
        w.contentViewController = panel
        w.setContentSize(NSSize(width: Self.width, height: 720))
        w.minSize = NSSize(width: 380, height: 420)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("SettingsWindow")
        super.init(window: w)
        w.delegate = self
        panel.onClose = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Set when settings live in the main window's sidebar: opening and closing go there.
    var onEmbed: ((Bool) -> Void)?
    var embeddedOpen = false
    var isPanelOpen: Bool { onEmbed != nil ? embeddedOpen : window?.isVisible == true }
    func togglePanel() { setPanel(open: !isPanelOpen) }

    /// Opens (next to the main window the first time) or closes the settings window.
    func setPanel(open: Bool, animated: Bool = true) {
        if let onEmbed { onEmbed(open); return }
        guard let w = window else { return }
        if open {
            if !w.setFrameUsingName("SettingsWindow"), let main = NSApp.mainWindow ?? NSApp.windows.first(where: { $0 !== w && $0.isVisible }) {
                // first time: beside the main window, on the right when there is room
                let screen = main.screen?.visibleFrame ?? .zero
                var f = w.frame
                f.size.height = min(main.frame.height, screen.height)
                f.origin.y = main.frame.maxY - f.height
                f.origin.x = main.frame.maxX + 12 + f.width <= screen.maxX ? main.frame.maxX + 12 : max(screen.minX, screen.maxX - f.width)
                w.setFrame(f, display: false)
            }
            panel.willShow()
            showWindow(nil)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.performClose(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { panel.didHide() }

    /// The media viewer no longer shares a window with the settings: nothing to do.
    func viewerChanged(open: Bool) {}
}

/// The panel: a header (back, title, close) above the current page; pages push and pop.
final class MacSettingsPanel: NSViewController {
    var onClose: (() -> Void)?
    /// Shown inside the main window (the sidebar's 设置): the header starts at the left edge
    /// instead of leaving room for the window buttons.
    var embedded = false { didSet { if isViewLoaded { applyEmbedded() } } }
    private var head: NSView?, line: NSView?
    private var topUnderHeader: NSLayoutConstraint?, topAtEdge: NSLayoutConstraint?
    private func applyEmbedded() {
        head?.isHidden = embedded
        line?.isHidden = embedded
        topUnderHeader?.isActive = !embedded
        topAtEdge?.isActive = embedded
    }
    private let back = NSButton()
    private let titleLabel = NSTextField(labelWithString: L("place.settings"))
    private let content = NSView()
    private var stack: [(NSViewController, String)] = []
    private var root: SettingsHost?

    override func loadView() {
        // an ordinary opaque settings surface (a vibrant sidebar material dims text and controls to gray)
        let v = MacOpaqueView(color: .windowBackgroundColor)
        v.frame = NSRect(x: 0, y: 0, width: MacSettingsWindowController.width, height: 720)
        back.bezelStyle = .accessoryBarAction
        back.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("mac.toolbar.back"))
        back.imagePosition = .imageLeading
        back.target = self
        back.action = #selector(pop)
        back.setAccessibilityIdentifier("panelBack")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("mac.panel.close"))!, target: self, action: #selector(closeClicked))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        close.setAccessibilityIdentifier("panelClose")
        close.toolTip = L("mac.panel.closeTip")
        _ = close
        let head = NSStackView(views: [back, titleLabel, NSView()])
        head.spacing = 8
        head.edgeInsets = NSEdgeInsets(top: 0, left: embedded ? 12 : 84, bottom: 0, right: 16)   // clear of the window buttons
        let line = NSBox(); line.boxType = .separator
        [head, line, content].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; v.addSubview($0) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: v.topAnchor), head.heightAnchor.constraint(equalToConstant: 52),   // the unified title bar's height
            head.leadingAnchor.constraint(equalTo: v.leadingAnchor), head.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.topAnchor.constraint(equalTo: head.bottomAnchor), line.leadingAnchor.constraint(equalTo: v.leadingAnchor), line.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            // in the main window the page title and back button are the window's (toolbar), so
            // the panel's own header is not shown
            content.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: v.leadingAnchor), content.trailingAnchor.constraint(equalTo: v.trailingAnchor),
        ])
        self.head = head; self.line = line
        topUnderHeader = content.topAnchor.constraint(equalTo: line.bottomAnchor)
        topAtEdge = content.topAnchor.constraint(equalTo: v.topAnchor)
        applyEmbedded()
        view = v
        let r = MacSettingsPages.root()
        r.panel = self
        root = r
        show(r, title: L("place.settings"))
        stack = [(r, L("place.settings"))]
        updateHeader()
    }

    /// Opens a sub-page.
    func push(_ vc: NSViewController, title: String) {
        if let p = vc as? FormPane { p.panel = self }
        if let p = vc as? SettingsHost { p.panel = self }
        if let t = vc as? MacTagsPage { t.panel = self }
        stack.append((vc, title))
        show(vc, title: title)
        updateHeader()
    }

    @objc func pop() {
        guard stack.count > 1 else { return }
        let (old, _) = stack.removeLast()
        old.view.removeFromSuperview()
        old.removeFromParent()
        show(stack.last!.0, title: stack.last!.1)
        updateHeader()
    }

    func popToRoot() { while stack.count > 1 { pop() } }

    private func show(_ vc: NSViewController, title: String) {
        content.subviews.forEach { $0.removeFromSuperview() }
        if vc.parent == nil { addChild(vc) }
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vc.view)
        NSLayoutConstraint.activate([vc.view.topAnchor.constraint(equalTo: content.topAnchor), vc.view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                                     vc.view.leadingAnchor.constraint(equalTo: content.leadingAnchor), vc.view.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
    }

    private func updateHeader() {
        back.isHidden = stack.count < 2
        back.title = stack.count >= 2 ? stack[stack.count - 2].1 : ""
        titleLabel.stringValue = stack.last?.1 ?? L("place.settings")
        onStackChanged?()
    }

    /// The page shown, and the one Back returns to (the main window's toolbar shows them).
    var onStackChanged: (() -> Void)?
    var currentTitle: String { stack.last?.1 ?? L("place.settings") }
    var backTitle: String? { stack.count >= 2 ? stack[stack.count - 2].1 : nil }

    @objc private func closeClicked() { onClose?() }

    /// Pages refresh only while the panel is open (they own timers and observers).
    private(set) var isShown = false
    func willShow() { isShown = true; (stack.last?.0 as? FormPane)?.resume() }
    func didHide() { isShown = false; stack.forEach { ($0.0 as? FormPane)?.pause() } }
}

/// Every tag as a card (SwiftUI, hosted here): its name, how many media carry it, and a bar that
/// splits those media into yours, the AI's and both. Click a card to see only that tag on the
/// home screen; right-click for the rest (put its media into a folder, rename or merge, delete).
final class MacTagsPage: NSViewController {
    weak var panel: MacSettingsPanel?
    private let model = TagsModel()

    override func loadView() {
        model.window = { [weak self] in self?.view.window }
        let host = NSHostingView(rootView: TagCardsView(model: model))
        host.setAccessibilityIdentifier("tagCards")
        view = host
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
        model.load()
    }
}

/// The page's state and the actions behind its menus (alerts and sheets belong to the window).
@MainActor
final class TagsModel: ObservableObject {
    enum Sort: String, CaseIterable {
        case count, ai, mine, name
        var title: String { switch self { case .count: L("tags.sort.count"); case .ai: L("tags.sort.ai"); case .mine: L("tags.sort.mine"); case .name: L("common.name") } }
    }
    enum Show: String, CaseIterable {
        case all, mine, ai, both
        var title: String { switch self { case .all: L("search.kw.all.word"); case .mine: L("search.kw.mine.word"); case .ai: L("search.kw.ai.word"); case .both: L("search.kw.common.word") } }
    }

    @Published var all: [TagCount] = []
    @Published var query = ""
    @Published var sort = Sort.count
    @Published var show = Show.all
    @Published var loaded = false
    var window: () -> NSWindow? = { nil }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = Core.allTags()
            DispatchQueue.main.async { self.all = tags; self.loaded = true }
        }
    }

    /// Media with both your tag and the AI's: the two overlap by this much.
    static func common(_ t: TagCount) -> Int { max(0, t.user + t.ai - t.count) }

    var shown: [TagCount] {
        let k = query.trimmingCharacters(in: .whitespaces).lowercased()
        var v = k.isEmpty ? all : all.filter { $0.label.contains(k) }
        switch show {
        case .all: break
        case .mine: v = v.filter { $0.user > 0 }
        case .ai: v = v.filter { $0.ai > 0 }
        case .both: v = v.filter { Self.common($0) > 0 }
        }
        switch sort {
        case .count: return v.sorted { ($0.count, $1.label) > ($1.count, $0.label) }
        case .ai: return v.sorted { ($0.ai, $1.label) > ($1.ai, $0.label) }
        case .mine: return v.sorted { ($0.user, $1.label) > ($1.user, $0.label) }
        case .name: return v.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }
    }

    func showOnHome(_ label: String) { NotificationCenter.default.post(name: MacFeedViewController.showLabelNote, object: label) }

    /// Every AI tag goes; tags I added or endorsed stay.
    func confirmRemoveAI() {
        let n = all.reduce(0) { $0 + $1.ai }
        guard n > 0 else { return macAlert(window(), L("tags.noAI"), "") }
        macChoose(window(), title: L("tags.deleteAI.title", n), message: L("tags.deleteAI.message"), options: [L("tags.deleteAI.confirm")]) { [weak self] _ in
            do {
                try Core.removeAITags()
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.load()
            } catch { macAlert(self?.window(), L("tags.deleteAI.failed"), error.localizedDescription) }
        }
    }

    func rename(_ t: TagCount) {
        macPrompt(window(), title: L("tags.rename.title", t.label), message: L("tags.rename.message"), placeholder: t.label, initial: t.label) { [weak self] to in
            let to = to.trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty, to != t.label else { return }
            _ = try? Core.renameTag(t.label, to: to)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.load()
        }
    }

    func delete(_ t: TagCount) {
        macChoose(window(), title: L("tags.delete.title", t.label),
                  message: L("tags.delete.message", t.count),
                  options: [L("card.menu.deleteTag")]) { [weak self] _ in
            do {
                try Core.deleteTag(t.label)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                self?.load()
            } catch { macAlert(self?.window(), L("tags.delete.failed"), error.localizedDescription) }
        }
    }

    func toFolder(_ t: TagCount) {
        macChooseFolder(window(), title: L("tags.toFolder.title", t.label, t.count), suggested: t.label, message: L("tags.toFolder.message")) { [weak self] folder in
            guard let folder else { return }
            do {
                let n = try Core.tagToFolder(t.label, folder: folder)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                macAlert(self?.window(), L("tags.toFolder.done", folder), n == t.count ? L("search.row.mediaCount", n) : L("tags.toFolder.partly", n))
            } catch { macAlert(self?.window(), L("common.notDone"), error.localizedDescription) }
        }
    }
}

private extension Color {
    static let tagMine = Color.blue
    static let tagAI = Color.purple
    static let tagBoth = Color.green
}

struct TagCardsView: View {
    @ObservedObject var model: TagsModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolbar
                let tags = model.shown
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tags.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tags, id: \.label) { t in TagCard(tag: t, model: model) }
                    }
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("tags.filter"), text: $model.query).textFieldStyle(.plain)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.quaternary.opacity(0.6), in: Capsule())
                Menu {
                    Picker(L("tags.sort"), selection: $model.sort) { ForEach(TagsModel.Sort.allCases, id: \.self) { Text($0.title).tag($0) } }
                } label: { Label(L("tags.sortBy") + model.sort.title, systemImage: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).fixedSize()
                Menu {
                    Button(L("tags.deleteAIEllipsis"), role: .destructive) { model.confirmRemoveAI() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            HStack(spacing: 14) {
                Picker("", selection: $model.show) { ForEach(TagsModel.Show.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                Spacer()
                legend
            }
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        let n = model.shown.count
        return model.all.isEmpty ? "" : L("tags.total", model.all.count) + (n == model.all.count ? "" : L("tags.shown", n)) + L("tags.hint.mac")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([(L("search.kw.mine.word"), Color.tagMine), ("AI", Color.tagAI), (L("search.kw.common.word"), Color.tagBoth)], id: \.0) { name, c in
                HStack(spacing: 5) { Circle().fill(c).frame(width: 8, height: 8); Text(name).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.all.isEmpty ? "tag" : "magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(model.all.isEmpty ? L("tags.none") : L("tags.noMatch")).font(.headline)
            Text(model.all.isEmpty ? L("tags.none.message") : L("tags.noMatch.message")).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

/// One tag: its name, the number of media, and who tagged them (a bar: yours, the AI's, both).
struct TagCard: View {
    let tag: TagCount
    @ObservedObject var model: TagsModel
    @State private var hovering = false

    private var common: Int { TagsModel.common(tag) }
    private var onlyMine: Int { tag.user - common }
    private var onlyAI: Int { tag.ai - common }

    var body: some View {
        Button { model.showOnHome(tag.label) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(tag.label).font(.system(size: 16, weight: .semibold)).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(.tint)
                        .opacity(hovering ? 1 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(tag.count)").font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(L("tags.itemsUnit")).font(.callout).foregroundStyle(.secondary)
                }
                bar
                HStack(spacing: 10) {
                    if tag.user > 0 { stat(L("search.kw.mine.word"), tag.user, .tagMine) }
                    if tag.ai > 0 { stat("AI", tag.ai, .tagAI) }
                    if common > 0 { stat(L("search.kw.common.word"), common, .tagBoth) }
                }
                .font(.caption)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .background { cardBackground }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L("tags.onlyInBrowse", tag.label)) { model.showOnHome(tag.label) }
            Button(L("tags.allToFolder", tag.count)) { model.toFolder(tag) }
            Divider()
            Button(L("tags.renameOrMerge")) { model.rename(tag) }
            Button(L("tags.deleteEllipsis"), role: .destructive) { model.delete(tag) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("tags.cell.spoken", tag.label, tag.count, tag.user, tag.ai))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.strokeBorder(.separator))
        }
    }

    private func stat(_ name: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(name) \(n)").foregroundStyle(.secondary).monospacedDigit()
        }
    }

    /// One capsule split in yours (blue), both (green) and the AI's (purple); wide enough to see
    /// even a tiny share.
    private var bar: some View {
        GeometryReader { g in
            let total = max(tag.count, 1)
            let parts: [(Int, Color)] = [(onlyMine, .tagMine), (common, .tagBoth), (onlyAI, .tagAI)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(p.1.gradient).frame(width: max(5, (g.size.width - gaps) * CGFloat(p.0) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 8)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

/// A plain view filled with a (dynamic) color.
final class MacOpaqueView: NSView {
    private let color: NSColor
    init(color: NSColor) { self.color = color; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
}
