import UIKit

// MARK: - Tabs inside the home bar

final class HomeTabItem: UIControl {
    private let symbol: String
    private let tabID: String
    private let icon = UIImageView()
    private let label = UILabel()

    init(title: String, symbol: String, id: String) {
        self.symbol = symbol
        tabID = id
        super.init(frame: .zero)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = .init(pointSize: 17, weight: .medium)
        label.text = title
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.adjustsFontForContentSizeCategory = false
        let st = UIStackView(arrangedSubviews: [icon, label])
        st.axis = .vertical
        st.alignment = .center
        st.spacing = 2
        st.isUserInteractionEnabled = false
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        NSLayoutConstraint.activate([
            st.centerXAnchor.constraint(equalTo: centerXAnchor), st.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 50), widthAnchor.constraint(greaterThanOrEqualTo: st.widthAnchor, constant: 14),
            heightAnchor.constraint(equalToConstant: 44), icon.heightAnchor.constraint(equalToConstant: 22),
        ])
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = id
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isSelected: Bool { didSet { update() } }
    override var isHighlighted: Bool { didSet { UIView.animate(withDuration: 0.12, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) { self.alpha = self.isHighlighted ? 0.55 : 1 } } }

    private func update() {
        let color: UIColor = isSelected ? .tintColor : .secondaryLabel
        if Mascot.isOn {
            icon.image = Mascot.icon(tabID == "tab-browse" ? "home" : "folder", side: 28)
        } else {
            icon.image = UIImage(systemName: isSelected ? symbol + ".fill" : symbol) ?? UIImage(systemName: symbol)
        }
        icon.tintColor = color
        label.textColor = color
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
    }
}

// MARK: - Folders page

/// The L("place.folders") tab, laid out like the Photos app's Collections: the folders as large covers in
/// a sideways-scrolling shelf (two rows once there are more than four), the media types, and a
/// list of the other collections (loose media, unreviewed, damaged, bin).
final class FoldersViewController: UIViewController, UICollectionViewDelegate {
    enum Section: Int { case folders, kinds, more }
    enum More: String { case loose, album, unreviewed, reviewed, bad, trash }
    enum Item: Hashable {
        case folder(FolderOverview.Folder)
        case newFolder
        case empty
        case kind(MediaKind, Int)
        case more(More, String?)
    }

