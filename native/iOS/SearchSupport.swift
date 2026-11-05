import UIKit

// MARK: - Suggestions list

/// The grouped list under the search field: suggestions, filters and scopes, as system list
/// rows (checkmarks, switches, pop-up buttons). It covers 浏览 while searching.
final class SearchSuggestionsView: UIView, UITableViewDataSource, UITableViewDelegate {
    struct Row {
        enum Accessory { case none, disclosure, check(Bool), toggle(Bool, (Bool) -> Void), menu(String, () -> UIMenu) }
        var id: String
        var title: String
        var subtitle: String? = nil
        var symbol: String? = nil
        var tint: UIColor = .tintColor
        var destructive = false
        var accessory: Accessory = .none
        var action: (() -> Void)? = nil
    }
    struct Section { var title: String?; var rows: [Row] }

    var sections: [Section] = [] { didSet { table.reloadData() } }
    let table = UITableView(frame: .zero, style: .insetGrouped)
    /// Library totals and a short tip, under the last section.
    let footer = UILabel()
    private let footerHost = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemGroupedBackground
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = .clear
        table.keyboardDismissMode = .onDrag
        table.contentInsetAdjustmentBehavior = .never
        table.translatesAutoresizingMaskIntoConstraints = false
        table.accessibilityIdentifier = "searchSuggestions"
        addSubview(table)
        NSLayoutConstraint.activate([table.topAnchor.constraint(equalTo: topAnchor), table.bottomAnchor.constraint(equalTo: bottomAnchor),
                                     table.leadingAnchor.constraint(equalTo: leadingAnchor), table.trailingAnchor.constraint(equalTo: trailingAnchor)])
        footer.font = .preferredFont(forTextStyle: .footnote)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0
        footer.accessibilityIdentifier = "statsLine"
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerHost.addSubview(footer)
        NSLayoutConstraint.activate([footer.topAnchor.constraint(equalTo: footerHost.topAnchor, constant: 4),
                                     footer.leadingAnchor.constraint(equalTo: footerHost.layoutMarginsGuide.leadingAnchor, constant: 16),
                                     footer.trailingAnchor.constraint(equalTo: footerHost.layoutMarginsGuide.trailingAnchor, constant: -16)])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Room for the search bar floating above the list.
    var topInset: CGFloat = 0 { didSet { if table.contentInset.top != topInset { table.contentInset.top = topInset; table.verticalScrollIndicatorInsets.top = topInset } } }

    func setFooter(_ text: String) {
        footer.text = text
        let w = max(table.bounds.width, 320)
        let h = footer.systemLayoutSizeFitting(CGSize(width: w - 64, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        footerHost.frame = CGRect(x: 0, y: 0, width: w, height: h + 24)
        table.tableFooterView = footerHost
    }

    func numberOfSections(in tv: UITableView) -> Int { sections.count }
    func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { sections[s].rows.count }
    func tableView(_ tv: UITableView, titleForHeaderInSection s: Int) -> String? { sections[s].title }

    func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let r = sections[ip.section].rows[ip.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = cell.defaultContentConfiguration()
        c.text = r.title
        c.secondaryText = r.subtitle
        c.secondaryTextProperties.color = .secondaryLabel
        if r.destructive { c.textProperties.color = .systemRed }
        if let s = r.symbol { c.image = UIImage(systemName: s); c.imageProperties.tintColor = r.destructive ? .systemRed : r.tint }
        cell.contentConfiguration = c
        cell.accessibilityIdentifier = "sugg-" + r.id
        switch r.accessory {
        case .none: break
        case .disclosure: cell.accessoryType = .disclosureIndicator
        case .check(let on): cell.accessoryType = on ? .checkmark : .none; cell.accessibilityValue = on ? L("a11y.selected") : L("a11y.notSelected")
        case .toggle(let on, let changed):
            let sw = UISwitch()
            sw.isOn = on
            sw.accessibilityIdentifier = "sugg-" + r.id + "-switch"
            sw.addAction(UIAction { _ in changed(sw.isOn) }, for: .valueChanged)
            cell.accessoryView = sw
            cell.selectionStyle = .none
        case .menu(let value, let menu):
            var cfg = UIButton.Configuration.plain()
            cfg.title = value
            cfg.indicator = .popup
            cfg.baseForegroundColor = .secondaryLabel
            let b = UIButton(configuration: cfg)
            b.menu = menu()
            b.showsMenuAsPrimaryAction = true
            b.accessibilityIdentifier = "sugg-" + r.id + "-menu"
            b.accessibilityLabel = r.title
            b.accessibilityValue = value
            b.sizeToFit()
            cell.accessoryView = b
            cell.selectionStyle = .none
        }
        return cell
    }

    func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        let r = sections[ip.section].rows[ip.row]
        if case .menu = r.accessory { return }
        if case .toggle = r.accessory { return }
        r.action?()
    }
}
