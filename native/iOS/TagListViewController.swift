import UIKit

/// Every tag in the library with the number of media it is on (in total, added or endorsed by
/// you, from AI). Tap or long-press: show only this tag on the home screen, search it, put all
/// its media into a folder, rename it, or delete it. Tags whose media are all gone are not listed.
final class TagListViewController: UITableViewController, UISearchResultsUpdating {
    private var all: [TagCount] = []
    private var shown: [TagCount] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.tags")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "t")
        tableView.accessibilityIdentifier = "tagList"
        let sc = UISearchController(searchResultsController: nil)
        sc.searchResultsUpdater = self
        sc.obscuresBackgroundDuringPresentation = false
        sc.searchBar.placeholder = L("tags.filter")
        navigationItem.searchController = sc
        navigationItem.hidesSearchBarWhenScrolling = false
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                UIAction(title: L("tags.deleteAIEllipsis"), image: UIImage(systemName: "sparkles"), attributes: .destructive) { [weak self] _ in self?.confirmRemoveAI() },
            ]),
        ]))
        more.accessibilityLabel = L("grid.more")
        more.accessibilityIdentifier = "tagListMore"
        navigationItem.rightBarButtonItem = more
        load()
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = Core.allTags()
            DispatchQueue.main.async { self.all = tags; self.filter(self.navigationItem.searchController?.searchBar.text ?? "") }
        }
    }

    func updateSearchResults(for sc: UISearchController) { filter(sc.searchBar.text ?? "") }
    private func filter(_ q: String) {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        shown = k.isEmpty ? all : all.filter { $0.label.contains(k) }
        tableView.reloadData()
    }

    override func tableView(_ tv: UITableView, titleForHeaderInSection section: Int) -> String? {
        all.isEmpty ? nil : L("tags.total.ios", all.count)
    }
    override func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int { shown.count }
    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = tv.dequeueReusableCell(withIdentifier: "t", for: ip)
        let t = shown[ip.row]
        var cfg = UIListContentConfiguration.valueCell()
        cfg.text = t.label
        cfg.secondaryText = L("search.row.mediaCount", t.count)
        cfg.image = UIImage(systemName: t.user > 0 ? "tag.fill" : "sparkles")
        cfg.imageProperties.tintColor = t.user > 0 ? .systemBlue : .systemPurple
        var detail = UIListContentConfiguration.subtitleCell()
        detail.text = t.label
        detail.secondaryText = L("tags.cell.detail", t.count, t.user, t.ai)
        detail.secondaryTextProperties.color = .secondaryLabel
        detail.image = cfg.image
        detail.imageProperties.tintColor = cfg.imageProperties.tintColor
        c.contentConfiguration = detail
        c.accessibilityIdentifier = "tagRow-\(t.label)"
        c.accessoryType = .disclosureIndicator
        return c
    }

    override func tableView(_ tv: UITableView, didSelectRowAt ip: IndexPath) {
        tv.deselectRow(at: ip, animated: true)
        showOnHome(shown[ip.row].label)
    }

    override func tableView(_ tv: UITableView, contextMenuConfigurationForRowAt ip: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let t = shown[ip.row]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(title: L("tags.menu.title", t.label, t.count), children: [
                UIAction(title: L("tags.onlyOnHome"), image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { _ in self?.showOnHome(t.label) },
                UIAction(title: L("tags.allToFolderShort"), image: UIImage(systemName: "folder.badge.plus")) { _ in self?.toFolder(t) },
                UIAction(title: L("tags.renameOrMerge"), image: UIImage(systemName: "pencil")) { _ in self?.rename(t) },
                UIMenu(options: .displayInline, children: [
                    UIAction(title: L("tags.deleteEllipsis"), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.confirmDelete(t) },
                ]),
            ])
        })
    }

    /// Back to the home screen, showing only media with this tag.
    private func showOnHome(_ label: String) {
        NotificationCenter.default.post(name: FeedViewController.showLabelNote, object: label)
        navigationController?.popToRootViewController(animated: true)
        navigationController?.presentingViewController?.dismiss(animated: true)
    }

    private func toFolder(_ t: TagCount) {
        let a = UIAlertController(title: L("tags.toFolder.title", t.label, t.count), message: nil, preferredStyle: .actionSheet)
        let put: (String) -> Void = { [weak self] name in
            do {
                let n = try Core.tagToFolder(t.label, folder: name)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                let ok = UIAlertController(title: L("tags.toFolder.done", name), message: n == t.count ? L("search.row.mediaCount", n) : L("tags.toFolder.partly", n), preferredStyle: .alert)
                ok.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                self?.present(ok, animated: true)
            } catch { AppLog.error("tags", L("tags.toFolder.failed", error.localizedDescription)) }
        }
        for f in Core.folders() { a.addAction(UIAlertAction(title: L("format.nameDetail", f.name, f.count), style: .default) { _ in put(f.name) }) }
        a.addAction(UIAlertAction(title: L("common.newFolderEllipsis"), style: .default) { [weak self] _ in
            let n = UIAlertController(title: L("common.newFolder"), message: nil, preferredStyle: .alert)
            n.addTextField { $0.placeholder = L("common.folderName"); $0.text = t.label }
            n.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
            n.addAction(UIAlertAction(title: L("folder.createAndPut"), style: .default) { _ in
                let name = (n.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { put(name) }
            })
            self?.present(n, animated: true)
        })
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.popoverPresentationController?.sourceView = view
        a.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(a, animated: true)
    }

    /// Every AI tag goes; tags I added or endorsed stay.
    private func confirmRemoveAI() {
        let n = all.reduce(0) { $0 + $1.ai }
        guard n > 0 else {
            let a = UIAlertController(title: L("tags.noAI"), message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: L("common.ok"), style: .default))
            return present(a, animated: true)
        }
        let a = UIAlertController(title: L("tags.deleteAI.title", n), message: L("tags.deleteAI.message"), preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("tags.deleteAI.confirm"), style: .destructive) { [weak self] _ in
            do {
                try Core.removeAITags()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                ActivityCenter.shared.refreshStats()
                self?.load()
            } catch {
                AppLog.error("tags", L("tags.deleteAI.failedDetail", error.localizedDescription))
                let e = UIAlertController(title: L("tags.deleteAI.failed"), message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }

    /// The tag goes from every media; the media stay.
    private func confirmDelete(_ t: TagCount) {
        let a = UIAlertController(title: L("tags.delete.title", t.label),
                                  message: L("tags.delete.message", t.count),
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("card.menu.deleteTag"), style: .destructive) { [weak self] _ in
            do {
                try Core.deleteTag(t.label)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                ActivityCenter.shared.refreshStats()
                self?.load()
            } catch {
                AppLog.error("tags", L("tags.delete.failedDetail", error.localizedDescription))
                let e = UIAlertController(title: L("tags.delete.failed"), message: error.localizedDescription, preferredStyle: .alert)
                e.addAction(UIAlertAction(title: L("common.ok"), style: .default))
                self?.present(e, animated: true)
            }
        })
        present(a, animated: true)
    }

    private func rename(_ t: TagCount) {
        let a = UIAlertController(title: L("tags.rename.title", t.label), message: L("tags.rename.message"), preferredStyle: .alert)
        a.addTextField { $0.text = t.label }
        a.addAction(UIAlertAction(title: L("common.cancel"), style: .cancel))
        a.addAction(UIAlertAction(title: L("common.rename"), style: .default) { [weak self] _ in
            let to = (a.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces)
            guard !to.isEmpty, to != t.label else { return }
            _ = try? Core.renameTag(t.label, to: to)
            NotificationCenter.default.post(name: .libraryChanged, object: nil)
            self?.load()
        })
        present(a, animated: true)
    }
}
