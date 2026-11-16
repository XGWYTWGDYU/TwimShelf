import UIKit

/// Recent warnings and errors (newest first), from the app log.
final class ProblemsViewController: FormViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.problemLog")
        navigationItem.largeTitleDisplayMode = .never
        let list = AppLog.recentProblems()
        let f = DateFormatter(); f.dateFormat = L("date.monthDayTimeSeconds")
        let rows: [Row] = list.isEmpty ? [.value(L("mac.problems.none"), nil)] : list.enumerated().map { i, e in
            let l = UILabel()
            l.numberOfLines = 0
            let a = NSMutableAttributedString(string: "\(f.string(from: e.date)) · \(e.cat)\n", attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1), .foregroundColor: e.level == .error ? UIColor.systemRed : UIColor.systemOrange])
            a.append(NSAttributedString(string: e.msg, attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote)]))
            l.attributedText = a
            return .custom("p\(i)", l)
        }
        sections = [
            Section(id: "export", footer: Diagnostics.contents, rows: [
                .button(L("settings.exportDiagnostics"), icon: .init("stethoscope", .systemTeal), id: "b:diag2") { [weak self] in
                    (self?.navigationController?.viewControllers.first { $0 is SettingsViewController } as? SettingsViewController)?.exportDiagnostics() },
            ]),
            Section(id: "list", header: L("mac.problems.recent", list.count), rows: rows),
        ]
        reloadForm(animated: false)
    }
}