    /// Beside a sidebar the media kinds and the other collections are places of their own there,
    /// so this page lists only the folders (as the Mac's 文件夹 page).
    var foldersOnly = false
    /// L("grid.revealMedia"): the home shows 浏览 with this filter.
    var onShowInBrowse: ((FeedFilter) -> Void)?
    /// "在浏览中查看帖子" from a grid's long-press menu: the post of that media in 浏览.
    var onRevealPost: ((FeedItem) -> Void)?
    private var overview: FolderOverview?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var observers: [NSObjectProtocol] = []
    private var loading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("place.folders")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), primaryAction: UIAction { [weak self] _ in self?.createFolder() })
        add.accessibilityLabel = L("common.newFolder")
        add.accessibilityIdentifier = "newFolder"
        navigationItem.rightBarButtonItem = add
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "foldersPage"
        view.addSubview(collectionView)
        configureDataSource()
        let nc = NotificationCenter.default
        observers = [Notification.Name.libraryChanged, ActivityCenter.changed].map {
            nc.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        }
        reload()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] idx, env in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: idx) else { return nil }
            let width = env.container.effectiveContentSize.width
            let side: CGFloat = width > 700 ? 28 : 20
            let header = NSCollectionLayoutBoundarySupplementaryItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
                                                                     elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
            switch section {
            case .folders:
                let n = self.dataSource.snapshot().numberOfItems(inSection: .folders)
                if self.dataSource.snapshot().itemIdentifiers(inSection: .folders).first == .empty {
                    let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120)))
                    let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(120)), subitems: [item])
                    let s = NSCollectionLayoutSection(group: group)
                    s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                    s.boundarySupplementaryItems = [header]
                    return s
                }
                // a little more than two covers per screen on a phone: the next one peeks in
                let w = width > 700 ? 190 : floor((width - side * 2 - 14) / 2.18)
                let rows = n > 4 ? 2 : 1
                let cellH = w + 46
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(cellH)))
                let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .absolute(w), heightDimension: .absolute(cellH * CGFloat(rows) + CGFloat(rows - 1) * 14)),
                                                             repeatingSubitem: item, count: rows)
                group.interItemSpacing = .fixed(14)
                let s = NSCollectionLayoutSection(group: group)
                s.orthogonalScrollingBehavior = .continuousGroupLeadingBoundary
                s.interGroupSpacing = 14
                s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                s.boundarySupplementaryItems = [header]
                return s
            case .kinds:
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(0.5), heightDimension: .absolute(76)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(76)), repeatingSubitem: item, count: 2)
                group.interItemSpacing = .fixed(12)
                let s = NSCollectionLayoutSection(group: group)
                s.contentInsets = .init(top: 4, leading: side, bottom: 24, trailing: side)
                s.boundarySupplementaryItems = [header]
                return s
            case .more:
                var cfg = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
                cfg.headerMode = .supplementary
                cfg.backgroundColor = .clear
                let s = NSCollectionLayoutSection.list(using: cfg, layoutEnvironment: env)
                // the same edges as the cards above (a list would go by the layout margins)
                s.contentInsetsReference = .safeArea
                s.contentInsets.leading = side
                s.contentInsets.trailing = side
                s.contentInsets.bottom = 24
                return s
            }
        }
    }

    private static let cardPadding = NSDirectionalEdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)

    private func configureDataSource() {
        let folderCell = UICollectionView.CellRegistration<FolderCoverCell, Item> { cell, _, item in
            switch item {
            case .folder(let f): cell.configure(f)
            case .newFolder: cell.configureNew()
            default: break
            }
        }
        let emptyCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var c = UIListContentConfiguration.subtitleCell()
            c.image = UIImage(systemName: "folder.badge.plus")
            c.imageProperties.tintColor = .systemTeal
            c.text = L("search.noFolders")
            c.secondaryText = L("folders.empty.hint")
            c.secondaryTextProperties.color = .secondaryLabel
            // padding of its own: a list cell outside a list takes the collection's margins less
            // its own position, which is nothing where the card starts at the margin
            c.directionalLayoutMargins = Self.cardPadding
            cell.contentConfiguration = c
            var bg = UIBackgroundConfiguration.listGroupedCell()
            bg.cornerRadius = 14
            cell.backgroundConfiguration = bg
        }
        let kindCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            guard case let .kind(k, n) = item else { return }
            var c = UIListContentConfiguration.subtitleCell()
            c.image = Mascot.isOn ? Mascot.icon(k == .video ? "video" : "image", side: 32) : UIImage(systemName: k == .video ? "video.fill" : "photo.fill")
            c.imageProperties.tintColor = k == .video ? .systemPink : .systemBlue
            c.text = k == .video ? L("place.videos") : L("place.photos")
            c.textProperties.font = .preferredFont(forTextStyle: .headline)
            c.secondaryText = "\(n)"
            c.secondaryTextProperties.color = .secondaryLabel
            c.directionalLayoutMargins = Self.cardPadding
            cell.contentConfiguration = c
            var bg = UIBackgroundConfiguration.listGroupedCell()
            bg.cornerRadius = 14
            cell.backgroundConfiguration = bg
            cell.accessibilityIdentifier = "kind-" + k.rawValue
        }
        let moreCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            guard case let .more(m, detail) = item else { return }
            var c = UIListContentConfiguration.valueCell()
            let (title, symbol, color) = Self.moreInfo(m)
            c.text = title
            c.secondaryText = detail
            c.image = UIImage(systemName: symbol)
            c.imageProperties.tintColor = color
            cell.contentConfiguration = c
            cell.accessories = [.disclosureIndicator()]
            cell.accessibilityIdentifier = "more-" + m.rawValue
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, ip, item in
            switch item {
            case .folder, .newFolder: cv.dequeueConfiguredReusableCell(using: folderCell, for: ip, item: item)
            case .empty: cv.dequeueConfiguredReusableCell(using: emptyCell, for: ip, item: item)
            case .kind: cv.dequeueConfiguredReusableCell(using: kindCell, for: ip, item: item)
            case .more: cv.dequeueConfiguredReusableCell(using: moreCell, for: ip, item: item)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<FoldersSectionHeader>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] v, _, ip in
            guard let self, let s = self.dataSource.sectionIdentifier(for: ip.section) else { return }
            switch s {
            case .folders:
                let n = self.overview?.folders.count ?? 0
                v.configure(title: L("folders.mine"), detail: n > 0 ? "\(n)" : nil, action: n > 4 ? L("search.kw.all.word") : nil) { [weak self] in self?.showAllFolders() }
            case .kinds: v.configure(title: L("sidebar.mediaTypes"), detail: nil, action: nil, nil)
            case .more: v.configure(title: L("grid.more"), detail: nil, action: nil, nil)
            }
            v.listInsets = s == .more
        }
        dataSource.supplementaryViewProvider = { cv, kind, ip in cv.dequeueConfiguredReusableSupplementary(using: header, for: ip) }
    }

    private static func moreInfo(_ m: More) -> (String, String, UIColor) {
        switch m {
        case .loose: (L("place.loose"), "square.dashed", .systemIndigo)
        case .album: (L("place.album"), "photo.on.rectangle", .systemTeal)
        case .unreviewed: (L("place.unreviewed"), "seal", .systemOrange)
        case .reviewed: (L("place.reviewed"), "checkmark.seal", .systemGreen)
        case .bad: (L("place.bad"), "exclamationmark.triangle", .systemRed)
        case .trash: (L("place.trash"), "trash", .systemGray)
        }
    }

    // MARK: Data

    func reload() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .userInitiated) {
            let o = Core.folderOverview()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                self.apply(o)
            }
        }
    }

    private var lastApplied: [Item] = []

    private func apply(_ o: FolderOverview?) {
        let countChanged = o?.folders.count != overview?.folders.count
        overview = o
        var snap = NSDiffableDataSourceSnapshot<Section, Item>()
        snap.appendSections(foldersOnly ? [.folders] : [.folders, .kinds, .more])
        let folders = o?.folders ?? []
        snap.appendItems(folders.isEmpty ? [.empty] : folders.map(Item.folder) + [.newFolder], toSection: .folders)
        if !foldersOnly { appendKindsAndMore(&snap, o) }
        // progress updates arrive every second: only touch the page when something changed
        guard snap.itemIdentifiers != lastApplied || countChanged else { return }
        lastApplied = snap.itemIdentifiers
        // the header shows the count (and L("search.kw.all.word")): refresh it when the number of folders changed
        if countChanged && dataSource.snapshot().numberOfSections > 0 { snap.reloadSections([.folders]) }
        finishApply(snap)
    }

    private func appendKindsAndMore(_ snap: inout NSDiffableDataSourceSnapshot<Section, Item>, _ o: FolderOverview?) {
        snap.appendItems([.kind(.photo, o?.photos ?? 0), .kind(.video, o?.videos ?? 0)], toSection: .kinds)
        let stats = ActivityCenter.shared.stats
        var more: [Item] = [.more(.loose, nil), .more(.album, nil), .more(.unreviewed, nil), .more(.reviewed, nil)]
        if LibraryPrefs.aboutExtras { more.append(.more(.bad, (stats?.bad ?? 0) > 0 ? "\(stats?.bad ?? 0)" : nil)) }
        let trashed = stats?.trashed ?? 0
        more.append(.more(.trash, trashed > 0 ? "\(trashed)" : nil))
        snap.appendItems(more, toSection: .more)
    }

    private func finishApply(_ snap: NSDiffableDataSourceSnapshot<Section, Item>) {
        dataSource.apply(snap, animatingDifferences: view.window != nil)
    }

    // MARK: Actions

    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        cv.deselectItem(at: ip, animated: true)
        guard let item = dataSource.itemIdentifier(for: ip) else { return }
        switch item {
        case .folder(let f): open(MediaGridViewController(title: f.name, filter: FeedFilter(folder: f.name), folder: f.name))
        case .newFolder, .empty: createFolder()
        case .kind(let k, _): open(MediaGridViewController(title: k == .video ? L("place.videos") : L("place.photos"), filter: FeedFilter(kind: k)))
        case .more(let m, _):
            switch m {
            case .loose: open(MediaGridViewController(title: L("place.loose"), filter: FeedFilter(looseOnly: true)))
            case .album: open(MediaGridViewController(title: L("place.album"), filter: FeedFilter(albumOnly: true)))
            case .reviewed: open(MediaGridViewController(title: L("place.reviewed"), filter: FeedFilter(review: .reviewed)))
            case .unreviewed: open(MediaGridViewController(title: L("place.unreviewed"), filter: FeedFilter(review: .unreviewed)))
            case .bad: open(MediaGridViewController(title: L("place.bad"), filter: FeedFilter(badOnly: true)))
            case .trash: open(MediaGridViewController(title: L("place.trash"), filter: FeedFilter(), bin: true))
            }
        }
    }

    private func open(_ vc: MediaGridViewController) {
        vc.onShowInBrowse = onShowInBrowse
        vc.onRevealPost = onRevealPost
        navigationController?.pushViewController(vc, animated: true)
    }

    private func showAllFolders() {
        let vc = AllFoldersViewController(folders: overview?.folders ?? [])
        vc.onOpen = { [weak self] f in self?.open(MediaGridViewController(title: f.name, filter: FeedFilter(folder: f.name), folder: f.name)) }
        navigationController?.pushViewController(vc, animated: true)
    }

    func collectionView(_ cv: UICollectionView, contextMenuConfigurationForItemsAt ips: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = ips.first, case .folder(let f)? = dataSource.itemIdentifier(for: ip) else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.folderMenu(f.name) })
    }

    func folderMenu(_ name: String) -> UIMenu {
        UIMenu(children: [
            UIAction(title: L("grid.revealMedia"), image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in self?.onShowInBrowse?(FeedFilter(folder: name)) },
            UIAction(title: L("folder.exportZip"), image: UIImage(systemName: "doc.zipper")) { [weak self] _ in self?.exportFolderZip(name) },
            UIAction(title: L("folder.renameShort"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.renameFolder(name) { _ in self?.reload() } },
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("folder.deleteEllipsis"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.confirmDeleteFolder(name) },
            ]),
        ])
    }

    private func createFolder() {
        let a = UIAlertController(title: L("common.newFolder"), message: nil, preferredStyle: .alert)
        a.addTextField { $0.placeholder = L("common.folderName"); $0.accessibilityIdentifier = "folderName" }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.create"), style: .default) { [weak self] _ in
            let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return }
            _ = try? Core.createFolder(n)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.reload()
        })
        present(a, animated: true)
    }
}

