import UIKit

/// Declarative inset-grouped form built on a diffable list. Rows have stable ids, so updates
/// animate (insert/delete) and only rows whose visible content changed are reconfigured — no
/// full reloads, no lost text-field focus, no flicker while timers refresh status.
class FormViewController: UIViewController, UICollectionViewDelegate {

    struct Icon: Hashable {
        let symbol: String
        let color: UIColor
        /// `mascot`: the icon that takes its place in the mascot mode.
        /// `alwaysMascot`: that icon whether the mode is on or not.
        init(_ symbol: String, _ color: UIColor = .systemBlue, mascot: String? = nil, alwaysMascot: Bool = false) {
            self.symbol = mascot != nil && (alwaysMascot || Mascot.isOn) ? "mascot:" + mascot! : symbol
            self.color = color
        }
    }

    struct Section {
        var id: String
        var header: String? = nil
        var footer: String? = nil
        var rows: [Row]
    }

    struct Row {
        enum Kind {
            case value(String, String?)
            case button(String, destructive: Bool, enabled: Bool, action: () -> Void)
            case navigation(String, detail: String?, action: () -> Void)
            /// A card that opens in place: the tap or its arrow shows the rows that follow it.
            case expander(String, detail: String?, expanded: Bool, action: () -> Void)
            case toggle(String, Bool, enabled: Bool, changed: (Bool) -> Void)
            case stepper(String, value: Double, range: ClosedRange<Double>, step: Double, format: (Double) -> String, changed: (Double) -> Void)
            /// A choice shown as the system pop-up button (current value + ⌃⌄), as in Settings.
            case menu(String, value: String, menu: () -> UIMenu)
            /// A view owned by the controller (kept across updates so its state survives).
            case custom(UIView)
            /// The same on the page itself, without a card around it.
            case banner(UIView)
        }
        var id: String
        var kind: Kind
        var icon: Icon?
        /// Changes when visible content changes; drives reconfiguration.
        var signature: String

        static func value(_ title: String, _ detail: String?, icon: Icon? = nil, id: String? = nil) -> Row {
            Row(id: id ?? "v:" + title, kind: .value(title, detail), icon: icon, signature: "\(title)|\(detail ?? "")|\(icon?.symbol ?? "")")
        }
        static func button(_ title: String, icon: Icon? = nil, destructive: Bool = false, enabled: Bool = true, id: String? = nil, action: @escaping () -> Void) -> Row {
            Row(id: id ?? "b:" + title, kind: .button(title, destructive: destructive, enabled: enabled, action: action), icon: icon, signature: "\(title)|\(destructive)|\(enabled)")
        }
        static func navigation(_ title: String, detail: String? = nil, icon: Icon? = nil, id: String? = nil, action: @escaping () -> Void) -> Row {
            Row(id: id ?? "n:" + title, kind: .navigation(title, detail: detail, action: action), icon: icon, signature: "\(title)|\(detail ?? "")|\(icon?.symbol ?? "")")
        }
        static func expander(_ title: String, detail: String? = nil, expanded: Bool, icon: Icon? = nil, id: String, action: @escaping () -> Void) -> Row {
            Row(id: id, kind: .expander(title, detail: detail, expanded: expanded, action: action), icon: icon, signature: "\(title)|\(detail ?? "")|\(expanded)|\(icon?.symbol ?? "")")
        }
        static func toggle(_ title: String, _ on: Bool, enabled: Bool = true, icon: Icon? = nil, id: String? = nil, changed: @escaping (Bool) -> Void) -> Row {
            Row(id: id ?? "t:" + title, kind: .toggle(title, on, enabled: enabled, changed: changed), icon: icon, signature: "\(title)|\(on)|\(enabled)")
        }
        static func stepper(_ title: String, value: Double, range: ClosedRange<Double>, step: Double, icon: Icon? = nil, format: @escaping (Double) -> String, changed: @escaping (Double) -> Void) -> Row {
            Row(id: "s:" + title, kind: .stepper(title, value: value, range: range, step: step, format: format, changed: changed), icon: icon, signature: "\(title)|\(value)")
        }
        static func menu(_ title: String, value: String, icon: Icon? = nil, id: String? = nil, menu: @escaping () -> UIMenu) -> Row {
            Row(id: id ?? "m:" + title, kind: .menu(title, value: value, menu: menu), icon: icon, signature: "\(title)|\(value)")
        }
        static func banner(_ id: String, _ view: UIView) -> Row {
            Row(id: "c:" + id, kind: .banner(view), icon: nil, signature: "\(ObjectIdentifier(view))")
        }
        static func custom(_ id: String, _ view: UIView) -> Row {
            Row(id: "c:" + id, kind: .custom(view), icon: nil, signature: "\(ObjectIdentifier(view))")
        }
    }

