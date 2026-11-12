import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Hosting

/// What a settings page needs from its window: dialogs and sheets belong to the window, and
/// sub-pages are pushed on the settings panel (whose header is the main window's toolbar).
@MainActor
final class PaneEnv: ObservableObject {
    weak var host: NSViewController?
    var window: NSWindow? { host?.view.window }
    var push: (NSViewController, String) -> Void = { _, _ in }
    func open(_ title: String, _ page: NSViewController) { push(page, title) }
}

/// A settings page written in SwiftUI, shown in the settings panel like any other page.
final class SettingsHost: NSViewController {
    weak var panel: MacSettingsPanel? { didSet { env.push = { [weak panel] vc, title in panel?.push(vc, title: title) } } }
    let env = PaneEnv()
    private let make: (PaneEnv) -> AnyView

    init<V: View>(_ content: @escaping () -> V) {
        make = { env in AnyView(content().environmentObject(env)) }
        super.init(nibName: nil, bundle: nil)
        env.host = self
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let host = NSHostingView(rootView: make(env))
        // the page never asks the split view for a size (it fills what it is given): a
        // hosting view's own ideal size once pushed the sidebar to its widest
        host.sizingOptions = []
        view = host
        view.frame = NSRect(x: 0, y: 0, width: 680, height: 560)
    }
}

// MARK: - Live updates

/// Re-evaluates a page when anything it shows may have changed (a notification of the app's
/// stores, or a timer while the page is on screen). Pages read the live values in their body.
@MainActor
final class LiveTick: ObservableObject {
    @Published private(set) var count = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var scheduled = false
    /// Work that belongs to a page and is not a redraw (a download that ended, a pairing that finished).
    var onTick: (() -> Void)?

    func start(every interval: TimeInterval? = nil) {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [ActivityCenter.changed, ModelStore.changed, SyncService.changed, AutoTagger.progressChanged, LibraryPrefs.changed, .libraryChanged]
        observers = names.map { n in
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.poke() }
            }
        }
        if let interval { timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poke() } } }
        poke()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        timer?.invalidate(); timer = nil
    }

    /// Several changes in a row count as one (a progress update storm is one redraw).
    func poke() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.onTick?()
            self.count += 1
        }
    }
}

// MARK: - Design language
//
// Settings are made of cards on a soft page: a hero with the numbers that matter, glass tiles
// that open the sub-pages, option cards you pick by touching them, and content cards for
// everything else. Colour carries meaning (blue downloads, purple intelligence, green sync,
// orange problems, red what cannot be undone); symbols sit on small gradient tiles.

/// The page: a scrolling column on a readable width (no background of its own).
struct SettingsCanvas<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) { content }
                .frame(maxWidth: 880, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
        }
    }
}

/// A heading above a group of cards, with an optional note under it.
struct SectionHeading: View {
    let title: String
    var note: String?
    var trailing: AnyView?
    init(_ title: String, note: String? = nil, trailing: AnyView? = nil) { self.title = title; self.note = note; self.trailing = trailing }
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            // ends where the controls in the cards below end (a card's padding, less this heading's)
            trailing.padding(.trailing, 14)
        }
        .padding(.horizontal, 4)
    }
}

/// The surface of a content card.
struct CardSurface: View {
    var tint: Color? = nil
    var radius: CGFloat = 20
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Color(nsColor: .controlBackgroundColor))
            .overlay { if let tint { shape.fill(tint.opacity(0.08)) } }
            .overlay(shape.strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.22), lineWidth: 1))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
    }
}

/// A content card.
struct Card<Content: View>: View {
    var tint: Color? = nil
    var padding: CGFloat = 18
    var spacing: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CardSurface(tint: tint) }
    }
}

/// A glass surface for things you touch (macOS 26: Liquid Glass; earlier: a material).
struct GlassSurface: View {
    var radius: CGFloat = 20
    var interactive = false
    var selected = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            if #available(macOS 26.0, *) { Color.clear.glassEffect(interactive ? .regular.interactive() : .regular, in: shape) }
            else { shape.fill(.regularMaterial) }
        }
        .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.07), lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