extension UIViewController {
    /// Renames a folder; a name that is already taken merges the two (asked first). `done` gets
    /// the new name.
    func renameFolder(_ name: String, done: ((String) -> Void)? = nil) {
        let a = UIAlertController(title: L("folder.rename.title"), message: nil, preferredStyle: .alert)
        a.addTextField { $0.text = name; $0.placeholder = L("common.folderName"); $0.clearButtonMode = .whileEditing }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.rename"), style: .default) { [weak self] _ in
            let new = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !new.isEmpty, new != name else { return }
            let apply = {
                do { try Core.renameFolder(name, to: new); NotificationCenter.default.post(name: .libraryChanged, object: nil); done?(new) }
                catch {
                    let e = UIAlertController(title: L("common.couldNotRename"), message: error.localizedDescription, preferredStyle: .alert)
                    e.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                    self?.present(e, animated: true)
                }
            }
            if Core.folders().contains(where: { $0.name == new }) {
                let m = UIAlertController(title: L("folder.merge.title", new), message: L("folder.merge.message", new, name, name), preferredStyle: .alert)
                m.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
                m.addAction(UIAlertAction(title: L("folder.merge"), style: .default) { _ in apply() })
                self?.present(m, animated: true)
            } else { apply() }
        })
        present(a, animated: true)
    }

    /// Deletes a folder after a confirmation (its media stay in the library).
    func confirmDeleteFolder(_ name: String, done: (() -> Void)? = nil) {
        let a = UIAlertController(title: L("folder.delete.title", name), message: L("folder.delete.message"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("folder.delete.confirm"), style: .destructive) { _ in
            try? Core.deleteFolder(name)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            done?()
        })
        present(a, animated: true)
    }

    /// Exports one folder's media as a plain zip (readable without this app) and offers to share it.
    func exportFolderZip(_ name: String) {
        exportAndShare(fileName: name.replacingOccurrences(of: "/", with: "_") + ".zip") { out in
            try Core.exportMedia(Core.mediaIds(inFolder: name), options: ExportOptions(tags: false, folders: false, mediaOnly: true), to: out)
        }
    }

    /// Runs an export into a temporary file under a busy overlay, then offers the file for
    /// sharing; anything left out is said first, with each media's reason.
    func exportAndShare(fileName: String, _ work: @escaping (URL) throws -> ExportReport) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(fileName)
        let hud = BusyOverlay(title: L("export.runningShort"))
        hud.onCancel = { Core.cancelExport() }
        let host: UIView = view.window ?? view
        hud.show(in: host)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                if let p = Core.exportStatus(), p.total > 0 { hud.detail = L("export.progress", p.done, p.total) }
            }
        }
        Task.detached(priority: .userInitiated) {
            let r = Result { try work(out) }
            await MainActor.run {
                timer.invalidate()
                hud.dismiss { [weak self] in
                    guard let self else { return }
                    switch r {
                    case .success(let rep):
                        let share = {
                            let sheet = UIActivityViewController(activityItems: [out], applicationActivities: nil)
                            sheet.popoverPresentationController?.sourceView = self.view
                            sheet.popoverPresentationController?.sourceRect = CGRect(x: self.view.bounds.midX, y: self.view.bounds.midY, width: 1, height: 1)
                            sheet.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: dir) }
                            self.present(sheet, animated: true)
                        }
                        guard !rep.skippedText.isEmpty else { return share() }
                        let a = UIAlertController(title: L("export.doneSome", rep.media), message: rep.skippedText, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel) { _ in try? FileManager.default.removeItem(at: dir) })
                        a.addAction(UIAlertAction(title: L("export.shareAnyway"), style: .default) { _ in share() })
                        self.present(a, animated: true)
                    case .failure(let e):
                        try? FileManager.default.removeItem(at: dir)
                        let a = UIAlertController(title: L("export.failed"), message: e.localizedDescription, preferredStyle: .alert)
                        a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                        self.present(a, animated: true)
                    }
                }
            }
        }
    }
}

