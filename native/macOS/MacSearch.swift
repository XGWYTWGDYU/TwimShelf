import AppKit

/// The search field's capsules and the text being typed, drawn by the app: AppKit's token field
/// draws its tokens as rounded rectangles that do not sit concentrically in the toolbar's capsule.
/// Here each capsule is a true capsule (corner radius = half its height). Behaves like the token
/// field it replaces: a word followed by a space (or Return) becomes a capsule, ⌫ at the start
/// selects the last capsule and a second ⌫ removes it, a click on a capsule selects it, and
/// input methods (拼音…) are never cut off while composing.
final class CapsuleTokenField: NSView, NSTextFieldDelegate {
    /// Turns a finished word into a capsule (nil: drop it).
    var makeToken: ((String) -> MacSearchToken?)?
    var onTextChange: (() -> Void)?
    var onBeginEditing: (() -> Void)?
    var onEndEditing: (() -> Void)?
    var onCommit: (() -> Void)?
    /// Clicked into (focused), before anything is typed.
    var onFocus: (() -> Void)?
    var placeholderString: String? { didSet { updatePlaceholder() } }

    private(set) var tokens: [MacSearchToken] = []
    private var chips: [Chip] = []
    private let text = InnerField()
    private var selected: Int? { didSet { for (i, c) in chips.enumerated() { c.isSelected = i == selected } } }
    private static let tokenizers = CharacterSet(charactersIn: " \u{3000}")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        text.isBordered = false
        text.drawsBackground = false
        text.focusRingType = .none
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.cell?.isScrollable = true
        text.cell?.wraps = false
        text.usesSingleLineMode = true
        text.delegate = self
        text.owner = self
        addSubview(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Capsules, then the text being typed (if any), as NSTokenField's objectValue was.
    var objectValue: Any? {
        get { tokens + (text.stringValue.isEmpty ? [] : [text.stringValue]) as [Any] }
        set {
            let list = (newValue as? [Any]) ?? []
            setTokens(list.compactMap { $0 as? MacSearchToken })
            text.stringValue = list.compactMap { $0 as? String }.joined(separator: " ")
            updatePlaceholder()
        }
    }

    /// The text field's editor while typing.
    func currentEditor() -> NSText? { text.currentEditor() }
    var editingField: NSTextField { text }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(text) ?? false }
    override func setAccessibilityIdentifier(_ id: String?) { super.setAccessibilityIdentifier(id); text.setAccessibilityIdentifier(id) }

    private func setTokens(_ t: [MacSearchToken]) {
        tokens = t
        chips.forEach { $0.removeFromSuperview() }
        chips = t.map { tok in
            let c = Chip(title: tok.title, excluded: TokenQuery.isExcluded(tok.key), spoken: TokenQuery.spoken(tok.key))
            c.onClick = { [weak self, weak c] in
                guard let self, let c, let i = self.chips.firstIndex(where: { $0 === c }) else { return }
                self.selected = i
                self.window?.makeFirstResponder(self.text)
                self.onFocus?()
            }
            addSubview(c)
            return c
        }
        selected = nil
        needsLayout = true
        updatePlaceholder()
    }

    private func updatePlaceholder() { text.placeholderString = tokens.isEmpty ? placeholderString : nil }

    override func layout() {
        super.layout()
        // inset from the toolbar capsule's rounded end, so the first capsule, the caret and the
        // placeholder sit inside its curve (concentric) instead of on its edge
        let h = bounds.height, chipH: CGFloat = 18, gap: CGFloat = 4, inset: CGFloat = 8
        var x: CGFloat = inset
        var frames: [NSRect] = []
        for c in chips { let w = c.width; frames.append(NSRect(x: x, y: ((h - chipH) / 2).rounded(), width: w, height: chipH)); x += w + gap }
        // the text keeps at least 60 pt; capsules that do not fit slide out on the left
        let minText: CGFloat = 60
        let shift = max(0, x + minText - bounds.width)
        let visibleStart = inset
        for (c, f) in zip(chips, frames) { c.frame = f.offsetBy(dx: -shift, dy: 0) }
        // capsules pushed out on the left disappear behind the inset instead of under the curve
        for c in chips { c.isHidden = c.frame.minX < visibleStart - 1 }
        let tx = x - shift
        let th = text.intrinsicContentSize.height
        // the text's line box centred on the same midline as the capsules
        text.frame = NSRect(x: tx - 2, y: ((h - th) / 2).rounded(), width: max(minText, bounds.width - tx), height: th)
    }