/// A symbol on a small gradient tile.
struct IconTile: View {
    let symbol: String
    var color: Color = .accentColor
    var size: CGFloat = 36
    /// The icon that takes its place in the mascot mode (no tile: the crab has its own colours).
    var mascot: String? = nil
    /// That icon whether the mode is on or not.
    var alwaysMascot = false
    @AppStorage(Mascot.key) private var mascotOn = false
    var body: some View {
        if let mascot, mascotOn || alwaysMascot {
            Image(nsImage: Mascot.icon(mascot, side: size))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
                .shadow(color: color.opacity(0.28), radius: 4, y: 2)
        }
    }
}

/// A small label in a colour.
struct Pill: View {
    let text: String
    var color: Color = .secondary
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
    }
}

/// A circular progress.
/// A slim progress bar: a quiet track and a solid fill (the accent colour unless given) that
/// follows the value smoothly. With no value, a short piece of fill passes along the track.
struct SlimBar: View {
    var value: Double?
    var color: Color = .accentColor
    @State private var passing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                if let value {
                    Capsule().fill(color)
                        .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
                        .animation(.easeOut(duration: 0.35), value: value)
                } else {
                    Capsule().fill(color)
                        .frame(width: geo.size.width * 0.32)
                        .offset(x: passing ? geo.size.width : -geo.size.width * 0.32)
                        .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: passing)
                        .onAppear { passing = true }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityValue(value.map { "\(Int(min(max($0, 0), 1) * 100))%" } ?? L("models.inProgress"))
    }
}

struct ProgressRing: View {
    let value: Double
    var lineWidth: CGFloat = 10
    var color: Color = .accentColor
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(value, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: value)
        }
    }
}

/// A row in a card: an optional symbol tile, a title and a note, the control on the trailing side.
struct CardRow<Trailing: View>: View {
    var symbol: String? = nil
    var color: Color = .accentColor
    var mascot: String? = nil
    var alwaysMascot = false
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol { IconTile(symbol: symbol, color: color, size: 30, mascot: mascot, alwaysMascot: alwaysMascot) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .medium))
                if let detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 10)
            trailing
        }
    }
}

/// A row that opens a subpage: the whole row is the button, with the same arrow as the tiles.
struct NavRow: View {
    var symbol: String? = nil
    var color: Color = .accentColor
    let title: String
    var detail: String? = nil
    var id: String? = nil
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            CardRow(symbol: symbol, color: color, title: title, detail: detail) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { hovering = h } }
        .accessibilityIdentifier(id ?? title)
    }
}

/// A row with a switch.
struct ToggleRow: View {
    var symbol: String? = nil
    var color: Color = .accentColor
    var mascot: String? = nil
    var alwaysMascot = false
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var disabled = false
    var body: some View {
        CardRow(symbol: symbol, color: color, mascot: mascot, alwaysMascot: alwaysMascot, title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).disabled(disabled)
        }
        .opacity(disabled ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// A thin line between rows of one card, inset past the symbol tiles.
struct RowDivider: View {
    var inset: CGFloat = 0
    var body: some View { Divider().padding(.leading, inset).opacity(0.6) }
}

/// A tile that opens a sub-page: symbol, title, a live line (and optionally a thin progress).
struct NavTile: View {
    let title: String
    var detail: String?
    let symbol: String
    let color: Color
    var mascot: String? = nil
    var progress: Double? = nil
    var badge: String? = nil
    var badgeColor: Color = .secondary
    var id: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    IconTile(symbol: symbol, color: color, size: 40, mascot: mascot)
                    Spacer(minLength: 6)
                    if let badge { Pill(text: badge, color: badgeColor) }
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                        .offset(x: hovering ? 2 : 0)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail ?? " ").font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                }
            }
            .padding(16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                // the bar lies over the tile's foot, in room every tile keeps, so all tiles are as tall as each other
                if let progress { SlimBar(value: progress, color: color).padding(.horizontal, 16).padding(.bottom, 12) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .background { GlassSurface(interactive: true) }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id ?? "")
    }
}