    private(set) var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private var sectionsById: [String: Section] = [:]
    private var rowsById: [String: Row] = [:]
    private var lastSignatures: [String: String] = [:]
    var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        cfg.headerMode = .supplementary
        cfg.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout { [weak self] idx, env in
            var c = cfg
            let sid = self?.dataSource.sectionIdentifier(for: idx)
            let s = sid.flatMap { self?.sectionsById[$0] }
            c.headerMode = s?.header == nil ? .none : .supplementary
            c.footerMode = s?.footer == nil ? .none : .supplementary
            return NSCollectionLayoutSection.list(using: c, layoutEnvironment: env)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.keyboardDismissMode = .interactive
        // Progress cards update their labels in place; let their constraints grow the row.
        collectionView.selfSizingInvalidation = .enabledIncludingConstraints
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> { [weak self] cell, _, id in
            self?.configure(cell, id: id)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] v, _, ip in
            var c = UIListContentConfiguration.groupedHeader()
            c.text = self?.section(at: ip.section)?.header
            v.contentConfiguration = c
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionFooter) { [weak self] v, _, ip in
            var c = UIListContentConfiguration.groupedFooter()
            c.text = self?.section(at: ip.section)?.footer
            v.contentConfiguration = c
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, id in
            cv.dequeueConfiguredReusableCell(using: cell, for: ip, item: id)
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in
            kind == UICollectionView.elementKindSectionHeader
                ? cv.dequeueConfiguredReusableSupplementary(using: header, for: ip)
                : cv.dequeueConfiguredReusableSupplementary(using: footer, for: ip)
        }
    }

    private func section(at idx: Int) -> Section? {
        dataSource.sectionIdentifier(for: idx).flatMap { sectionsById[$0] }
    }

    /// Applies `sections`: animated structural diff + reconfigure of rows whose signature changed.
    // MARK: Keyboard

    /// Leaves room for the keyboard and keeps the row being edited — and the row after it, such
    /// as a "下载" button under the text box — above it.
    @objc private func keyboardChanged(_ n: Notification) {
        guard let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue, view.window != nil else { return }
        let hiding = n.name == UIResponder.keyboardWillHideNotification
        let kb = view.convert(end, from: UIScreen.main.coordinateSpace)
        let overlap = hiding ? 0 : max(0, view.bounds.maxY - kb.minY - view.safeAreaInsets.bottom)
        collectionView.contentInset.bottom = overlap
        collectionView.verticalScrollIndicatorInsets.bottom = overlap
        if overlap > 0 { DispatchQueue.main.async { self.revealEditingRow() } }
    }

    private func revealEditingRow() {
        func editing(_ v: UIView) -> Bool { v.isFirstResponder || v.subviews.contains(where: editing) }
        guard let cell = collectionView.visibleCells.first(where: { editing($0.contentView) }),
              let ip = collectionView.indexPath(for: cell) else { return }
        var rect = cell.frame
        let next = IndexPath(item: ip.item + 1, section: ip.section)
        if next.item < collectionView.numberOfItems(inSection: ip.section), let a = collectionView.layoutAttributesForItem(at: next) { rect = rect.union(a.frame) }
        collectionView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -12), animated: true)
    }

    func reloadForm(animated: Bool = true) {
        guard dataSource != nil else { return }
        var snap = NSDiffableDataSourceSnapshot<String, String>()
        var newRows: [String: Row] = [:]
        var newSections: [String: Section] = [:]
        var seen = Set<String>()
        for s in sections {
            snap.appendSections([s.id])
            newSections[s.id] = s
            let ids = s.rows.compactMap { r -> String? in
                let key = s.id + "/" + r.id
                guard seen.insert(key).inserted else { return nil }
                newRows[key] = r
                return key
            }
            snap.appendItems(ids, toSection: s.id)
        }
        let old = dataSource.snapshot()
        let changed = newRows.compactMap { k, r in old.indexOfItem(k) != nil && lastSignatures[k] != r.signature ? k : nil }
        let headersChanged = sections.contains { n in sectionsById[n.id].map { o in o.header != n.header || o.footer != n.footer } ?? false }
        sectionsById = newSections
        rowsById = newRows
        lastSignatures = newRows.mapValues(\.signature)
        if !changed.isEmpty { snap.reconfigureItems(changed) }
        if headersChanged { snap.reloadSections(sections.map(\.id).filter { old.indexOfSection($0) != nil }) }
        let animate = animated && view.window != nil && !old.itemIdentifiers.isEmpty
        dataSource.apply(snap, animatingDifferences: animate)
    }

    private func configure(_ cell: UICollectionViewListCell, id: String) {
        guard let row = rowsById[id] else { return }
        cell.accessories = []
        cell.backgroundConfiguration = .listCell()
        cell.contentView.subviews.filter { $0.tag == 4242 }.forEach { $0.removeFromSuperview() }
        var c = UIListContentConfiguration.valueCell()
        c.image = row.icon.map(Self.badge)
        c.imageProperties.maximumSize = CGSize(width: 29, height: 29)
        switch row.kind {
        case let .value(title, detail):
            c.text = title; c.secondaryText = detail
        case let .button(title, destructive, enabled, _):
            c = .cell()
            c.image = row.icon.map(Self.badge)
            c.imageProperties.maximumSize = CGSize(width: 29, height: 29)
            c.text = title
            c.textProperties.color = !enabled ? .tertiaryLabel : (destructive ? .systemRed : .tintColor)
        case let .navigation(title, detail, _):
            c.text = title; c.secondaryText = detail
            cell.accessories = [.disclosureIndicator()]
        case let .expander(title, detail, expanded, _):
            c = .subtitleCell()
            c.image = row.icon.map(Self.badge)
            c.imageProperties.maximumSize = CGSize(width: 29, height: 29)
            c.text = title; c.secondaryText = detail
            c.secondaryTextProperties.color = .secondaryLabel
            let arrow = UIImageView(image: UIImage(systemName: expanded ? "chevron.up" : "chevron.down"))
            arrow.tintColor = .tertiaryLabel
            cell.accessories = [.customView(configuration: .init(customView: arrow, placement: .trailing()))]
        case let .toggle(title, on, enabled, changed):
            c.text = title
            if !enabled { c.textProperties.color = .secondaryLabel }
            let sw = UISwitch()
            sw.isOn = on
            sw.isEnabled = enabled
            sw.addAction(UIAction { _ in changed(sw.isOn) }, for: .valueChanged)
            cell.accessories = [.customView(configuration: .init(customView: sw, placement: .trailing()))]
        case let .menu(title, value, menu):
            c.text = title
            var bc = UIButton.Configuration.plain()
            bc.title = value
            bc.indicator = .popup
            bc.baseForegroundColor = .secondaryLabel
            bc.contentInsets = .init(top: 6, leading: 8, bottom: 6, trailing: 0)
            bc.titleLineBreakMode = .byTruncatingMiddle
            let b = UIButton(configuration: bc)
            b.menu = menu()
            b.showsMenuAsPrimaryAction = true
            b.accessibilityIdentifier = id   // "section/row"
            b.accessibilityLabel = title
            b.accessibilityValue = value
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.accessories = [.customView(configuration: .init(customView: b, placement: .trailing(), reservedLayoutWidth: .actual, maintainsFixedSize: false))]
        case let .stepper(title, value, range, step, format, changed):
            // Own layout: icon · title · flexible space · value · stepper, so nothing overlaps.
            let icon = UIImageView(image: row.icon.map(Self.badge))
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let t = UILabel()
            t.text = title
            t.font = .preferredFont(forTextStyle: .body)
            let v = UILabel()
            v.text = format(value)
            v.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
            v.textColor = .secondaryLabel
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            let st = UIStepper()
            st.minimumValue = range.lowerBound; st.maximumValue = range.upperBound; st.stepValue = step; st.value = value
            st.setContentCompressionResistancePriority(.required, for: .horizontal)
            st.addAction(UIAction { _ in changed(st.value); v.text = format(st.value) }, for: .valueChanged)
            let row = UIStackView(arrangedSubviews: (row.icon == nil ? [] : [icon]) + [t, UIView(), v, st])
            row.spacing = 12
            row.alignment = .center
            row.setCustomSpacing(16, after: icon)
            cell.contentConfiguration = nil
            let host = UIView()
            host.tag = 4242
            host.translatesAutoresizingMaskIntoConstraints = false
            row.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(row)
            cell.contentView.addSubview(host)
            let m = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: m.topAnchor), host.bottomAnchor.constraint(equalTo: m.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: m.leadingAnchor), host.trailingAnchor.constraint(equalTo: m.trailingAnchor),
                row.topAnchor.constraint(equalTo: host.topAnchor), row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                row.leadingAnchor.constraint(equalTo: host.leadingAnchor), row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                icon.widthAnchor.constraint(equalToConstant: 29), icon.heightAnchor.constraint(equalToConstant: 29),
            ])
            return
        case let .custom(v), let .banner(v):
            cell.contentConfiguration = nil
            if case .banner = row.kind { cell.backgroundConfiguration = .clear() }
            v.removeFromSuperview()
            let host = UIView()
            host.tag = 4242
            host.translatesAutoresizingMaskIntoConstraints = false
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
            cell.contentView.addSubview(host)
            let m = cell.contentView.layoutMarginsGuide
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: m.topAnchor), host.bottomAnchor.constraint(equalTo: m.bottomAnchor),
                host.leadingAnchor.constraint(equalTo: m.leadingAnchor), host.trailingAnchor.constraint(equalTo: m.trailingAnchor),
                v.topAnchor.constraint(equalTo: host.topAnchor), v.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: host.leadingAnchor), v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            return
        }
        cell.contentConfiguration = c
    }

    func collectionView(_ cv: UICollectionView, shouldHighlightItemAt ip: IndexPath) -> Bool {
        guard let id = dataSource.itemIdentifier(for: ip), let r = rowsById[id] else { return false }
        switch r.kind { case .button(_, _, let enabled, _): return enabled; case .navigation, .expander: return true; default: return false }
    }

    /// The row that was just tapped, in this page's coordinates: a sheet opened by the tap (shown as
    /// a bubble on newer systems) points at it instead of at the middle of the page.
    private(set) var tappedRowRect: CGRect?

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        tappedRowRect = cv.cellForItem(at: ip).map { $0.convert($0.bounds, to: view) }
        guard let id = dataSource.itemIdentifier(for: ip), let r = rowsById[id] else { return }
        switch r.kind {
        case let .button(_, _, enabled, action): if enabled { UISelectionFeedbackGenerator().selectionChanged(); action() }
        case let .navigation(_, _, action): action()
        case let .expander(_, _, _, action): action()
        default: break
        }
    }

    // MARK: Settings-style icon badges

    private static var badgeCache: [Icon: UIImage] = [:]
    static func badge(_ icon: Icon) -> UIImage {
        if icon.symbol.hasPrefix("mascot:") { return Mascot.icon(String(icon.symbol.dropFirst(7)), side: 29) }
        if let i = badgeCache[icon] { return i }
        let size = CGSize(width: 29, height: 29)
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            let r = CGRect(origin: .zero, size: size)
            let p = UIBezierPath(roundedRect: r, cornerRadius: 7)
            let top = icon.color.withAlphaComponent(1), bottom = icon.color.adjusted(by: -0.12)
            p.addClip()
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: [0, 1])!
            UIGraphicsGetCurrentContext()?.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            let sym = UIImage(systemName: icon.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))?
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            if let sym {
                let s = sym.size
                sym.draw(in: CGRect(x: (size.width - s.width) / 2, y: (size.height - s.height) / 2, width: s.width, height: s.height))
            }
        }
        badgeCache[icon] = img
        return img
    }

    // MARK: Helpers

    func alert(_ title: String, _ message: String? = nil) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
        present(a, animated: true)
    }

    /// Runs `work` off the main thread with a spinner overlay, then reports on the main thread.
    /// Runs `work` off the main thread under a spinner. `progress` (polled twice a second) shows
    /// a live line under the title; `cancel` adds a Cancel button.
    func runBusy<T>(_ title: String, progress: (() -> String?)? = nil, cancel: (() -> Void)? = nil, _ work: @escaping () throws -> T, done: @escaping (T) -> Void) {
        let hud = BusyOverlay(title: title)
        hud.onCancel = cancel
        hud.show(in: view.window ?? navigationController?.view.window ?? view)
        // Live progress of imports (folders / media) under the spinner.
        let obs = NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { if progress == nil { hud.detail = ActivityCenter.shared.activities.first { $0.kind == .importing }?.detail } }
        }
        let timer = progress.map { p in Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { hud.detail = p() } } }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try work() }
            DispatchQueue.main.async {
                timer?.invalidate()
                NotificationCenter.default.removeObserver(obs)
                hud.dismiss {
                    switch r {
                    case .success(let v): done(v)
                    case .failure(let e): AppLog.error("ui", L("form.actionFailed", title, e.localizedDescription)); self.alert(L("activity.failed"), e.localizedDescription)
                    }
                }
            }
        }
    }
}