    override func mouseDown(with event: NSEvent) {
        selected = nil
        window?.makeFirstResponder(text)
        DispatchQueue.main.async { [weak self] in self?.onFocus?() }
    }

    fileprivate func focusedByUser() { DispatchQueue.main.async { [weak self] in self?.onFocus?() } }

    // MARK: Typing

    private var composing: Bool { (text.currentEditor() as? NSTextView)?.hasMarkedText() == true }

    /// Finished words (followed by a space) become capsules; the rest stays as typed text.
    private func tokenizeFinishedWords(all: Bool) {
        guard !composing else { return }
        let s = text.stringValue
        var parts = s.components(separatedBy: Self.tokenizers)
        let rest = all ? "" : (parts.popLast() ?? "")
        let made = parts.compactMap { w -> MacSearchToken? in w.isEmpty ? nil : makeToken?(w) }
        guard !made.isEmpty || s != rest else { return }
        setTokens(tokens + made)
        text.stringValue = rest
        if let ed = text.currentEditor() { ed.selectedRange = NSRange(location: (rest as NSString).length, length: 0) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) { onBeginEditing?() }
    func controlTextDidChange(_ obj: Notification) {
        selected = nil
        if text.stringValue.unicodeScalars.contains(where: Self.tokenizers.contains) { tokenizeFinishedWords(all: false) }
        updatePlaceholder()
        onTextChange?()
    }
    func controlTextDidEndEditing(_ obj: Notification) { selected = nil; onEndEditing?() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            tokenizeFinishedWords(all: true)
            onCommit?()
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            if let i = selected {
                var t = tokens; t.remove(at: i)
                setTokens(t)
                onTextChange?()
                return true
            }
            if sel == #selector(NSResponder.deleteBackward(_:)), textView.selectedRange == NSRange(location: 0, length: 0), !chips.isEmpty {
                selected = chips.count - 1          // first ⌫ selects the capsule, the second removes it
                return true
            }
            return false
        case #selector(NSResponder.moveLeft(_:)):
            if textView.selectedRange == NSRange(location: 0, length: 0), !chips.isEmpty {
                selected = max(0, (selected ?? chips.count) - 1)
                return true
            }
            return false
        case #selector(NSResponder.moveRight(_:)):
            if let i = selected { selected = i + 1 < chips.count ? i + 1 : nil; return true }
            return false
        default:
            selected = nil
            return false
        }
    }

    /// The text part: reports focus by the user (a click or a key, not the window choosing its
    /// first responder on its own).
    private final class InnerField: NSTextField {
        weak var owner: CapsuleTokenField?
        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            if ok, [.leftMouseDown, .leftMouseUp, .keyDown].contains(NSApp.currentEvent?.type) { owner?.focusedByUser() }
            return ok
        }
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            owner?.focusedByUser()
        }
    }

    /// One capsule: tinted, the accent colour when selected; a minus capsule red with a "−".
    private final class Chip: NSView {
        var onClick: (() -> Void)?
        var isSelected = false { didSet { needsDisplay = true } }
        private let title: String
        private let color: NSColor
        private static let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        init(title: String, excluded: Bool, spoken: String) {
            self.title = excluded ? "−" + title : title
            color = excluded ? .systemRed : .controlAccentColor
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel(spoken)
        }
        required init?(coder: NSCoder) { fatalError() }
        var width: CGFloat { ceil((title as NSString).size(withAttributes: [.font: Self.font]).width) + 16 }
        override func draw(_ dirtyRect: NSRect) {
            let r = bounds
            let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
            (isSelected ? color : color.withAlphaComponent(0.18)).setFill()
            path.fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: isSelected ? NSColor.white : color]
            let size = (title as NSString).size(withAttributes: attrs)
            (title as NSString).draw(at: NSPoint(x: ((r.width - size.width) / 2).rounded(), y: ((r.height - size.height) / 2).rounded()), withAttributes: attrs)
        }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}