/// Section title in the Photos style: bold title, a count, and an optional L("search.kw.all.word") button.
final class FoldersSectionHeader: UICollectionReusableView {
    private let title = UILabel()
    private let detail = UILabel()
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?
    private var leading: NSLayoutConstraint!
    /// The list section is inset by the list itself: its title lines up with the rows' text.
    var listInsets = false { didSet { leading.constant = listInsets ? 4 : 0 } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: 22, weight: .bold))
        title.adjustsFontForContentSizeCategory = true
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: "chevron.forward")
        cfg.imagePlacement = .trailing
        cfg.imagePadding = 4
        cfg.preferredSymbolConfigurationForImage = .init(pointSize: 13, weight: .semibold)
        cfg.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 0)
        button.configuration = cfg
        button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .touchUpInside)
        button.accessibilityIdentifier = "allFolders"
        let st = UIStackView(arrangedSubviews: [title, detail, UIView(), button])
        st.spacing = 8
        st.alignment = .firstBaseline
        st.translatesAutoresizingMaskIntoConstraints = false
        addSubview(st)
        leading = st.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            st.topAnchor.constraint(equalTo: topAnchor, constant: 6), st.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            leading, st.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title t: String, detail d: String?, action a: String?, _ act: (() -> Void)?) {
        title.text = t
        detail.text = d
        detail.isHidden = d == nil
        button.configuration?.title = a
        button.isHidden = a == nil
        action = act
        accessibilityElements = [title, button]
    }
}

