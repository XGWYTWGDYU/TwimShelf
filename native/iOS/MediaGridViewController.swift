import UIKit

/// The media of one folder or collection as a square grid, like an album in Photos.
///  * With "按帖子分组" on, a post is one tile (its first media) with a count badge.
///  * Pinch to zoom between 5 / 3 / 1 columns exactly as Photos does (see `MediaGridView`).
///    The "…" menu also has 放大 / 缩小.
///  * The recycle bin is the same grid over the binned media (`bin`): 还原 and 永久删除 instead of
///    the folder and bin actions.
///  * L("common.select"): tap tiles, or drag sideways across them, to select; share, add to a folder, take
///    out of this folder, or move to the recycle bin from the toolbar.
final class MediaGridViewController: UIViewController, MediaGridViewDelegate {
    var onShowInBrowse: ((FeedFilter) -> Void)?
    /// Shows the post of a media in 浏览 (not offered in the recycle bin).
    var onRevealPost: ((FeedItem) -> Void)?
    /// A place of the sidebar: there is nothing to go back to.
    var isTopLevel = false { didSet { navigationItem.hidesBackButton = isTopLevel } }
    private let filter: FeedFilter
    private let folder: String?
    private let bin: Bool
    private var trashedAt: [String: Date] = [:]
    private var entries: [[FeedItem]] = []
    private var items: [FeedItem] = []
    private let grid = MediaGridView()
    private let emptyLabel = UILabel()
    private var observer: NSObjectProtocol?
    private let reloadWork = LatestWork()
    private var generation = 0
    private var grouped: Bool { UserDefaults.standard.object(forKey: "grouped") as? Bool ?? true }

