import SwiftUI
import UIKit

/// Every tag in the library with the number of media it is on (in total, added or endorsed by
/// you, from AI).
///  * Wide screens (regular × regular): macOS-aligned full tag cards with inline toolbar.
///  * Narrow screens: high-density 2-column micro-tiles without per-row icons, using dot counts
///    and a bottom 3-segment proportion bar (Mine / Common / AI).
final class TagListViewController: UIViewController, UISearchResultsUpdating {
    private var searchController: UISearchController?
    private var moreButton: UIBarButtonItem?
    private let model = IOSTagsModel()
    private var showingWide: Bool?
    private var all: [TagCount] = []

    init(style: UITableView.Style = .insetGrouped) {
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var wantsWide: Bool {
        traitCollection.horizontalSizeClass == .regular && traitCollection.verticalSizeClass == .regular
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("common.tags")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        model.onShowOnHome = { [weak self] label in self?.showOnHome(label) }
        model.onToFolder = { [weak self] t in self?.toFolder(t) }
        model.onRename = { [weak self] t in self?.rename(t) }
        model.onDelete = { [weak self] t in self?.confirmDelete(t) }
        model.onDeleteAI = { [weak self] in self?.confirmRemoveAI() }

        let host = UIHostingController(rootView: IOSTagsRootView(model: model))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        updateLayoutMode()
        registerForTraitChanges([UITraitHorizontalSizeClass.self, UITraitVerticalSizeClass.self]) { (self: Self, _) in
            DispatchQueue.main.async { self.updateLayoutMode() }
        }
        load()
    }

    private func updateLayoutMode() {
        let wide = wantsWide
        guard wide != showingWide else { return }
        showingWide = wide
        model.isWide = wide

        if wide {
            navigationItem.searchController = nil
            navigationItem.rightBarButtonItem = nil
        } else {
            let sc = searchController ?? {
                let c = UISearchController(searchResultsController: nil)
                c.searchResultsUpdater = self
                c.obscuresBackgroundDuringPresentation = false
                c.searchBar.placeholder = L("tags.filter")
                searchController = c
                return c
            }()
            sc.searchBar.text = model.query
            navigationItem.searchController = sc
            navigationItem.hidesSearchBarWhenScrolling = false

            let more = moreButton ?? {
                let b = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
                    UIDeferredMenuElement.uncached { [weak self] done in
                        done([UIMenu(title: L("tags.sort"), image: UIImage(systemName: "arrow.up.arrow.down"), children: TagSort.allCases.map { s in
                            UIAction(title: s.title, state: s == TagSort.saved ? .on : .off) { _ in
                                TagSort.saved = s
                                self?.model.sort = s
                            }
                        })])
                    },
                    UIMenu(options: .displayInline, children: [
                        UIAction(title: L("tags.deleteAIEllipsis"), image: UIImage(systemName: "sparkles"), attributes: .destructive) { [weak self] _ in self?.confirmRemoveAI() },
                    ]),
                ]))
                b.accessibilityLabel = L("grid.more")
                b.accessibilityIdentifier = "tagListMore"
                moreButton = b
                return b
            }()
            navigationItem.rightBarButtonItem = more
        }
    }

    private func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let tags = Core.allTags()
            DispatchQueue.main.async {
                self.all = tags
                self.model.all = tags
                self.model.loaded = true
            }
        }
    }

    func updateSearchResults(for sc: UISearchController) {
        model.query = sc.searchBar.text ?? ""
    }

    // MARK: Actions

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

// MARK: - State & Shared Views

@MainActor
private final class IOSTagsModel: ObservableObject {
    enum Show: String, CaseIterable {
        case all, mine, ai, both
        var title: String {
            switch self {
            case .all: L("search.kw.all.word")
            case .mine: L("search.kw.mine.word")
            case .ai: L("search.kw.ai.word")
            case .both: L("search.kw.common.word")
            }
        }
    }

