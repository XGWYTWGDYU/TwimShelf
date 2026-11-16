import UIKit

/// One import report: every file or folder that was not imported as a normal new media, with its
/// path inside the source, the reason, and what it matches. The files can be exported unchanged.
final class ImportReportViewController: FormViewController {
    private let report: ImportReport
    private let file: String

    init(report: ImportReport, file: String) { self.report = report; self.file = file; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("import.details")
        navigationItem.largeTitleDisplayMode = .never
        let summary = UILabel()
        summary.numberOfLines = 0
        summary.font = .preferredFont(forTextStyle: .subheadline)
        summary.text = report.summary
        var s: [Section] = [Section(id: "summary", footer: report.source.map { L("import.source") + URL(fileURLWithPath: $0).lastPathComponent }, rows: [.custom("summary", summary)])]
        if report.grouped.contains(where: { $0.items.contains(where: \.isFile) }) {
            s.append(Section(id: "export", footer: L("import.export.footer"), rows: [
                .button(L("import.export"), icon: .init("square.and.arrow.up", .systemBlue)) { [weak self] in self?.export() },
            ]))
        }
        s.append(Section(id: "delete", footer: L("import.delete.footer"), rows: [
            .button(L("import.delete"), icon: .init("trash", .systemRed), destructive: true, id: "b:deleteReport") { [weak self] in
                guard let self else { return }
                self.confirmDeleteImportReports([self.file], what: L("mac.importHistory.this")) { [weak self] in self?.navigationController?.popViewController(animated: true) }
            },
        ]))
        for g in report.grouped {
            let rows: [Row] = g.items.prefix(500).enumerated().map { i, it in
                let l = UILabel()
                l.numberOfLines = 0
                let a = NSMutableAttributedString(string: it.path + "\n", attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)])
                a.append(NSAttributedString(string: it.reason, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel]))
                if let same = it.sameAs { a.append(NSAttributedString(string: L("import.matches") + same, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel])) }
                l.attributedText = a
                return .custom("\(g.category)-\(i)", l)
            }
            s.append(Section(id: g.category, header: L("format.nameDetail", ImportIssue.title(g.category), g.items.count),
                             footer: g.items.count > 500 ? L("import.first500") : nil, rows: rows))
        }
        sections = s
        reloadForm(animated: false)
    }

    private func export() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("import-issues", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(L("import.problemsZip"))
        runBusy(L("export.runningShort"), { try Core.exportImportIssues(report: self.file, to: out) }) { [weak self] _ in
            guard let self else { return }
            let share = UIActivityViewController(activityItems: [out], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = self.view
            share.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: 120, width: 1, height: 1)
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
            self.present(share, animated: true)
        }
    }
}

/// Saved import reports, newest first.
final class ImportHistoryViewController: FormViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.importRecords")
        navigationItem.largeTitleDisplayMode = .never
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        build()
    }

    private func build() {
        let f = DateFormatter(); f.dateFormat = L("date.monthDayTime")
        let list = Core.importReports()
        sections = [Section(id: "list", footer: L("import.history.footer"), rows: list.isEmpty ? [.value(L("import.history.none"), nil)] : list.map { r in
            .navigation(f.string(from: r.date) + " · " + URL(fileURLWithPath: r.source).lastPathComponent, detail: r.issues == 0 ? L("mac.importHistory.ok") : L("import.issuesCount", r.issues),
                        icon: .init(r.issues == 0 ? "checkmark.circle" : "exclamationmark.circle", r.issues == 0 ? .systemGreen : .systemOrange), id: "r:" + r.file) { [weak self] in
                guard let rep = try? Core.importReport(r.file) else { return }
                self?.navigationController?.pushViewController(ImportReportViewController(report: rep, file: r.file), animated: true)
            }
        })]
        if !list.isEmpty {
            sections.append(Section(id: "deleteAll", rows: [
                .button(L("import.deleteAll"), icon: .init("trash", .systemRed), destructive: true, id: "b:deleteAllReports") { [weak self] in
                    self?.confirmDeleteImportReports(list.map(\.file), what: L("mac.importHistory.all", list.count)) { self?.build() }
                },
            ]))
        }
        reloadForm(animated: false)
    }
}

extension UIViewController {
    /// Deletes import records after a confirmation; the app's own copies of their sources go too.
    func confirmDeleteImportReports(_ files: [String], what: String, done: @escaping () -> Void) {
        let a = UIAlertController(title: L("mac.importHistory.deleteTitle", what), message: L("import.deleteAll.message"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.delete"), style: .destructive) { [weak self] _ in
            do {
                let r = try Core.deleteImportReports(files, owned: ShareInbox.ownedRoots)
                let msg = r.sources > 0 ? L("import.deleted.sources", r.sources, ActivityCenter.bytes(r.bytes)) : L("import.deleted.freed", ActivityCenter.bytes(r.bytes))
                let ok = UIAlertController(title: L("mac.importHistory.deleted", r.reports), message: msg, preferredStyle: .alert)
                ok.addAction(UIAlertAction(title: L("common.ok"), style: .default) { _ in done() })
                self?.present(ok, animated: true)
            } catch {
                let e = UIAlertController(title: L("mac.deleteFailed"), message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: L("common.ok"), style: .cancel))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }
}

extension UIFont {
    func withTraits(_ t: UIFontDescriptor.SymbolicTraits) -> UIFont {
        fontDescriptor.withSymbolicTraits(t).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

extension UIViewController {
    /// Import finished: summary, with the details one tap away when something needs attention.
    func showImportResult(_ r: ImportReport, extra: String = "") {
        let a = UIAlertController(title: L("import.done"), message: r.summary + extra, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.ok"), style: .cancel))
        if let f = r.reportFile, !(r.issues ?? []).isEmpty {
            a.addAction(UIAlertAction(title: L("import.viewDetails"), style: .default) { [weak self] _ in
                let vc = ImportReportViewController(report: r, file: f)
                if let nav = (self as? UINavigationController) ?? self?.navigationController { nav.pushViewController(vc, animated: true) }
                else { self?.present(UINavigationController(rootViewController: vc), animated: true) }
            })
        }
        present(a, animated: true)
    }
}