/// A folder as a large rounded cover with its name and count below (or the L("common.newFolder") tile).
final class FolderCoverCell: UICollectionViewCell {
    private let cover = UIImageView()
    private let placeholder = UIImageView()
    private let videoBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private let name = UILabel()
    private let count = UILabel()
    private let dashed = CAShapeLayer()
    private var token: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.contentMode = .scaleAspectFill
        cover.clipsToBounds = true
        cover.layer.cornerRadius = 12
        cover.layer.cornerCurve = .continuous
        cover.backgroundColor = .tertiarySystemFill
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = .init(pointSize: 34, weight: .regular)
        placeholder.tintColor = .tertiaryLabel
        videoBadge.tintColor = .white
        videoBadge.preferredSymbolConfiguration = .init(pointSize: 12, weight: .bold)
        videoBadge.layer.shadowOpacity = 0.4
        videoBadge.layer.shadowRadius = 2
        videoBadge.layer.shadowOffset = .zero
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.adjustsFontForContentSizeCategory = true
        count.font = .preferredFont(forTextStyle: .footnote)
        count.textColor = .secondaryLabel
        dashed.fillColor = nil
        dashed.strokeColor = UIColor.tertiaryLabel.cgColor
        dashed.lineDashPattern = [6, 4]
        dashed.lineWidth = 1.5
        cover.layer.addSublayer(dashed)
        for v in [cover, placeholder, videoBadge, name, count] { v.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(v) }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor),
            placeholder.centerXAnchor.constraint(equalTo: cover.centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            videoBadge.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 8), videoBadge.bottomAnchor.constraint(equalTo: cover.bottomAnchor, constant: -8),
            name.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 6),
            name.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), name.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            count.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
            count.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), count.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        dashed.frame = cover.bounds
        dashed.path = UIBezierPath(roundedRect: cover.bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 12).cgPath
    }

    private var imageRequest: MediaLoader.Token?

    override func prepareForReuse() {
        super.prepareForReuse()
        MediaLoader.shared.cancel(imageRequest); imageRequest = nil
        token = nil
        cover.image = nil
    }

    func configure(_ f: FolderOverview.Folder) {
        MediaLoader.shared.cancel(imageRequest); imageRequest = nil
        name.text = f.name
        count.text = f.videos > 0 && f.videos < f.count ? L("folders.cell.detail", f.count, f.videos) : "\(f.count)"
        dashed.isHidden = true
        placeholder.image = UIImage(systemName: "folder")
        placeholder.isHidden = false
        videoBadge.isHidden = true
        cover.backgroundColor = .tertiarySystemFill
        accessibilityLabel = L("folders.cell.spoken", f.name, f.count)
        accessibilityIdentifier = "folder-" + f.name
        token = f.coverPath
        guard let path = f.coverPath else { return }
        let px = max(bounds.width, 180) * traitCollection.displayScale
        imageRequest = MediaLoader.shared.load(path: path, isVideo: f.coverVideo, maxPixel: px) { [weak self] img in
            guard let self, self.token == path, let img else { return }
            self.cover.image = img
            self.placeholder.isHidden = true
            self.videoBadge.isHidden = !f.coverVideo
        }
    }

    func configureNew() {
        MediaLoader.shared.cancel(imageRequest); imageRequest = nil
        token = nil
        cover.image = nil
        cover.backgroundColor = .clear
        dashed.isHidden = false
        placeholder.image = UIImage(systemName: "plus")
        placeholder.isHidden = false
        videoBadge.isHidden = true
        name.text = L("common.newFolder")
        count.text = " "
        accessibilityLabel = L("common.newFolder")
        accessibilityIdentifier = "newFolderTile"
    }
}