    @Published var all: [TagCount] = []
    @Published var query = ""
    @Published var sort = TagSort.saved { didSet { TagSort.saved = sort } }
    @Published var show = Show.all
    @Published var loaded = false
    @Published var isWide = false

    var onShowOnHome: ((String) -> Void)?
    var onToFolder: ((TagCount) -> Void)?
    var onRename: ((TagCount) -> Void)?
    var onDelete: ((TagCount) -> Void)?
    var onDeleteAI: (() -> Void)?

    /// Media with both your tag and the AI's: the two overlap by this much.
    static func common(_ t: TagCount) -> Int { max(0, t.user + t.ai - t.count) }

    var shown: [TagCount] {
        let k = query.trimmingCharacters(in: .whitespaces).lowercased()
        var v = k.isEmpty ? all : all.filter { $0.label.contains(k) }
        switch show {
        case .all: break
        case .mine: v = v.filter { $0.user > 0 }
        case .ai: v = v.filter { $0.ai > 0 }
        case .both: v = v.filter { Self.common($0) > 0 }
        }
        return sort.apply(v)
    }

    var summary: String {
        let n = shown.count
        return all.isEmpty ? "" : L("tags.total", all.count) + (n == all.count ? "" : L("tags.shown", n))
    }
}

private extension Color {
    static let iosTagMine = Color.blue
    static let iosTagAI = Color.purple
    static let iosTagBoth = Color.green
}

private struct IOSTagsRootView: View {
    @ObservedObject var model: IOSTagsModel

    var body: some View {
        if model.isWide {
            IOSTagCardsView(model: model)
        } else {
            IOSNarrowTagGridView(model: model)
        }
    }
}

private struct TagProportionBar: View {
    let tag: TagCount
    let height: CGFloat

    private var common: Int { IOSTagsModel.common(tag) }
    private var onlyMine: Int { tag.user - common }
    private var onlyAI: Int { tag.ai - common }

