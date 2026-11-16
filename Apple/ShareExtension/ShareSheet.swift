import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The share page, the same on iOS and the Mac. What was shared is brought here first (files are
/// copied, links downloaded into a staging folder), shown as a card, or as a stack of cards for
/// several; the person says which folder it goes into, or none. Nothing reaches the library until
/// then: closing the page deletes what was brought here.
@MainActor
final class ShareSheetModel: ObservableObject {
    enum Stage {
        case working
        case ready
        case failed(String)
    }

    @Published var stage = Stage.working
    @Published var progress = ""
    @Published var title = L("common.import")
    @Published var count = 0
    @Published var previews: [ShareCard] = []
    @Published var text: String?
    @Published var problems: [String] = []
    @Published var folders: [String] = ShareCollector.folders()
    /// The folder chosen; empty: no folder.
    @Published var folder = ""
    /// How much was brought here, and the one file's name when it is one.
    @Published var bytes: Int64 = 0
    @Published var kind = ""
    @Published var name = ""
    /// Links that could not be downloaded here, which the app can try with its own settings.
    @Published var linksLeft: [String] = []

    /// Dropped on a window of the app: it goes in as loose media only, not as 从相册导入.
    var dropped = false
    /// A post's link was shared: however much it holds, it is one card on a low page.
    @Published var post = false
    /// The media fills the page: the iOS extension, whose sheet keeps the system's height.
    var large = false
    var onFinish: (() -> Void)?
    private var collector = ShareCollector()
    private var batch: ShareCollector.Batch?

    func start(_ providers: [NSItemProvider]) {
        post = !providers.isEmpty && providers.allSatisfy(ShareCollector.holdsText)
        Task {
            do {
                let b = try await collector.collect(providers) { [weak self] p in
                    Task { @MainActor in self?.progress = p }
                }
                batch = b
                count = b.count
                problems = b.problems
                text = b.text
                #if DEBUG
                // the page as it looks for a post, in a test without a link to download
                if let t = ProcessInfo.processInfo.environment["TL_TEST_POST"] { post = true; text = t }
                #endif
                linksLeft = b.failedLinks
                // what fills the page is pictured larger; a post shows its first media only
                let one = post || b.count == 1
                let files = post ? Array(b.previewFiles.prefix(1)) : b.previewFiles
                let pixels = large ? (one ? 1400 : 600) : 480
                previews = await Task.detached(priority: .userInitiated) { await ShareCard.cards(files, pixels: pixels) }.value
                bytes = b.bytes
                if b.count == 1, let f = b.previewFiles.first { name = f.lastPathComponent; kind = f.pathExtension.uppercased() }
                if b.count == 0, b.failedLinks.isEmpty {
                    stage = .failed(problems.isEmpty ? L("share.nothing") : problems.joined(separator: "\n"))
                    collector.discard()
                } else {
                    stage = .ready
                }
            } catch {
                collector.discard()
                stage = .failed(L("share.failed", error.localizedDescription))
            }
        }
    }

    private var chosenFolder: String? { folder.isEmpty ? nil : folder }

    /// A folder made here: it is in the list from now on, chosen. It comes to exist with the import.
    func addFolder(_ typed: String) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if !folders.contains(name) { folders.insert(name, at: 0) }
        folder = name
    }

    /// Hands over what is here, to the folder chosen.
    func confirm(openApp: (() -> Void)? = nil) {
        guard let batch else { return }
        stage = .working
        progress = L("share.handingOver")
        let folder = chosenFolder
        Task {
            do {
                try await collector.publish(batch, folder: folder, dropped: dropped)
                onFinish?()
            } catch {
                collector.discard()
                stage = .failed(L("share.failed", error.localizedDescription))
            }
        }
    }

    /// Closed without choosing: nothing was added anywhere.
    func close() {
        collector.discard()
    }
}

/// A picture of one shared media, small: made from the file by ImageIO without decoding the whole,
/// so the page stays light however large the files are.
struct ShareCard: Identifiable, Sendable {
    let id = UUID()
    let image: CGImage?
    let isVideo: Bool

    static func cards(_ files: [URL], pixels: Int) async -> [ShareCard] {
        var cards: [ShareCard] = []
        for url in files.prefix(ShareCollector.previewLimit) {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: pixels, height: pixels)
                let image = try? await generator.image(at: .zero).image
                cards.append(ShareCard(image: image, isVideo: true))
                continue
            }
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: pixels] as CFDictionary
            let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
            cards.append(ShareCard(image: image, isVideo: false))
        }
        return cards
    }
}

