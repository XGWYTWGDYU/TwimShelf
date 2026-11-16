import UIKit

/// Shows where each tag of a media came from: you, AI (and which models), or both.
final class TagSourcesViewController: UITableViewController {
    private let item: FeedItem

    init(item: FeedItem) {
        self.item = item
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("tag.sources.title")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }

    override func tableView(_ tv: UITableView, numberOfRowsInSection s: Int) -> Int { item.tags.count }
    override func tableView(_ tv: UITableView, titleForFooterInSection s: Int) -> String? {
        L("tag.sources.legend")
    }

    override func tableView(_ tv: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let t = item.tags[ip.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var c = UIListContentConfiguration.subtitleCell()
        c.text = t.label
        let who = t.isUser && t.isAI ? L("tag.source.both") : (t.isAI ? "AI" : L("tag.source.me"))
        let models = t.models.map { ModelStore.shared.displayName($0) }
        c.secondaryText = models.isEmpty ? who : "\(who) · \(models.joined(separator: "、"))"
        c.secondaryTextProperties.color = .secondaryLabel
        c.image = UIImage(systemName: t.isAI ? (t.isUser ? "checkmark.seal.fill" : "sparkles") : "person.fill")
        c.imageProperties.tintColor = TagChip.color(t)
        cell.contentConfiguration = c
        cell.selectionStyle = .none
        return cell
    }
}