    var body: some View {
        GeometryReader { g in
            let total = max(tag.count, 1)
            let parts: [(Int, Color)] = [(onlyMine, .iosTagMine), (common, .iosTagBoth), (onlyAI, .iosTagAI)].filter { $0.0 > 0 }
            let gaps = CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(p.1.gradient).frame(width: max(5, (g.size.width - gaps) * CGFloat(p.0) / CGFloat(total)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Capsule().fill(.quaternary.opacity(0.5)))
    }
}

private struct TagLegendView: View {
    var compact = false
    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ForEach([(L("search.kw.mine.word"), Color.iosTagMine), (L("search.kw.common.word"), Color.iosTagBoth), ("AI", Color.iosTagAI)], id: \.0) { name, c in
                HStack(spacing: 4) {
                    Circle().fill(c).frame(width: compact ? 6 : 8, height: compact ? 6 : 8)
                    Text(name).font(compact ? .caption2 : .caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TagEmptyState: View {
    let isEmptyLibrary: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: isEmptyLibrary ? "tag" : "magnifyingglass").font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(isEmptyLibrary ? L("tags.none") : L("tags.noMatch")).font(.headline)
            Text(isEmptyLibrary ? L("tags.none.message") : L("tags.noMatch.message")).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 24)
    }
}

// MARK: - Narrow-screen 2-column micro-tiles (Plan B)

private struct IOSNarrowTagGridView: View {
    @ObservedObject var model: IOSTagsModel
    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $model.show) {
                    ForEach(IOSTagsModel.Show.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 8) {
                    if !model.summary.isEmpty {
                        Text(model.summary).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    TagLegendView(compact: true)
                }

                let tags = model.shown
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tags.isEmpty {
                    TagEmptyState(isEmptyLibrary: model.all.isEmpty)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(tags, id: \.label) { t in IOSNarrowTagTile(tag: t, model: model) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("tagList")
    }
}

private struct IOSNarrowTagTile: View {
    let tag: TagCount
    @ObservedObject var model: IOSTagsModel

    private var common: Int { IOSTagsModel.common(tag) }

    var body: some View {
        Button { model.onShowOnHome?(tag.label) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tag.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(tag.count)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    if tag.user > 0 { dot(tag.user, .iosTagMine) }
                    if common > 0 { dot(common, .iosTagBoth) }
                    if tag.ai > 0 { dot(tag.ai, .iosTagAI) }
                }
                TagProportionBar(tag: tag, height: 4)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(shape.strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.onShowOnHome?(tag.label) } label: {
                Label(L("tags.onlyOnHome"), systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { model.onToFolder?(tag) } label: {
                Label(L("tags.allToFolderShort"), systemImage: "folder.badge.plus")
            }
            Divider()
            Button { model.onRename?(tag) } label: {
                Label(L("tags.renameOrMerge"), systemImage: "pencil")
            }
            Button(role: .destructive) { model.onDelete?(tag) } label: {
                Label(L("tags.deleteEllipsis"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("tags.cell.spoken", tag.label, tag.count, tag.user, tag.ai))
        .accessibilityIdentifier("tagRow-\(tag.label)")
    }

    private func dot(_ n: Int, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text("\(n)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

// MARK: - Wide-screen card grid (aligned with macOS TagCardsView)

private struct IOSTagCardsView: View {
    @ObservedObject var model: IOSTagsModel
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                toolbar
                let tags = model.shown
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                } else if tags.isEmpty {
                    TagEmptyState(isEmptyLibrary: model.all.isEmpty)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(tags, id: \.label) { t in IOSTagCard(tag: t, model: model) }
                    }
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("tagCards")
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("tags.filter"), text: $model.query)
                    if !model.query.isEmpty {
                        Button { model.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())

                Menu {
                    Picker(L("tags.sort"), selection: $model.sort) {
                        ForEach(TagSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(L("tags.sortBy") + model.sort.title, systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .fixedSize()

                Menu {
                    Button(L("tags.deleteAIEllipsis"), role: .destructive) { model.onDeleteAI?() }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel(L("grid.more"))
                .accessibilityIdentifier("tagListMore")
            }

            HStack(spacing: 14) {
                Picker("", selection: $model.show) {
                    ForEach(IOSTagsModel.Show.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                TagLegendView()
            }

            if !model.summary.isEmpty {
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct IOSTagCard: View {
    let tag: TagCount
    @ObservedObject var model: IOSTagsModel

    private var common: Int { IOSTagsModel.common(tag) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(tag.label)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Button { model.onShowOnHome?(tag.label) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -6)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(tag.count)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(L("tags.itemsUnit"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            TagProportionBar(tag: tag, height: 8)
            HStack(spacing: 10) {
                if tag.user > 0 { stat(L("search.kw.mine.word"), tag.user, .iosTagMine) }
                if tag.ai > 0 { stat("AI", tag.ai, .iosTagAI) }
                if common > 0 { stat(L("search.kw.common.word"), common, .iosTagBoth) }
            }
            .font(.caption)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background { cardBackground }
        .contextMenu {
            Button { model.onShowOnHome?(tag.label) } label: {
                Label(L("tags.onlyOnHome"), systemImage: "line.3.horizontal.decrease.circle")
            }
            Button { model.onToFolder?(tag) } label: {
                Label(L("tags.allToFolderShort"), systemImage: "folder.badge.plus")
            }
            Divider()
            Button { model.onRename?(tag) } label: {
                Label(L("tags.renameOrMerge"), systemImage: "pencil")
            }
            Button(role: .destructive) { model.onDelete?(tag) } label: {
                Label(L("tags.deleteEllipsis"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("tags.cell.spoken", tag.label, tag.count, tag.user, tag.ai))
        .accessibilityIdentifier("tagRow-\(tag.label)")
        .accessibilityAction(named: L("tags.onlyOnHome")) { model.onShowOnHome?(tag.label) }
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(shape.strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
        }
    }

    private func stat(_ name: String, _ n: Int, _ c: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text("\(name) \(n)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}