/// The share page: what was brought here on a card, and where it goes on another, with 关闭 and
/// 导入 above them. As tall as what it shows (`onHeight`): one media takes a row, more take a grid;
/// a post's link keeps one low height, downloading or done. On a sheet of the system's height
/// (`large`) the media fills what the folder row leaves, and that row stays at the bottom.
struct ShareSheetView: View {
    @ObservedObject var model: ShareSheetModel
    let close: () -> Void
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var asking = false
    @State private var typed = ""
    private static let postHeight: CGFloat = 280

    private func report(_ height: CGFloat) {
        guard !model.large else { return }
        onHeight?(model.post ? max(height, Self.postHeight) : height)
    }

    private var pageColor: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color.clear
        #endif
    }

    private var cardColor: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color.primary.opacity(0.05)
        #endif
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            switch model.stage {
            case .working:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.progress).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: model.large ? .infinity : nil)
                .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            case .failed(let message):
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: model.large ? .infinity : nil)
                    .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            case .ready:
                if model.large { largeCard } else { mediaCard }
                if model.count > 0 { place }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { report(g.size.height) }
                .onChange(of: g.size.height) { _, h in report(h) }
                .onChange(of: model.post) { report(g.size.height) }
        })
        .frame(maxHeight: .infinity, alignment: .top)
        .background(pageColor.ignoresSafeArea())
        .alert(L("common.newFolder"), isPresented: $asking) {
            TextField(L("common.folderName"), text: $typed).accessibilityIdentifier("shareNewFolderName")
            Button(L("common.create")) { model.addFolder(typed); typed = "" }.accessibilityIdentifier("shareNewFolderCreate")
            Button(L("common.cancel"), role: .cancel) { typed = "" }
        }
    }

    private var header: some View {
        ZStack {
            Text(model.title).font(.headline).lineLimit(1)
            HStack {
                Button(L("common.close"), action: close).accessibilityIdentifier("shareClose")
                Spacer()
                if case .ready = model.stage {
                    Button(model.count > 0 ? L("share.import") : L("share.downloadInApp")) { model.confirm() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .accessibilityIdentifier("shareImport")
                }
            }
        }
    }

    private var meta: String {
        ([model.kind].filter { !$0.isEmpty } + [ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)]).joined(separator: " · ")
    }

    private var status: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text(L("share.readyCount", model.count)).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("shareStatus")
            if model.bytes > 0 { Text(meta).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1) }
        }
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.post, model.count > 0, let card = model.previews.first {
                HStack(alignment: .center, spacing: 14) {
                    ShareThumb(card: card, side: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        status
                        if let text = model.text, !text.isEmpty {
                            Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        } else {
                            hint
                        }
                    }
                }
            } else if model.count == 1, let card = model.previews.first {
                HStack(alignment: .center, spacing: 14) {
                    ShareThumb(card: card, side: 76)
                    VStack(alignment: .leading, spacing: 5) {
                        status
                        if !model.name.isEmpty { Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle) }
                        hint
                    }
                }
            } else if model.count > 0 {
                status
                if !model.previews.isEmpty { ShareThumbGrid(cards: Array(model.previews.prefix(8)), count: model.count) }
                hint
            } else {
                Text(L("share.linksLeft", model.linksLeft.count)).font(.subheadline).foregroundStyle(.secondary)
            }
            if !model.post, let text = model.text, !text.isEmpty {
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if !model.problems.isEmpty {
                ScrollView { Text(model.problems.joined(separator: "\n")).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: 72)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The media as large as the page allows: one in full, several in a grid, a post on one card.
    private var largeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.count > 0, let card = model.previews.first, model.post || model.count == 1 {
                ShareLargePreview(card: card, badge: model.post && model.count > 1 ? L("share.cards", model.count) : nil)
                status
                if model.post {
                    if let text = model.text, !text.isEmpty {
                        Text(text).font(.subheadline).lineLimit(7).fixedSize(horizontal: false, vertical: true)
                    } else {
                        hint
                    }
                } else {
                    if !model.name.isEmpty { Text(model.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle) }
                    hint
                }
            } else if model.count > 0 {
                status
                if !model.previews.isEmpty { ShareLargeGrid(cards: model.previews, count: model.count) } else { Spacer(minLength: 0) }
                hint
            } else {
                Text(L("share.linksLeft", model.linksLeft.count)).font(.subheadline).foregroundStyle(.secondary)
            }
            if !model.problems.isEmpty {
                ScrollView { Text(model.problems.joined(separator: "\n")).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .frame(maxHeight: model.count > 0 ? 72 : .infinity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var hint: some View {
        Text(L("share.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var currentFolder: String { model.folder.isEmpty ? L("share.noFolder") : model.folder }

    private var place: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("share.place")).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(L("share.current", currentFolder)).font(.footnote).foregroundStyle(Color.accentColor).lineLimit(1)
            }
            .padding(.horizontal, 6)
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.system(size: 15)).foregroundStyle(.white)
                    .frame(width: 32, height: 32).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(L("share.targetFolder")).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Picker("", selection: $model.folder) {
                        Text(L("share.noFolder")).tag("")
                        ForEach(model.folders, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    Divider()
                    Button { asking = true } label: { Label(L("common.newFolderEllipsis"), systemImage: "folder.badge.plus") }
                        .accessibilityIdentifier("shareNewFolder")
                } label: {
                    HStack(spacing: 4) {
                        Text(currentFolder).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.1), in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("shareFolder")
            }
            .padding(12)
            .background(cardColor, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

/// One shared media, small.
private struct ShareThumb: View {
    let card: ShareCard
    let side: CGFloat

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.2))
            if let image = card.image { Image(decorative: image, scale: 2).resizable().scaledToFill() }
            if card.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: side * 0.36)).foregroundStyle(.white.opacity(0.9))
            } else if card.image == nil {
                Image(systemName: "photo").font(.system(size: side * 0.3)).foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shareCards")
    }
}

/// One media in full, never cropped, on as much of the page as there is.
private struct ShareLargePreview: View {
    let card: ShareCard
    let badge: String?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.gray.opacity(0.12))
            if let image = card.image { Image(decorative: image, scale: 2).resizable().scaledToFit() }
            if card.isVideo {
                Image(systemName: "play.circle.fill").font(.system(size: 52)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4)
            } else if card.image == nil {
                Image(systemName: "photo").font(.system(size: 40)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if let badge {
                Text(badge).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(8)
                    .accessibilityIdentifier("shareCount")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("shareCards")
    }
}

/// Several on the whole page: two columns up to four, then three, the last saying how many more.
private struct ShareLargeGrid: View {
    let cards: [ShareCard]
    let count: Int

    private var rows: [ArraySlice<ShareCard>] {
        let columns = count <= 4 ? 2 : 3
        return stride(from: 0, to: cards.count, by: columns).map { cards[$0..<min($0 + columns, cards.count)] }
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row) { cell($0) }
                    ForEach(0..<((count <= 4 ? 2 : 3) - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("share.cards", count))
        .accessibilityIdentifier("shareCards")
    }

    private func cell(_ card: ShareCard) -> some View {
        Rectangle().fill(Color.gray.opacity(0.2))
            .overlay {
                if let image = card.image { Image(decorative: image, scale: 2).resizable().scaledToFill() }
                else if !card.isVideo { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .overlay {
                if card.isVideo { Image(systemName: "play.circle.fill").font(.title).foregroundStyle(.white.opacity(0.9)).shadow(radius: 3) }
            }
            .overlay {
                if card.id == cards.last?.id, count > cards.count {
                    Rectangle().fill(.black.opacity(0.5))
                    Text("+\(count - cards.count + 1)").font(.title3.weight(.semibold)).foregroundStyle(.white).accessibilityIdentifier("shareCount")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Several: a grid of as many rows as they take, the last saying how many more there are.
private struct ShareThumbGrid: View {
    let cards: [ShareCard]
    let count: Int

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 8)], spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(GeometryReader { g in ShareThumb(card: card, side: g.size.width) })
                    .overlay {
                        if i == cards.count - 1, count > cards.count {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.5))
                            Text("+\(count - cards.count + 1)").font(.headline).foregroundStyle(.white).accessibilityIdentifier("shareCount")
                        }
                    }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("share.cards", count))
        .accessibilityIdentifier("shareCards")
    }
}
