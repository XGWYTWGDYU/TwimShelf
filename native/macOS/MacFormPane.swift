import AppKit

/// A scrollable pane. `structure()` describes what is on screen; the form is rebuilt only when
/// it changes, while `refresh()` pushes live values into existing views (no flicker).
class FormPane: NSViewController {
    let form = MacForm()
    /// The settings panel showing this page (for opening sub-pages).
    weak var panel: MacSettingsPanel?
    private var timer: Timer?
    private var lastStructure: String?
    private var observers: [NSObjectProtocol] = []
    var refreshInterval: TimeInterval { 0 }

    override func loadView() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        form.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = form
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            form.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            form.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        view = scroll
        view.frame = NSRect(x: 0, y: 0, width: MacSettingsWindowController.width, height: 560)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if panel?.isShown ?? true { resume() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        pause()
    }

    /// Live updates (timer and notifications) run only while the page is on screen: a closed
    /// panel stays in the window, so it pauses its page explicitly.
    func resume() {
        guard timer == nil, observers.isEmpty else { return }
        update(force: true)
        if refreshInterval > 0 { timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in self?.tick(); self?.update() } }
        observers = [ActivityCenter.changed, ModelStore.changed, SyncService.changed, AutoTagger.progressChanged, LibraryPrefs.changed].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.update() }
        }
    }
    func pause() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    func update(force: Bool = false) {
        // Never rebuild behind an open sheet (it can leave the sheet unresponsive).
        if view.window?.attachedSheet != nil { return }
        let s = structure()
        if force || s != lastStructure {
            lastStructure = s
            let scroll = view as? NSScrollView
            let offset = scroll?.contentView.bounds.origin ?? .zero
            form.clear()
            build()
            refresh()
            view.layoutSubtreeIfNeeded()
            if let scroll {
                let maxY = max(0, form.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset.y), maxY)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        } else {
            refresh()
        }
    }

    func structure() -> String { "" }
    func build() {}
    func refresh() {}
    func tick() {}
}