/// Keeps the token field at its natural one-line height, centered.
final class FieldHost: NSView {
    override func layout() {
        super.layout()
        for v in subviews { v.frame = NSRect(x: 0, y: ((bounds.height - 22) / 2).rounded(), width: bounds.width, height: 22) }
    }
}

/// One capsule of the Mac search field (wrapping its key, so it is never mistaken for text
/// being typed).
final class MacSearchToken: NSObject {
    let key: String
    init(_ key: String) { self.key = key }

    var title: String { TokenQuery.title(key) }
}

/// The toolbar's search, the same as on iOS: words followed by a space become capsules —
/// 标签 贴文 用户 我的 AI 共同 文件夹 最近 外部导入 are conditions, anything else is text to search
/// for, interleaved freely; a word after 文件夹 names the folder. Suggestions complete
/// conditions, tags and folders as you type. The × beside the field ends the search.
final class MacTokenSearch: NSView {
    let field = CapsuleTokenField()
    /// The field's width follows the window (`setWidth`), so the toolbar's other items never
    /// end up in its overflow menu.
    private lazy var widthConstraint = field.superview!.widthAnchor.constraint(equalToConstant: 300)
    func setWidth(_ w: CGFloat) {
        fieldWidth = min(max(w, 150), 380).rounded()
        let width = fieldWidth + (shuffleShown ? 0 : Self.shuffleRoom)
        if widthConstraint.constant != width { widthConstraint.constant = width }
    }
    private var fieldWidth: CGFloat = 300