/// Blurred card with a spinner, used while short tasks (import/export) run.
final class BusyOverlay: UIView {
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let detailLabel = UILabel()
    /// Optional progress line under the title.
    var detail: String? { didSet { detailLabel.text = detail; detailLabel.isHidden = detail == nil } }
    /// Shows a Cancel button when set.
    var onCancel: (() -> Void)? { didSet { cancelButton.isHidden = onCancel == nil } }
    private let cancelButton = UIButton(type: .system)
    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.15)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        let spin = UIActivityIndicatorView(style: .large)
        spin.startAnimating()
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .headline)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        detailLabel.isHidden = true
        detailLabel.accessibilityIdentifier = "busyDetail"
        cancelButton.setTitle(L("common.cancel"), for: .normal)
        cancelButton.isHidden = true
        cancelButton.accessibilityIdentifier = "busyCancel"
        cancelButton.addAction(UIAction { [weak self] _ in
            self?.onCancel?(); self?.cancelButton.isEnabled = false; self?.cancelButton.setTitle(L("share.cancelling"), for: .normal) }, for: .touchUpInside)
        let st = UIStackView(arrangedSubviews: [spin, label, detailLabel, cancelButton])
        st.axis = .vertical; st.spacing = 14; st.alignment = .center
        st.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(st)
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            st.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 26), st.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -22),
            st.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 28), st.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -28),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(in host: UIView) {
        frame = host.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        alpha = 0
        card.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
        host.addSubview(self)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.5) {
            self.alpha = 1; self.card.transform = .identity
        }
    }

    func dismiss(_ done: @escaping () -> Void) {
        UIView.animate(withDuration: 0.2, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: { self.alpha = 0; self.card.transform = CGAffineTransform(scaleX: 0.92, y: 0.92) }) { _ in
            self.removeFromSuperview(); done()
        }
    }
}