    init(title: String, filter: FeedFilter, folder: String? = nil, bin: Bool = false) {
        self.filter = filter
        self.folder = folder
        self.bin = bin
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        // full height (it scrolls under the bars), but within the safe area at the sides: a tab
        // rail or a notch in landscape would cover its outer columns
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.delegate = self
        grid.initialLevel = UserDefaults.standard.object(forKey: "grid.level") as? Int ?? 1
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: view.topAnchor), grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
        ])
        emptyLabel.text = bin ? L("grid.trashEmpty") : L("grid.empty")
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .body)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([emptyLabel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor), emptyLabel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)])
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } }
        updateBarItems()
        reload()
        // media past the retention period leave the bin
        if bin {
            DispatchQueue.global(qos: .userInitiated).async { if Core.expireTrash() > 0 { DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil) } } }
        }
    }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if grid.selecting { setSelecting(false) }
    }

    private func reload() {
        generation += 1
        let gen = generation
        let req = FeedRequest(filter: filter)
        let bin = self.bin
        reloadWork.submit { [weak self] isCurrent in
            guard let self, isCurrent() else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> ([FeedItem], [String: Date]) in
                var dates: [String: Date] = [:]
                let items: [FeedItem]
                if bin {
                    let t = Core.trashList()
                    for i in t { dates[i.mediaId] = i.trashedAt }
                    items = t.map(\.asFeedItem)
                } else {
                    items = (try? Core.feed(req)) ?? []
                }
                return (items, dates)
            }.value
            guard isCurrent(), gen == self.generation else { return }
            self.items = result.0
            self.trashedAt = result.1
            self.rebuild()
        }
    }

    private func rebuild() {
        if grouped {
            var order: [String] = []
            var byPost: [String: [FeedItem]] = [:]
            for it in items {
                if byPost[it.postId] == nil { order.append(it.postId) }
                byPost[it.postId, default: []].append(it)
            }
            entries = order.map { byPost[$0]!.sorted { $0.ordinal < $1.ordinal } }
        } else {
            entries = items.map { [$0] }
        }
        emptyLabel.isHidden = !entries.isEmpty
        let videos = items.filter { $0.kind == .video }.count
        let photos = items.count - videos
        var parts: [String] = []
        if photos > 0 { parts.append(L("grid.photos", photos)) }
        if videos > 0 { parts.append(L("grid.videos", videos)) }
        grid.setTiles(entries.compactMap { e in e.first.map { ZoomGridTile(item: $0, count: e.count) } }, footer: parts.joined(separator: L("list.separator")))
        updateSelectionUI()
    }

    // MARK: Grid

    func mediaGrid(_ g: MediaGridView, didTap i: Int) {
        guard i < entries.count, let first = entries[i].first else { return }
        // swipe through every media of the grid, photos and videos alike, starting here
        let all = grouped ? entries.flatMap { $0 } : items
        let vc = PhotoViewController(items: all, index: all.firstIndex(of: first) ?? 0)
        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    func mediaGrid(_ g: MediaGridView, didSettleAt level: Int) {
        UserDefaults.standard.set(level, forKey: "grid.level")
        updateBarItems()
    }

    func mediaGridSelectionChanged(_ g: MediaGridView) { updateSelectionUI() }

    func mediaGrid(_ g: MediaGridView, menuFor i: Int) -> UIMenu? {
        guard i < entries.count else { return nil }
        let entry = entries[i]
        // while selecting, a long press still previews the media large; the menu only (de)selects it
        if grid.selecting, let id = entry.first?.mediaId {
            let on = grid.selected.contains(id)
            return UIMenu(children: [UIAction(title: on ? L("common.deselect") : L("common.select"), image: UIImage(systemName: on ? "circle" : "checkmark.circle")) { [weak self] _ in
                guard let self else { return }
                if on { self.grid.selected.remove(id) } else { self.grid.selected.insert(id) }
                self.updateSelectionUI()
            }])
        }
        let ids = entry.map(\.mediaId)
        var acts: [UIMenuElement] = [UIAction(title: L("common.select"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
            self?.setSelecting(true)
            if let id = entry.first?.mediaId { self?.grid.selected = [id] }
            self?.updateSelectionUI()
        }]
        if bin {
            let n = ids.count > 1 ? L("grid.countSuffix", ids.count) : ""
            var left: [UIMenuElement] = []
            if let l = daysLeft(entry) { left.append(UIAction(title: l, image: UIImage(systemName: "clock"), attributes: .disabled) { _ in }) }
            return UIMenu(children: left + acts + [
                UIAction(title: L("common.restore") + n, image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.grid.afterMenuCloses { self?.restore(ids) } },
                UIAction(title: L("common.deletePermanently") + n, image: UIImage(systemName: "trash.slash"), attributes: .destructive) { [weak self] _ in self?.confirmPurge(ids) },
            ])
        }
        // the post in 浏览, found among the cards (or the media itself, for a loose one)
        if let first = entry.first, onRevealPost != nil {
            acts.append(UIAction(title: first.isLoose ? L("grid.revealMedia") : L("grid.revealPost"), image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                self?.grid.afterMenuCloses { self?.onRevealPost?(first) }
            })
        }
        if let folder {
            acts.append(UIAction(title: L("common.removeFromFolder"), image: UIImage(systemName: "folder.badge.minus")) { [weak self] _ in
                // the grid closes the gap once the menu has flown back to the tile
                self?.grid.afterMenuCloses {
                    _ = try? Core.removeFromFolder(folder, media: ids)
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                }
            })
        }
        // "the whole post" goes by post id, so media this grid does not show (a video while only
        // photos are listed, say) go to the bin too
        let done = { UINotificationFeedbackGenerator().notificationOccurred(.success); NotificationCenter.default.post(name: .libraryChanged, object: nil) }
        if entry.count == 1 {
            acts.append(UIAction(title: L("grid.trashMedia"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.grid.afterMenuCloses { _ = try? Core.trash(media: ids); done() }
            })
        }
        if let first = entry.first, !first.isLoose, case let post = first.postId {
            acts.append(UIAction(title: L("grid.trashPost"), subtitle: L("grid.trashPost.detail"), image: UIImage(systemName: "trash.square"), attributes: .destructive) { [weak self] _ in
                self?.grid.afterMenuCloses { _ = try? Core.trash(post: post); done() }
            })
        }
        return UIMenu(children: acts)
    }

    // MARK: Recycle bin

    /// How long the media of an entry stay (the first of them to go counts).
    private func daysLeft(_ entry: [FeedItem]) -> String? {
        let keep = Core.trashKeepDays
        guard let first = entry.compactMap({ trashedAt[$0.mediaId] }).min() else { return nil }
        if keep == 0 { return L("trash.keepForever") }
        let d = Double(keep) - Date().timeIntervalSince(first) / 86_400
        return d < 1 ? L("trash.deletingSoon") : L("trash.daysLeft", Int(d.rounded(.up)))
    }

    private func restore(_ ids: [String]? = nil) {
        do {
            let snapshot = try Core.binSnapshot(media: ids)
            let result = try Core.action(.restore, snapshot: snapshot)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            ActivityCenter.shared.refreshStats()
            if grid.selecting { setSelecting(false) }
            notice(L("trash.restored", result.count))
        } catch { notice(L("trash.restoreFailed", error.localizedDescription)) }
    }

    private func confirmPurge(_ ids: [String]) { confirmBinDeletion(media: ids) }
    private func confirmEmpty() { confirmBinDeletion(media: nil) }
    private func confirmBinDeletion(media: [String]?) {
        do {
            let snapshot = try Core.binSnapshot(media: media)
            guard snapshot.count > 0 else { return }
            let a = UIAlertController(title: media == nil ? L("trash.emptyTitle") : L("trash.purgeTitle"), message: L("trash.purgeMessage", snapshot.description), preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
            a.addAction(UIAlertAction(title: L("common.deletePermanently"), style: .destructive) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try Core.action(.purge, snapshot: snapshot) }
                    DispatchQueue.main.async {
                        self?.setSelecting(false)
                        NotificationCenter.default.post(name: .libraryChanged, object: nil); ActivityCenter.shared.refreshStats()
                        switch result {
                        case .success(let r): self?.notice(L("trash.purged", r.count) + (r.count < snapshot.count ? L("trash.purged.skipped") : ""))
                        case .failure(let e): self?.notice(L("trash.purgeFailed", e.localizedDescription))
                        }
                    }
                }
            })
            present(a, animated: true)
        } catch { notice(L("trash.unreadable", error.localizedDescription)) }
    }

    /// 自动永久删除 (retention), 全部还原 and 清空回收站 in the "…" menu.
    private func binMenuItems() -> [UIMenuElement] {
        let keep = Core.trashKeepDays
        let retention = UIMenu(title: L("trash.autoDelete", LibraryPrefs.keepTitle(keep)), image: UIImage(systemName: "clock.arrow.circlepath"), children: LibraryPrefs.keepChoices.map { c in
            UIAction(title: c.days == 0 ? L("trash.never") : L("trash.after", c.title), state: c.days == keep ? .on : .off) { _ in
                Core.trashKeepDays = c.days
                DispatchQueue.global(qos: .userInitiated).async { Core.expireTrash(); DispatchQueue.main.async { NotificationCenter.default.post(name: .libraryChanged, object: nil); ActivityCenter.shared.refreshStats() } }
            }
        })
        return [
            retention,
            UIAction(title: L("trash.restoreAll"), image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in self?.restore() },
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("trash.emptyEllipsis"), image: UIImage(systemName: "trash.slash"), attributes: .destructive) { [weak self] _ in self?.confirmEmpty() },
            ]),
        ]
    }

    // MARK: Selection

    /// Selected tiles, as whole entries (a post in grouped mode).
    private var selectedMedia: [FeedItem] {
        entries.filter { grid.selected.contains($0.first?.mediaId ?? "") }.flatMap { $0 }
    }

    private func setSelecting(_ on: Bool) {
        grid.selecting = on
        // the home bar makes room for the selection toolbar
        tabBarController?.setTabBarHidden(on, animated: true)
        navigationController?.setToolbarHidden(!on, animated: true)
        updateBarItems()
        updateSelectionUI()
    }

    private func updateBarItems() {
        if grid.selecting {
            let done = UIBarButtonItem(title: L("common.cancel"), primaryAction: UIAction { [weak self] _ in self?.setSelecting(false) })
            done.accessibilityIdentifier = "gridSelectDone"
            navigationItem.rightBarButtonItems = [done]
            let all = UIBarButtonItem(title: L("grid.selectAll"), primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.grid.selectAll(self.grid.selected.count != self.entries.count)
            })
            all.accessibilityIdentifier = "gridSelectAll"
            navigationItem.leftBarButtonItem = all
            navigationItem.hidesBackButton = true
        } else {
            let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.menuItems() ?? []) }]))
            more.accessibilityLabel = L("grid.more")
            more.accessibilityIdentifier = "gridMore"
            let select = UIBarButtonItem(title: L("common.select"), primaryAction: UIAction { [weak self] _ in self?.setSelecting(true) })
            select.accessibilityIdentifier = "gridSelect"
            // the same as a pinch, one step, for when two fingers are not handy
            let zoomIn = UIBarButtonItem(image: UIImage(systemName: "plus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.grid.step(-1) })
            zoomIn.accessibilityLabel = L("grid.zoomIn")
            zoomIn.isEnabled = grid.level < grid.levelCount - 1
            let zoomOut = UIBarButtonItem(image: UIImage(systemName: "minus.magnifyingglass"), primaryAction: UIAction { [weak self] _ in self?.grid.step(1) })
            zoomOut.accessibilityLabel = L("grid.zoomOut")
            zoomOut.isEnabled = grid.level > 0
            navigationItem.rightBarButtonItems = [more, select, zoomIn, zoomOut]
            navigationItem.leftBarButtonItem = nil
            navigationItem.hidesBackButton = isTopLevel
        }
    }

    private func updateSelectionUI() {
        guard grid.selecting else { return }
        let n = selectedMedia.count
        navigationItem.leftBarButtonItem?.title = !entries.isEmpty && grid.selected.count == entries.count ? L("grid.deselectAll") : L("grid.selectAll")
        if bin {
            let restore = UIBarButtonItem(title: L("common.restore"), image: UIImage(systemName: "arrow.uturn.backward"), primaryAction: UIAction { [weak self] _ in self?.restore(self?.selectedMedia.map(\.mediaId) ?? []) })
            restore.accessibilityIdentifier = "gridRestore"
            let purge = UIBarButtonItem(title: L("common.deletePermanently"), image: UIImage(systemName: "trash.slash"), primaryAction: UIAction { [weak self] _ in self?.confirmPurge(self?.selectedMedia.map(\.mediaId) ?? []) })
            purge.accessibilityIdentifier = "gridPurge"
            purge.tintColor = .systemRed
            let label = UILabel()
            label.text = n == 0 ? L("grid.selectItems") : L("grid.selected", n)
            label.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
            label.sizeToFit()
            restore.isEnabled = n > 0
            purge.isEnabled = n > 0
            setToolbarItems([restore, .flexibleSpace(), UIBarButtonItem(customView: label), .flexibleSpace(), purge], animated: false)
            return
        }
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.shareSelected() })
        share.accessibilityLabel = L("viewer.share")
        share.accessibilityIdentifier = "gridShare"
        let addTo = UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] done in done(self?.addToFolderItems() ?? []) }]))
        addTo.accessibilityLabel = L("common.addToFolder")
        addTo.accessibilityIdentifier = "gridAddToFolder"
        let label = UILabel()
        label.text = n == 0 ? L("grid.selectItems") : L("grid.selected", n)
        label.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        label.sizeToFit()
        let count = UIBarButtonItem(customView: label)
        let trash = UIBarButtonItem(image: UIImage(systemName: "trash"), primaryAction: UIAction { [weak self] _ in self?.trashSelected() })
        trash.accessibilityLabel = L("grid.moveToTrash")
        trash.accessibilityIdentifier = "gridTrash"
        var actions: [UIBarButtonItem] = [share, addTo, trash]
        var items: [UIBarButtonItem] = [share, .flexibleSpace(), addTo]
        if folder != nil {
            let out = UIBarButtonItem(image: UIImage(systemName: "folder.badge.minus"), primaryAction: UIAction { [weak self] _ in self?.removeSelectedFromFolder() })
            out.accessibilityLabel = L("common.removeFromFolder")
            out.accessibilityIdentifier = "gridRemoveFromFolder"
            items += [.flexibleSpace(), out]
            actions.append(out)
        }
        items += [.flexibleSpace(), count, .flexibleSpace(), trash]
        for i in actions { i.isEnabled = n > 0 }
        setToolbarItems(items, animated: false)
    }

    private func shareSelected() {
        let urls = selectedMedia.map(\.fileURL).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { return }
        let sheet = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = toolbarItems?.first
        present(sheet, animated: true)
    }

    private func addToFolderItems() -> [UIMenuElement] {
        let ids = selectedMedia.map(\.mediaId)
        var acts: [UIMenuElement] = Core.folders().filter { $0.name != folder }.map { f in
            UIAction(title: f.name, image: UIImage(systemName: "folder")) { [weak self] _ in self?.add(ids, to: f.name) }
        }
        acts.append(UIAction(title: L("common.newFolderEllipsis"), image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            let a = UIAlertController(title: L("common.newFolder"), message: nil, preferredStyle: .alert)
            a.addTextField { $0.placeholder = L("common.folderName") }
            a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
            a.addAction(UIAlertAction(title: L("grid.createAndAdd"), style: .default) { _ in
                let n = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { self?.add(ids, to: n) }
            })
            self?.present(a, animated: true)
        })
        return acts
    }

    private func add(_ ids: [String], to name: String) {
        do {
            let n = try Core.addToFolder(name, media: ids)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            setSelecting(false)
            notice(n == 0 ? L("folder.allAlready", name) : L("folder.added", n, name))
        } catch { notice(L("folder.addFailed", error.localizedDescription)) }
    }

    private func removeSelectedFromFolder() {
        guard let folder else { return }
        let ids = selectedMedia.map(\.mediaId)
        _ = try? Core.removeFromFolder(folder, media: ids)
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        setSelecting(false)
        notice(L("folder.removed", ids.count, folder))
    }

    private func trashSelected() {
        let ids = selectedMedia.map(\.mediaId)
        guard !ids.isEmpty else { return }
        let a = UIAlertController(title: nil, message: L("grid.trashConfirm", ids.count), preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: L("grid.moveToTrash"), style: .destructive) { [weak self] _ in
            _ = try? Core.trash(media: ids)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.setSelecting(false)
        })
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.popoverPresentationController?.barButtonItem = toolbarItems?.last
        present(a, animated: true)
    }

    private func notice(_ text: String) {
        let a = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        present(a, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { a.dismiss(animated: true) }
    }

    // MARK: Menu

    private func menuItems() -> [UIMenuElement] {
        var acts: [UIMenuElement] = bin ? binMenuItems() : [
            UIAction(title: L("grid.revealMedia"), image: UIImage(systemName: "rectangle.stack")) { [weak self] _ in
                guard let self else { return }
                self.onShowInBrowse?(self.filter)
            },
        ]
        if let folder {
            acts.append(UIAction(title: L("folder.exportZip"), image: UIImage(systemName: "doc.zipper")) { [weak self] _ in self?.exportFolderZip(folder) })
            // renamed: back to the folders, where it shows under its new name
            acts.append(UIAction(title: L("folder.renameEllipsis"), image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.renameFolder(folder) { _ in self?.navigationController?.popViewController(animated: true) }
            })
            acts.append(UIMenu(options: .displayInline, children: [
                UIAction(title: L("folder.deleteEllipsis"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.confirmDeleteFolder(folder) { self?.navigationController?.popViewController(animated: true) }
                },
            ]))
        }
        return acts
    }
}