    /// 重新随机: by date there is nothing to shuffle. It shrinks and fades away while the field
    /// takes its room, and comes back the same way; the whole stays one width, so the toolbar
    /// around it does not move.
    private static let shuffleRoom: CGFloat = 28 + 6
    private let shuffleButton = MacRoundSearchButton(symbol: "shuffle", label: L("feed.reshuffle"))
    private let shuffleSlot = NSView()
    private lazy var shuffleWidth = shuffleSlot.widthAnchor.constraint(equalToConstant: shuffleShown ? Self.shuffleRoom : 0)
    var onShuffle: (() -> Void)?
    var shuffleShown = !LibraryPrefs.feedByAdded {
        didSet {
            guard shuffleShown != oldValue else { return }
            shuffleButton.isEnabled = shuffleShown
            shuffleButton.setAccessibilityElement(shuffleShown)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                shuffleWidth.constant = shuffleShown ? Self.shuffleRoom : 0
                widthConstraint.constant = fieldWidth + (shuffleShown ? 0 : Self.shuffleRoom)
                shuffleButton.alphaValue = shuffleShown ? 1 : 0
                layoutSubtreeIfNeeded()
            }
        }
    }
    private let exit = NSButton()
    private let searchMascot: NSImageView = {
        let v = NSImageView(image: Mascot.icon("search", side: 24))
        v.isHidden = true
        return v
    }()
    /// Exports what the search found; shown while there is a search, beside the ✕.
    private let exportButton = NSButton()
    var onExport: ((NSView) -> Void)?
    var onDownload: ((NSView) -> Void)?
    private let downloadButton = MacRoundSearchButton(symbol: "arrow.down", label: L("search.download"))
    /// What the quick download card hangs from; the field itself while a search has the button away.
    var quickDownloadAnchor: NSView { downloadButton.isHidden ? self : downloadButton }
    /// 按添加时间排序 and 按帖子分组: with the quick download button, at the same times.
    private let sortButton = MacRoundSearchButton(symbol: "clock", label: L("feed.sortByAdded"))
    private let groupButton = MacRoundSearchButton(symbol: "rectangle.stack", label: L("feed.groupByPost"))
    var onGrouped: ((Bool) -> Void)?
    var grouped = true { didSet { groupButton.isOn = grouped } }
    var onSortByAdded: ((Bool) -> Void)?
    var sortByAdded = LibraryPrefs.feedByAdded { didSet { updateSortButton() } }
    private func updateSortButton() { sortButton.isOn = sortByAdded }
    /// A filter chip of the page is on (not a capsule of this field): exporting is offered then too.
    var chipFilterActive = false { didSet { updateExportVisibility() } }
    private func updateExportVisibility() {
        exportButton.isHidden = exit.isHidden && !chipFilterActive
        downloadButton.isHidden = !exportButton.isHidden
        sortButton.isHidden = downloadButton.isHidden
        groupButton.isHidden = downloadButton.isHidden
    }
    var onChange: ((TokenQuery) -> Void)?
    private var tagCache: [TagCount] = []
    private var folderCache: [(name: String, count: Int)] = []
    private var tagsLoading = false
    private var tagsLoaded = false
    /// The list under the field, as on iOS: conditions, what to search for, matching tags and
    /// folders, recent searches; and a short guide with the library totals at the bottom.
    private var popover = NSPopover()
    private let list = MacSuggestionList()

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = L("search.placeholder")
        field.setAccessibilityIdentifier("search")
        field.makeToken = { [weak self] w in self?.token(for: w) }
        field.onTextChange = { [weak self] in self?.changed(); self?.showSuggestions() }
        field.onBeginEditing = { [weak self] in self?.tagsLoaded = false; self?.showSuggestions() }
        field.onEndEditing = { [weak self] in self?.endedEditing() }
        field.onCommit = { [weak self] in self?.changed() }
        exit.bezelStyle = .circular
        exit.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: L("search.exit"))
        exit.toolTip = L("search.exit")
        exit.target = self
        exit.action = #selector(clear)
        exit.isHidden = true
        exit.setAccessibilityIdentifier("searchExit")
        exportButton.bezelStyle = .circular
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: L("search.export"))
        exportButton.toolTip = L("search.export")
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.isHidden = true
        exportButton.setAccessibilityIdentifier("searchExport")
        downloadButton.setAccessibilityIdentifier("quickDownload")
        downloadButton.target = self
        downloadButton.action = #selector(downloadTapped)
        sortButton.setAccessibilityIdentifier("sortByAdded")
        sortButton.target = self
        sortButton.action = #selector(sortTapped)
        updateSortButton()
        groupButton.setAccessibilityIdentifier("groupToggle")
        groupButton.target = self
        groupButton.action = #selector(groupTapped)
        shuffleButton.setAccessibilityIdentifier("reshuffle")
        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleTapped)
        shuffleButton.alphaValue = shuffleShown ? 1 : 0
        shuffleButton.isEnabled = shuffleShown
        shuffleButton.setAccessibilityElement(shuffleShown)
        // its spacing is inside the slot, so closing it leaves nothing behind
        shuffleButton.translatesAutoresizingMaskIntoConstraints = false
        shuffleSlot.wantsLayer = true
        shuffleSlot.layer?.masksToBounds = true
        shuffleSlot.addSubview(shuffleButton)
        popover = makePopover()
        list.onPick = { [weak self] in self?.focusAfterPick() }
        // as on iOS, the conditions show as soon as the field is clicked, not only once typing
        field.onFocus = { [weak self] in
            guard let self else { return }
            if self.suppressFocusOpen { self.suppressFocusOpen = false; return }
            self.showSuggestions()
        }
        // the field is laid out by frame inside its host
        let host = FieldHost()
        host.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(field)
        let st = NSStackView(views: [searchMascot, host, exit, exportButton, sortButton, groupButton, downloadButton, shuffleSlot])
        st.spacing = 6
        st.setCustomSpacing(0, after: downloadButton)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor), st.bottomAnchor.constraint(equalTo: bottomAnchor),
            st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            widthConstraint,
            host.heightAnchor.constraint(equalToConstant: 28),
            shuffleWidth,
            shuffleSlot.heightAnchor.constraint(equalToConstant: 28),
            shuffleButton.trailingAnchor.constraint(equalTo: shuffleSlot.trailingAnchor),
            shuffleButton.centerYAnchor.constraint(equalTo: shuffleSlot.centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private var tokens: [MacSearchToken] { (field.objectValue as? [Any])?.compactMap { $0 as? MacSearchToken } ?? [] }

    /// A tag to search for, from a card: added as a capsule.
    func addTerm(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !tokens.contains(where: { $0.key == TokenQuery.termKey(t) }) else { return }
        SearchHistory.add(t)
        field.objectValue = tokens + [MacSearchToken(TokenQuery.termKey(t))]
        changed()
    }

    /// A tag was renamed: its capsule follows.
    func renameTerm(_ old: String, to new: String) {
        let plain = TokenQuery.termKey(old), minus = TokenQuery.minus + TokenQuery.termKey(old)
        guard tokens.contains(where: { $0.key == plain || $0.key == minus }) else { return }
        field.objectValue = tokens.map { $0.key == plain ? MacSearchToken(TokenQuery.termKey(new)) : $0.key == minus ? MacSearchToken(TokenQuery.minus + TokenQuery.termKey(new)) : $0 }
        changed()
    }

    @objc private func clear() {
        field.objectValue = []
        changed()
        closeList()
        window?.makeFirstResponder(nil)
    }

    /// Ends the search from elsewhere (a media shown in 浏览 that the search hid).
    func clearSearch() { clear() }

    @objc private func sortTapped() { closeList(); onSortByAdded?(!sortByAdded) }
    @objc private func groupTapped() { closeList(); onGrouped?(!grouped) }
    @objc private func shuffleTapped() { onShuffle?() }
    @objc private func downloadTapped() { closeList(); onDownload?(downloadButton) }

    @objc private func exportTapped() { closeList(); onExport?(exportButton) }

    private func endedEditing() {
        changed()
        // a click in the list ends editing too: keep it open then
        DispatchQueue.main.async { [weak self] in
            guard let self, self.popover.isShown, self.window?.firstResponder !== self.field.currentEditor(), NSApp.keyWindow !== self.popover.contentViewController?.view.window else { return }
            self.closeList()
        }
    }

    /// A click in the field opens the list, or closes it when it is open (a second click); a
    /// click anywhere else closes it; Esc closes it. Watched for the life of the field.
    private var clickMonitor: Any?
    private func watchClicks() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .keyDown {
                if e.keyCode == 53, self.popover.isShown { self.closeList(); return nil }   // Esc
                return e
            }
            if e.window === self.popover.contentViewController?.view.window { return e }
            let inField = e.window === self.window && self.field.bounds.contains(self.field.convert(e.locationInWindow, from: nil))
            if self.popover.isShown {
                self.closeList()
                if inField {
                    // the click that closed it should not reopen it (its focus callback runs next)
                    self.suppressFocusOpen = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.suppressFocusOpen = false }
                }
            } else if inField, e.type == .leftMouseDown {
                DispatchQueue.main.async { if !self.suppressFocusOpen { self.showSuggestions() } }
            }
            return e
        }
    }
    private var suppressFocusOpen = false

    private func closeList() { popover.close() }

    #if DEBUG
    /// Types into the field as a person would (the tour).
    func debugType(_ text: String) {
        window?.makeFirstResponder(field)
        field.currentEditor()?.insertText(text)
        changed()
        showSuggestions()
    }
    #endif

    #if DEBUG
    var debugExportButton: NSView { exportButton }
    var debugPopoverWindow: NSWindow? { popover.contentViewController?.view.window }
    var debugSuggestions: String { list.sections.map { "\($0.title ?? "")(\($0.rows.map(\.title).joined(separator: ",")))" }.joined(separator: " ") + " size=\(popover.contentSize) window=\(popover.contentViewController?.view.window?.frame.size ?? .zero) list=\(list.frame.size)" }
    #endif

    /// What is being typed (not yet a capsule).
    private var typed: String {
        ((field.objectValue as? [Any])?.compactMap { $0 as? String }.last ?? "").trimmingCharacters(in: .whitespaces)
    }

    private func add(_ key: String) {
        field.objectValue = tokens + [MacSearchToken(key)]
        changed()
    }

    private func focusAfterPick() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(field)
        // put the caret at the end instead of selecting everything
        if let ed = field.currentEditor() { ed.selectedRange = NSRange(location: (ed.string as NSString).length, length: 0) }
        showSuggestions()
    }

    private func makePopover() -> NSPopover {
        let p = NSPopover()
        let vc = NSViewController()
        vc.view = list
        p.contentViewController = vc
        p.behavior = .applicationDefined
        p.animates = false
        // a dropdown list under the field, without the popover's pointer arrow (AppKit's own
        // option; checked first so a system without it keeps the arrow instead of crashing)
        if p.responds(to: NSSelectorFromString("setShouldHideAnchor:")) { p.setValue(true, forKey: "shouldHideAnchor") }
        return p
    }

    private func showSuggestions() {
            if !tagsLoaded, !tagsLoading {
                tagsLoading = true
                Task { [weak self] in
                    let (tags, folders) = await Task.detached { (Core.allTags(), Core.folders()) }.value
                    guard let self else { return }
                    self.tagCache = tags; self.folderCache = folders; self.tagsLoading = false; self.tagsLoaded = true
                    if self.popover.isShown { self.showSuggestions() }
                }
            }
        list.sections = suggestionSections()
        list.footer = (ActivityCenter.shared.statsLine.isEmpty ? "" : ActivityCenter.shared.statsLine + "\n") + SearchHighlight.guide
        // the list sized first as well: shown for the first time it would otherwise take its own
        // (still empty) frame, and the popover opened as a sliver with nothing in it
        let size = list.fittingSize(width: max(field.bounds.width, 420))
        list.setFrameSize(size)
        // a shown popover keeps the size it opened with (it stayed tall after typing narrowed the
        // list, the rows sinking under an empty band): a new one at the new size, no animation
        if popover.isShown, abs(popover.contentSize.height - size.height) > 1 {
            popover.close()
            popover.contentViewController?.view = NSView()     // hand the list over
            popover = makePopover()
        }
        popover.contentViewController?.preferredContentSize = size
        popover.contentSize = size
        // AppKit throws when the anchor is not on screen (a narrow window moves the search
        // field into the toolbar's overflow menu): no list then, instead of a crash
        guard field.window != nil, !field.isHiddenOrHasHiddenAncestor else { return }
        if !popover.isShown { popover.show(relativeTo: field.bounds, of: field, preferredEdge: .maxY) }
        watchClicks()
    }

    /// Same sections as the iOS list (shared: `SearchSuggestions`).
    private func suggestionSections() -> [MacSuggestionList.Section] {
        SearchSuggestions.sections(typed: typed, keys: tokens.map(\.key), tags: tagCache, folders: folderCache).map { sec in
            .init(title: sec.title, rows: sec.rows.map { r in
                let tint: NSColor = switch r.tint { case .accent: .controlAccentColor; case .folder: .systemTeal; case .secondary: .secondaryLabelColor; case .exclude: .systemRed }
                return MacSuggestionList.Row(id: r.id, title: r.title, subtitle: r.subtitle, symbol: r.symbol, tint: tint, destructive: r.destructive,
                                             action: r.action.map { a in { [weak self] in self?.perform(a) } })
            })
        }
    }

    private func perform(_ a: SearchSuggestion.Action) {
        // what was typed gives way to the pick
        let keep = tokens
        switch a {
        case .key(let k):
            if k.hasPrefix("t:") { SearchHistory.add(String(k.dropFirst(2))) }
            field.objectValue = keep + [MacSearchToken(k)]
        case .folder(let name, let excluded):
            var t = keep
            if let last = t.last?.key, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder { t.removeLast() }
            if !excluded { t.removeAll { $0.key.hasPrefix("d:") } }
            field.objectValue = t + [MacSearchToken((excluded ? TokenQuery.minus : "") + TokenQuery.folderKey(name))]
        case .clearHistory:
            SearchHistory.clear()
        }
        changed()
    }

    /// Reads the capsules: a name typed after "文件夹" becomes the folder; then the search runs.
    private func changed() {
        var out: [MacSearchToken] = []
        var merged = false
        for t in tokens {
            let pending = out.last?.key
            if pending == TokenQuery.pendingFolder || pending == TokenQuery.minus + TokenQuery.pendingFolder, t.key.hasPrefix("t:") || t.key.hasPrefix(TokenQuery.minus + "t:") {
                let excluded = pending != TokenQuery.pendingFolder
                let typed = String(t.key.drop { $0 == "-" }.dropFirst(2))
                let name = folderCache.first { $0.name.lowercased() == typed.lowercased() }?.name ?? typed
                out.removeLast()
                if !excluded { out.removeAll { $0.key.hasPrefix("d:") } }
                out.append(MacSearchToken((excluded ? TokenQuery.minus : "") + TokenQuery.folderKey(name)))
                merged = true
            } else { out.append(t) }
        }
        if merged {
            let typing = (field.objectValue as? [Any])?.compactMap { $0 as? String } ?? []
            field.objectValue = (out as [Any]) + (typing as [Any])
        }
        exit.isHidden = out.isEmpty && (field.objectValue as? [Any])?.isEmpty != false
        // once something is searched for, in the mascot mode (the field has no icon otherwise)
        searchMascot.isHidden = exit.isHidden || !Mascot.isOn
        updateExportVisibility()
        exit.setAccessibilityValue(out.map { TokenQuery.spoken($0.key) }.joined(separator: L("list.separator")))
        onChange?(TokenQuery(keys: out.map(\.key)))
    }

    // MARK: Capsules

    /// A finished word as a capsule: a condition word, a folder, or text to search for.
    private func token(for editingString: String) -> MacSearchToken? {
        let w = editingString.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        let k = TokenQuery.key(for: w, after: nil)
        if k.hasPrefix("t:") { SearchHistory.add(String(k.dropFirst(2))) }
        return MacSearchToken(k)
    }
}

