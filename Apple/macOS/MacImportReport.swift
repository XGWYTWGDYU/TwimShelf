import AppKit
import UniformTypeIdentifiers

/// Shows one import report: every file or folder that was not imported as a normal new media,
/// with its path inside the source, the reason, and what it matches. The listed files can be
/// exported byte for byte (with 说明.txt) into a ZIP.
final class MacImportReportWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [MacImportReportWindowController] = []

    static func show(reportFile: String) {
        guard let r = try? Core.importReport(reportFile) else { return }
        let c = MacImportReportWindowController(report: r, file: reportFile)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private let report: ImportReport
    private let file: String
    private var rows: [ImportIssue] = []
    private let table = NSTableView()
    private let filter = NSPopUpButton()

    private init(report: ImportReport, file: String) {
        self.report = report
        self.file = file
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = L("import.details")
        w.center()
        super.init(window: w)
        w.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Self.open.removeAll { $0 === self }
        }
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        let summary = NSTextField(wrappingLabelWithString: (report.source.map { L("import.sourceLine", $0) } ?? "") + report.summary)
        summary.font = .systemFont(ofSize: 12)
        filter.removeAllItems()
        filter.addItem(withTitle: L("import.allIssues", report.issues?.count ?? 0))
        for g in report.grouped { filter.addItem(withTitle: L("format.nameDetail", ImportIssue.title(g.category), g.items.count)) }
        filter.target = self
        filter.action = #selector(filterChanged)
        let export = ClosureButton(title: L("import.export")) { [weak self] in self?.exportFiles() }
        let reveal = ClosureButton(title: L("import.showReport")) { [weak self] in
            if let f = self?.file { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) } }
        let bar = NSStackView(views: [filter, NSView(), reveal, export])
        bar.spacing = 8

        for (id, title, width) in [("cat", L("import.col.category"), 150.0), ("path", L("import.col.path"), 360.0), ("reason", L("import.col.reason"), 300.0), ("same", L("import.col.match"), 200.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            table.addTableColumn(col)
        }
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.style = .fullWidth
        let sc = NSScrollView()
        sc.documentView = table
        sc.hasVerticalScroller = true
        sc.hasHorizontalScroller = true

        let root = NSView()
        [summary, bar, sc].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; root.addSubview($0) }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: root.topAnchor, constant: 16), summary.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            summary.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            bar.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12), bar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            sc.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10), sc.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sc.trailingAnchor.constraint(equalTo: root.trailingAnchor), sc.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root
        filterChanged()
    }

    @objc private func filterChanged() {
        let i = filter.indexOfSelectedItem
        rows = i <= 0 ? report.grouped.flatMap(\.items) : report.grouped[i - 1].items
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = (tableView.makeView(withIdentifier: .init("cell-" + id), owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = .init("cell-" + id)
            t.lineBreakMode = id == "path" ? .byTruncatingMiddle : .byTruncatingTail
            t.isSelectable = true
            return t
        }()
        let r = rows[row]
        cell.stringValue = switch id { case "cat": ImportIssue.title(r.category); case "path": r.path; case "reason": r.reason; default: r.sameAs ?? "" }
        cell.toolTip = cell.stringValue
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        func v(_ i: ImportIssue) -> String { switch key { case "cat": ImportIssue.title(i.category); case "path": i.path; case "reason": i.reason; default: i.sameAs ?? "" } }
        rows.sort { d.ascending ? v($0) < v($1) : v($0) > v($1) }
        table.reloadData()
    }

    private func exportFiles() {
        let p = NSSavePanel()
        p.nameFieldStringValue = L("import.problemsZip")
        p.allowedContentTypes = [.zip]
        p.begin { [weak self] r in
            guard r == .OK, let url = p.url, let self else { return }
            macRun(self.window, { try Core.exportImportIssues(report: self.file, to: url) }) { n in
                macAlert(self.window, L("mac.models.exported"), L("import.exported.message", n))
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// Import finished: summary, with the details one click away when something needs attention.
func macShowImportResult(_ window: NSWindow?, _ r: ImportReport) {
    let a = NSAlert()
    a.messageText = L("import.done")
    a.informativeText = r.summary
    a.addButton(withTitle: L("common.ok"))
    let hasIssues = !(r.issues ?? []).isEmpty && r.reportFile != nil
    if hasIssues { a.addButton(withTitle: L("import.viewDetails")) }
    let handle: (NSApplication.ModalResponse) -> Void = { resp in
        if hasIssues, resp == .alertSecondButtonReturn, let f = r.reportFile { MacImportReportWindowController.show(reportFile: f) }
    }
    if let window { a.beginSheetModal(for: window, completionHandler: handle) } else { handle(a.runModal()) }
}