/// A choice you pick by touching it (one of several side by side).
struct OptionCard: View {
    let title: String
    let detail: String
    let symbol: String
    var color: Color = .accentColor
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    IconTile(symbol: symbol, color: selected ? color : .gray, size: 32)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17)).foregroundStyle(selected ? color : Color.secondary.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(selected ? color.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(selected ? color : Color.primary.opacity(hovering ? 0.18 : 0.08), lineWidth: selected ? 2 : 1))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? L("mac.selected") : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A capsule you can pick (a folder, a prompt set).
struct ChipButton: View {
    let title: String
    var symbol: String? = nil
    var selected = false
    var dashed = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
            .overlay { if dashed { Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3])) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A line of text with an icon, for a note inside a card (a warning, a hint).
struct Banner: View {
    let text: String
    var symbol = "info.circle.fill"
    var color: Color = .orange
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.callout).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A big number with its label, for the hero.
struct BigStat: View {
    let value: Int?
    let name: String
    let symbol: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value ?? 0)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText()).minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(value ?? 0)")
    }
}

/// The four totals, side by side (the numbers to compare across devices).
struct StatsStrip: View {
    let stats: LibraryStats?
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            BigStat(value: stats?.posts, name: L("common.posts"), symbol: "text.bubble.fill", color: .blue)
            BigStat(value: stats?.photos, name: L("search.kw.photo.word"), symbol: "photo.fill", color: .orange)
            BigStat(value: stats?.videos, name: L("place.videos"), symbol: "play.rectangle.fill", color: .pink)
            BigStat(value: stats?.tags, name: L("common.tags"), symbol: "tag.fill", color: .purple)
        }
    }
}

/// One running task: the item being worked on (a thumbnail), the title, what is done and a bar.
struct ActivityRow: View {
    let activity: Activity
    @State private var thumb: NSImage?
    @State private var loadedPath: String?

    private var symbol: String {
        switch activity.kind {
        case .download: "arrow.down.circle.fill"
        case .model: "shippingbox.fill"
        case .tagging: "sparkles"
        case .sync: "arrow.triangle.2.circlepath"
        case .verify: "checkmark.shield.fill"
        case .importing: "square.and.arrow.down.on.square.fill"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            let crab = thumb == nil && Mascot.isOn && (activity.kind == .download || activity.kind == .tagging)
            ZStack {
                // the crab lies on the card as it is, with no tile around it
                if !crab { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.15)) }
                if let thumb { Image(nsImage: thumb).resizable().scaledToFill() }
                else if crab { Image(nsImage: Mascot.icon(activity.kind == .download ? "bag" : "camera", side: 44)) }
                else { Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.tint) }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(activity.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                SlimBar(value: activity.progress).padding(.top, 2)
            }
        }
        .onAppear { load() }
        .onChange(of: activity.previewPath) { _, _ in load() }
    }

    private func load() {
        guard let path = activity.previewPath else { thumb = nil; loadedPath = nil; return }
        guard path != loadedPath else { return }
        loadedPath = path
        let isVideo = activity.previewIsVideo
        MacMediaLoader.shared.load(path: path, isVideo: isVideo, maxPixel: 140) { img in
            guard loadedPath == path else { return }
            withAnimation(.easeInOut(duration: 0.25)) { thumb = img }
        }
    }
}

/// What is running (of some kinds), as one accent-tinted card; nothing when nothing runs.
struct ActivityCard: View {
    var kinds: Set<Activity.Kind>? = nil
    var body: some View {
        let list = ActivityCenter.shared.activities.filter { kinds == nil || kinds!.contains($0.kind) }
        if !list.isEmpty {
            Card(tint: .accentColor, spacing: 16) {
                ForEach(list) { ActivityRow(activity: $0) }
            }
        }
    }
}