/// The grouped list shown under the search field (a popover), like the iOS suggestions list.
final class MacSuggestionList: NSView {
    struct Row {
        var id: String
        var title: String
        var subtitle: String? = nil
        var symbol: String? = nil
        var tint: NSColor = .controlAccentColor
        var destructive = false
        var action: (() -> Void)? = nil
    }
    struct Section { var title: String?; var rows: [Row] }

    var sections: [Section] = [] { didSet { rebuild() } }
    var footer = "" { didSet { rebuild() } }
    var onPick: (() -> Void)?
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityIdentifier("searchSuggestions")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
        let doc = FlippedStackHost()
        doc.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor), stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor), stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Height of the content (capped), at the given width — added up from the rows rather than
    /// asked of Auto Layout, which measured the wrapping guide at the bottom far too tall (the
    /// popover opened with an empty band above its rows).
    func fittingSize(width: CGFloat) -> NSSize {
        let headerH = ceil(NSFont.systemFont(ofSize: 11, weight: .semibold).boundingRectForFont.height)
        var h: CGFloat = stack.edgeInsets.top
        for sec in sections {
            if sec.title != nil { h += headerH + 4 }
            h += CGFloat(sec.rows.count) * 28 + CGFloat(max(0, sec.rows.count - 1)) * stack.spacing + 12
        }
        if !footer.isEmpty {
            let f = NSTextField(wrappingLabelWithString: footer)
            f.font = .systemFont(ofSize: 11)
            h += ceil(f.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 20, height: .greatestFiniteMagnitude)).height)
        } else if !sections.isEmpty {
            h -= 12
        }
        h += stack.edgeInsets.bottom
        return NSSize(width: width, height: min(ceil(h), 520))
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for s in sections {
            if let t = s.title {
                let h = NSTextField(labelWithString: t)
                h.font = .systemFont(ofSize: 11, weight: .semibold)
                h.textColor = .secondaryLabelColor
                stack.addArrangedSubview(h)
                stack.setCustomSpacing(4, after: h)
            }
            for r in s.rows {
                let v = MacSuggestionRow(r) { [weak self] in r.action?(); self?.onPick?() }
                stack.addArrangedSubview(v)
                v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
            }
            if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(12, after: last) }
        }
        if !footer.isEmpty {
            let f = NSTextField(wrappingLabelWithString: footer)
            f.font = .systemFont(ofSize: 11)
            f.textColor = .secondaryLabelColor
            f.setAccessibilityIdentifier("statsLine")
            stack.addArrangedSubview(f)
            f.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
    }
}