/// L("search.kw.all.word"): every folder in a two-column grid (Photos' "See All" for albums).
final class AllFoldersViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    var onOpen: ((FolderOverview.Folder) -> Void)?
    private var folders: [FolderOverview.Folder]
    private var collectionView: UICollectionView!

    init(folders: [FolderOverview.Folder]) { self.folders = folders; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("folders.all")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground
        let layout = UICollectionViewCompositionalLayout { _, env in
            let width = env.container.effectiveContentSize.width
            let columns = max(2, Int(width / 220))
            let side: CGFloat = 20, gap: CGFloat = 16
            let w = floor((width - side * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns))
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .absolute(w), heightDimension: .absolute(w + 46)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(w + 46)), repeatingSubitem: item, count: columns)
            group.interItemSpacing = .fixed(gap)
            let s = NSCollectionLayoutSection(group: group)
            s.interGroupSpacing = 18
            s.contentInsets = .init(top: 12, leading: side, bottom: 24, trailing: side)
            return s
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FolderCoverCell.self, forCellWithReuseIdentifier: "f")
        view.addSubview(collectionView)
    }

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { folders.count }
    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let c = cv.dequeueReusableCell(withReuseIdentifier: "f", for: ip) as! FolderCoverCell
        c.configure(folders[ip.item])
        return c
    }
    func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) { onOpen?(folders[ip.item]) }
}