extension UIColor {
    func adjusted(by amount: CGFloat) -> UIColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return self }
        return UIColor(hue: h, saturation: s, brightness: max(0, min(1, b + amount)), alpha: a)
    }
}

/// Multi-line text input with a placeholder, kept stable by its owner across form updates.
final class PlaceholderTextView: UITextView, UITextViewDelegate {
    var onChange: ((String) -> Void)?
    private let placeholderLabel = UILabel()

    init(placeholder: String) {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        backgroundColor = .clear
        autocapitalizationType = .none
        autocorrectionType = .no
        delegate = self
        isScrollEnabled = false
        textContainerInset = .init(top: 6, left: 0, bottom: 6, right: 0)
        textContainer.lineFragmentPadding = 0
        placeholderLabel.text = placeholder
        placeholderLabel.font = font
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholderLabel)
        NSLayoutConstraint.activate([placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                                     placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     placeholderLabel.widthAnchor.constraint(equalTo: widthAnchor),
                                     heightAnchor.constraint(greaterThanOrEqualToConstant: 84)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var text: String! { didSet { placeholderLabel.isHidden = !(text ?? "").isEmpty } }
    func textViewDidChange(_ tv: UITextView) { placeholderLabel.isHidden = !tv.text.isEmpty; onChange?(tv.text) }
}