private final class FlippedStackHost: NSView { override var isFlipped: Bool { true } }

/// One suggestion: symbol, title and hint; highlighted under the pointer, chosen with a click.
private final class MacSuggestionRow: NSView {
    private let pick: () -> Void
    private var area: NSTrackingArea?

    init(_ r: MacSuggestionList.Row, pick: @escaping () -> Void) {
        self.pick = pick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        let icon = NSImageView(image: r.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? NSImage())
        icon.contentTintColor = r.destructive ? .systemRed : r.tint
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        let t = NSTextField(labelWithString: r.title)
        t.font = .systemFont(ofSize: 13)
        if r.destructive { t.textColor = .systemRed }
        let d = NSTextField(labelWithString: r.subtitle ?? "")
        d.font = .systemFont(ofSize: 12)
        d.textColor = .secondaryLabelColor
        d.lineBreakMode = .byTruncatingTail
        d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let st = NSStackView(views: [icon, t, d])
        st.spacing = 8
        st.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor), st.bottomAnchor.constraint(equalTo: bottomAnchor),
            st.leadingAnchor.constraint(equalTo: leadingAnchor), st.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 28), icon.widthAnchor.constraint(equalToConstant: 18),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(r.title)
        setAccessibilityIdentifier("sugg-" + r.id)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { pick() } }
    override func accessibilityPerformPress() -> Bool { pick(); return true }
}

/// A button of the search row: a round plate, filled while on. The symbol stays the same in both
/// states and is never a filled or circled one: inside a round plate those read as a circle in a
/// circle.
final class MacRoundSearchButton: NSButton {
    private static let side: CGFloat = 28
    var isOn = false { didSet { update() } }

    init(symbol: String, label: String) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        title = ""
        imagePosition = .imageOnly
        isBordered = false
        toolTip = label
        wantsLayer = true
        layer?.cornerRadius = Self.side / 2
        widthAnchor.constraint(equalToConstant: Self.side).isActive = true
        heightAnchor.constraint(equalToConstant: Self.side).isActive = true
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isOn ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        }
        contentTintColor = isOn ? .white : .labelColor
        setAccessibilityValue(isOn ? L("a11y.selected") : L("a11y.notSelected"))
    }

    // a symbol's own insets would stretch the plate, each symbol by a different amount
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); update() }
}
