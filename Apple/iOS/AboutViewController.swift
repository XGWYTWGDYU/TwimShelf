import UIKit

/// 关于: the app's icon, name and version. Ten taps on the icon bring out what is only for looking
/// into a problem (checking the media, the problem log, exporting the diagnostics) until ten more
/// put it away.
final class AboutViewController: FormViewController {
    private weak var settings: SettingsViewController?
    private var taps = 0
    private var extras = LibraryPrefs.aboutExtras
    private let header = UIStackView()
    private var observer: NSObjectProtocol?

    init(settings: SettingsViewController) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("settings.about")
        navigationItem.largeTitleDisplayMode = .never
        let image = UIImageView(image: UIImage(named: "AppIconPreview") ?? Self.appIcon)
        image.layer.cornerRadius = 24
        image.layer.cornerCurve = .continuous
        image.clipsToBounds = true
        image.translatesAutoresizingMaskIntoConstraints = false
        // the shadow beside the corners that clip the picture
        let icon = UIView()
        icon.layer.shadowColor = UIColor.black.cgColor
        icon.layer.shadowOpacity = 0.16
        icon.layer.shadowRadius = 18
        icon.layer.shadowOffset = CGSize(width: 0, height: 8)
        icon.addSubview(image)
        icon.isUserInteractionEnabled = true
        icon.accessibilityIdentifier = "aboutIcon"
        icon.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(iconTapped)))
        let name = UILabel()
        name.text = L10n.appName
        name.font = UIFontMetrics(forTextStyle: .title1).scaledFont(for: .systemFont(ofSize: 28, weight: .bold))
        name.adjustsFontForContentSizeCategory = true
        let tagline = UILabel()
        tagline.text = L("about.tagline")
        tagline.font = .preferredFont(forTextStyle: .subheadline)
        tagline.adjustsFontForContentSizeCategory = true
        tagline.textColor = .secondaryLabel
        tagline.numberOfLines = 0
        tagline.textAlignment = .center
        let info = Bundle.main.infoDictionary ?? [:]
        let version = PaddedLabel()
        version.text = L("about.version", info["CFBundleShortVersionString"] as? String ?? "") + " · " + L("about.build", info["CFBundleVersion"] as? String ?? "")
        version.font = .preferredFont(forTextStyle: .footnote)
        version.adjustsFontForContentSizeCategory = true
        version.textColor = .secondaryLabel
        version.backgroundColor = .tertiarySystemFill
        version.layer.cornerRadius = 13
        version.layer.cornerCurve = .continuous
        version.clipsToBounds = true
        version.accessibilityIdentifier = "aboutVersion"
        [icon, name, tagline, version].forEach(header.addArrangedSubview)
        header.axis = .vertical
        header.alignment = .center
        header.spacing = 6
        header.setCustomSpacing(20, after: icon)
        header.setCustomSpacing(14, after: tagline)
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 28, left: 0, bottom: 12, right: 0)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 112), icon.heightAnchor.constraint(equalToConstant: 112),
            image.topAnchor.constraint(equalTo: icon.topAnchor), image.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            image.leadingAnchor.constraint(equalTo: icon.leadingAnchor), image.trailingAnchor.constraint(equalTo: icon.trailingAnchor),
        ])
        observer = NotificationCenter.default.addObserver(forName: ActivityCenter.changed, object: nil, queue: .main) { [weak self] _ in
            if self?.extras == true { self?.build() }
        }
        build()
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// The icon the system shows for this app.
    private static var appIcon: UIImage? {
        let icons = (Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
        return ((icons?["CFBundleIconFiles"] as? [String])?.last).flatMap { UIImage(named: $0) }
    }

    @objc private func iconTapped() {
        taps += 1
        guard taps == 10 else { return }
        taps = 0
        extras.toggle()
        LibraryPrefs.aboutExtras = extras
        build()
    }

    /// The check ran and found everything in order.
    private static var checkPassed: Bool {
        guard let s = Core.integritySummary(), s.last != nil else { return false }
        return s.bad == 0 && s.unchecked == 0
    }

    private func build() {
        var s = [Section(id: "app", rows: [.banner("header", header)])]
        if extras {
            s.append(Section(id: "problems", header: L("settings.section.maintenance"), footer: L("settings.maintenance.footer"), rows: [
                Core.verifyStatus()?.running == true
                    ? .button(L("settings.stopCheck"), icon: .init("stop.fill", .systemRed), destructive: true, id: "b:verify") { Core.cancelVerify() }
                    : .button(L("settings.check"), icon: Icon("checkmark.shield.fill", .systemGreen, mascot: Self.checkPassed ? "shield" : nil), id: "b:verify") { [weak self] in
                        do { try Core.startVerify() } catch { self?.alert(L("settings.checkFailed"), error.localizedDescription) } },
                .value(L("settings.integrity"), Core.integritySummary()?.text ?? L("settings.checkUnreadable"), icon: .init("exclamationmark.triangle", .systemOrange), id: "v:bad"),
                .navigation(L("common.problemLog"), detail: L("common.items", AppLog.problemCount), icon: .init("exclamationmark.triangle.fill", .systemOrange), id: "n:problems") { [weak self] in
                    self?.navigationController?.pushViewController(ProblemsViewController(), animated: true)
                },
                .button(L("settings.exportDiagnostics"), icon: .init("stethoscope", .systemTeal), id: "b:diag") { [weak self] in self?.settings?.exportDiagnostics() },
            ]))
        }
        sections = s
        reloadForm(animated: view.window != nil)
    }
}