/// Text with a hint inside while it is empty.
struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var minHeight: CGFloat = 110
    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6).padding(.vertical, 4)
            if text.isEmpty {
                Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                    .padding(.horizontal, 11).padding(.vertical, 12).allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Wraps its children onto further lines (a cloud of capsules).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// A card with an icon and a title as its head, for a page's main blocks.
struct TitledCard<Content: View, Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    var color: Color = .accentColor
    var tint: Color? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        Card(tint: tint, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                if let symbol { IconTile(symbol: symbol, color: color, size: 34) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 8)
                trailing
            }
            content
        }
    }
}

extension TitledCard where Trailing == EmptyView {
    init(title: String, detail: String? = nil, symbol: String? = nil, color: Color = .accentColor, tint: Color? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, detail: detail, symbol: symbol, color: color, tint: tint, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Dialogs that are not a page's own

/// Shows an open panel as its own window (not a sheet on the settings window).
func macOpenPanel(_ types: [UTType], directories: Bool = false, done: @escaping (URL) -> Void) {
    let p = NSOpenPanel()
    p.allowedContentTypes = types
    p.canChooseDirectories = directories
    p.allowsMultipleSelection = false
    p.begin { r in if r == .OK, let u = p.url { done(u) } }
}

func macSavePanel(_ name: String, done: @escaping (URL) -> Void) {
    let p = NSSavePanel()
    p.nameFieldStringValue = name
    p.begin { r in if r == .OK, let u = p.url { done(u) } }
}

/// Diagnostics ZIP for a bug report (counts and errors only).
func macExportDiagnostics(_ window: NSWindow?) {
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
    macSavePanel(L("settings.diagnostics.fileName", f.string(from: Date()))) { url in
        macRun(window, { try Diagnostics.export(to: url) }) { n in
            macAlert(window, L("diag.exported"), L("diag.exported.detail", n, url.lastPathComponent))
        }
    }
}

/// Clearing everything on this device: a choice (keep the AI models or not), then typing 清除.
enum MacWipeFlow {
    static func start(_ window: NSWindow?) {
        macChoose(window, title: L("settings.wipe.title"), message: L("mac.wipe.message"),
                  options: [L("settings.wipe.keepModels"), L("settings.wipe.withModels")]) { choice in
            let models = choice == 1
            DispatchQueue.main.async { typed(window, includeModels: models) }
        }
    }

    private nonisolated static func typed(_ window: NSWindow?, includeModels: Bool) {
        macPrompt(window, title: L("common.confirmAgain"), message: L("mac.wipe.typeToConfirm", L("settings.wipe.word")) + (includeModels ? L("settings.wipe.modelsToo") : ""), placeholder: L("settings.wipe.word")) { text in
            guard text == L("settings.wipe.word") else { return }
            MainActor.assumeIsolated { AutoTagger.shared.stop() }
            macRun(window, {
                try Core.wipe(includeModels: includeModels)
                ShareInbox.wipe()
                AppLog.wipe()
                Keychain.wipeAll()
                Core.setCookies(authToken: "", ct0: "")
                let d = UserDefaults.standard
                d.dictionaryRepresentation().keys.filter { includeModels || !Core.aiPreferenceKeys.contains($0) }.forEach { d.removeObject(forKey: $0) }
            }) {
                MainActor.assumeIsolated {
                    if includeModels { ModelStore.shared.wipe() } else { ModelStore.shared.reload() }
                    SyncService.shared.resetForWipe()
                    NotificationCenter.default.post(name: .libraryChanged, object: nil)
                    ActivityCenter.shared.refreshStats()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MainActor.assumeIsolated { ModelStore.shared.configure(); SyncService.shared.start() } }
                    macAlert(window, L("settings.wipe.done"), L("settings.wipe.doneMessage"))
                }
            }
        }
    }
}
