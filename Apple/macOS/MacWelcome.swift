import AppKit
import SwiftUI

// MARK: - Window Controller

/// Native macOS Welcome / Onboarding window: 8 pages introducing TwimShelf's real workflows with
/// pure-vector SwiftUI micro-animations mirroring the actual macOS app layout (no GIFs, no sample
/// media). Shown automatically on first launch and reopenable from the app menu or About page.
@MainActor
final class MacWelcomeController: NSObject, NSWindowDelegate {
    static let shared = MacWelcomeController()
    private static let seenKey = "mac.welcome.seen"
    private static let nextLaunchKey = "mac.welcome.nextLaunch"

    private var window: NSWindow?
    private var keyMonitor: Any?
    private let state = WelcomeState()

    var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: Self.seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.seenKey) }
    }

    var showOnNextLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Self.nextLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.nextLaunchKey) }
    }

    func showIfFirstLaunch(relativeTo parent: NSWindow?) {
        let scheduled = showOnNextLaunch
        guard !hasSeen || scheduled else { return }
        if scheduled { showOnNextLaunch = false }
        show(relativeTo: parent, startPage: 0)
    }

    func show(relativeTo parent: NSWindow? = nil, startPage: Int = 0) {
        state.jump(to: startPage)
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = L("welcome.windowTitle")
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.delegate = self

        let root = WelcomeView(state: state, dismiss: { [weak self] in self?.close() })
        w.contentViewController = NSHostingController(rootView: root)
        w.setContentSize(NSSize(width: 700, height: 560))

        if let parent {
            let pf = parent.frame
            w.setFrameOrigin(NSPoint(x: pf.midX - 350, y: pf.midY - 280))
        } else {
            w.center()
        }

        window = w
        installKeyMonitor()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        hasSeen = true
        removeKeyMonitor()
        window?.orderOut(nil)
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        hasSeen = true
        removeKeyMonitor()
        window = nil
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, w.isKeyWindow else { return event }
            switch event.keyCode {
            case 53: // Esc
                self.close()
                return nil
            case 123: // Left arrow
                self.state.goPrev()
                return nil
            case 124: // Right arrow
                self.state.goNext()
                return nil
            case 36, 76, 49: // Return / Enter / Space
                if self.state.page == WelcomePage.allCases.count - 1 {
                    self.close()
                } else {
                    self.state.goNext()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    #if DEBUG
    func debugCaptureAllPages(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        show(relativeTo: nil, startPage: 0)
        func snap(_ idx: Int) {
            guard idx < WelcomePage.allCases.count else {
                close()
                NSApp.terminate(nil)
                return
            }
            state.jump(to: idx)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                if let w = self.window {
                    AppDelegate.windowSnapshot(w, to: directory.appendingPathComponent("welcome_p\(idx + 1).png"))
                }
                snap(idx + 1)
            }
        }
        snap(0)
    }
    #endif
}

// MARK: - State & Page Model

enum WelcomePage: Int, CaseIterable, Identifiable {
    case randomBrowse = 0
    case gridZoom
    case quickDownload
    case aiModels
    case tagOrigins
    case tokenSearch
    case lanSync
    case importExport

    var id: Int { rawValue }

    var badge: String {
        switch self {
        case .randomBrowse: L("welcome.p1.badge")
        case .gridZoom: L("welcome.p2.badge")
        case .quickDownload: L("welcome.p3.badge")
        case .aiModels: L("welcome.p4.badge")
        case .tagOrigins: L("welcome.p5.badge")
        case .tokenSearch: L("welcome.p6.badge")
        case .lanSync: L("welcome.p7.badge")
        case .importExport: L("welcome.p8.badge")
        }
    }

    var title: String {
        switch self {
        case .randomBrowse: L("welcome.p1.title")
        case .gridZoom: L("welcome.p2.title")
        case .quickDownload: L("welcome.p3.title")
        case .aiModels: L("welcome.p4.title")
        case .tagOrigins: L("welcome.p5.title")
        case .tokenSearch: L("welcome.p6.title")
        case .lanSync: L("welcome.p7.title")
        case .importExport: L("welcome.p8.title")
        }
    }

    var body: String {
        switch self {
        case .randomBrowse: L("welcome.p1.body.desktop")
        case .gridZoom: L("welcome.p2.body")
        case .quickDownload: L("welcome.p3.body")
        case .aiModels: L("welcome.p4.body")
        case .tagOrigins: L("welcome.p5.body")
        case .tokenSearch: L("welcome.p6.body")
        case .lanSync: L("welcome.p7.body")
        case .importExport: L("welcome.p8.body")
        }
    }

    var accent: Color {
        switch self {
        case .randomBrowse: .orange
        case .gridZoom: .blue
        case .quickDownload: .cyan
        case .aiModels: .purple
        case .tagOrigins: .green
        case .tokenSearch: .indigo
        case .lanSync: .teal
        case .importExport: .pink
        }
    }

    var symbol: String {
        switch self {
        case .randomBrowse: "shuffle"
        case .gridZoom: "square.grid.3x3"
        case .quickDownload: "arrow.down.circle.fill"
        case .aiModels: "sparkles"
        case .tagOrigins: "tag.fill"
        case .tokenSearch: "magnifyingglass"
        case .lanSync: "point.3.connected.trianglepath.dotted"
        case .importExport: "arrow.left.arrow.right.circle.fill"
        }
    }
}

@MainActor
final class WelcomeState: ObservableObject {
    @Published var page: Int = 0
    @Published var direction: Int = 1

    var current: WelcomePage { WelcomePage(rawValue: page) ?? .randomBrowse }

    func goNext() {
        guard page < WelcomePage.allCases.count - 1 else { return }
        direction = 1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page += 1 }
    }

    func goPrev() {
        guard page > 0 else { return }
        direction = -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page -= 1 }
    }

    func jump(to index: Int) {
        let clamped = max(0, min(WelcomePage.allCases.count - 1, index))
        guard clamped != page else { return }
        direction = clamped > page ? 1 : -1
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) { page = clamped }
    }
}

// MARK: - Root Welcome View

private struct WelcomeView: View {
    @ObservedObject var state: WelcomeState
    var dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var total: Int { WelcomePage.allCases.count }
    private var isFirst: Bool { state.page == 0 }
    private var isLast: Bool { state.page == total - 1 }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    RadialGradient(
                        colors: [
                            state.current.accent.opacity(scheme == .dark ? 0.16 : 0.09),
                            Color.clear,
                        ],
                        center: .top,
                        startRadius: 20,
                        endRadius: 430
                    )
                    .animation(.easeInOut(duration: 0.45), value: state.page)
                )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Text(L("welcome.step", state.page + 1, total))
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
                }
                .padding(.top, 14)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

                ZStack {
                    pageContent(for: state.current)
                        .id(state.current)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: state.direction >= 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: state.direction >= 0 ? .leading : .trailing).combined(with: .opacity)
                            )
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                Divider()
                    .opacity(0.45)

                HStack(spacing: 12) {
                    if isFirst {
                        Button(L("welcome.skip")) { dismiss() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 74, alignment: .leading)
                    } else {
                        Button {
                            state.goPrev()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(L("welcome.back"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .frame(minWidth: 88, alignment: .leading)
                    }

                    Spacer()

                    HStack(spacing: 7) {
                        ForEach(WelcomePage.allCases) { p in
                            let active = p.rawValue == state.page
                            Capsule()
                                .fill(active ? state.current.accent : Color.primary.opacity(scheme == .dark ? 0.22 : 0.16))
                                .frame(width: active ? 22 : 7, height: 7)
                                .animation(.spring(response: 0.34, dampingFraction: 0.78), value: state.page)
                                .contentShape(Rectangle().inset(by: -5))
                                .onTapGesture { state.jump(to: p.rawValue) }
                        }
                    }

                    Spacer()

                    Button {
                        if isLast { dismiss() } else { state.goNext() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(isLast ? L("welcome.done") : L("welcome.next"))
                            Image(systemName: isLast ? "checkmark" : "arrow.right")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        .frame(minWidth: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.current.accent)
                    .controlSize(.large)
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
            }
        }
        .frame(width: 700, height: 560)
    }

    @ViewBuilder
    private func pageContent(for page: WelcomePage) -> some View {
        VStack(spacing: 0) {
            StageContainer(accent: page.accent) {
                stageView(for: page)
            }
            .frame(height: 304)
            .padding(.horizontal, 28)

            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                    Text(page.badge)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(page.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(page.accent.opacity(scheme == .dark ? 0.20 : 0.12), in: Capsule())

                Text(page.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(page.body)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 540)
            }
            .padding(.top, 18)
            .padding(.horizontal, 36)

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private func stageView(for page: WelcomePage) -> some View {
        switch page {
        case .randomBrowse: ShuffleMasonryStage()
        case .gridZoom: GridZoomStage()
        case .quickDownload: DownloadBatchStage()
        case .aiModels: AIModelTagStage()
        case .tagOrigins: TagTrioStage()
        case .tokenSearch: TokenSearchStage()
        case .lanSync: LanSyncStage()
        case .importExport: ImportExportStage()
        }
    }
}

/// Full-stage rounded card: expands content to full bounds BEFORE clipping so scaled or offset
/// animations are never clipped by an invisible tight container.
private struct StageContainer<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.055) : Color.white.opacity(0.76))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(scheme == .dark ? 0.13 : 0.07), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.06), radius: 14, y: 6)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.14 : 0.09), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Shared Miniature macOS TwimShelf Chrome

private enum MiniSidebarItem: CaseIterable {
    case browse, photos, videos, folders, settings

    var symbol: String {
        switch self {
        case .browse: "square.grid.2x2"
        case .photos: "photo"
        case .videos: "play.rectangle"
        case .folders: "folder"
        case .settings: "gearshape"
        }
    }

    var title: String {
        switch self {
        case .browse: L("place.browse")
        case .photos: L("place.photos")
        case .videos: L("place.videos")
        case .folders: L("place.folders")
        case .settings: L("place.settings")
        }
    }
}

/// Faithful miniature TwimShelf macOS window chrome: translucent left sidebar + unified toolbar +
/// main content pane. Keeps every page grounded in the app's actual layout.
private struct MiniAppWindow<Toolbar: View, BodyContent: View>: View {
    let selected: MiniSidebarItem
    let accent: Color
    @ViewBuilder var toolbar: () -> Toolbar
    @ViewBuilder var bodyContent: () -> BodyContent
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar (matches MacSidebarViewController)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4.5) {
                    Circle().fill(Color.red.opacity(0.65)).frame(width: 6.5, height: 6.5)
                    Circle().fill(Color.yellow.opacity(0.65)).frame(width: 6.5, height: 6.5)
                    Circle().fill(Color.green.opacity(0.65)).frame(width: 6.5, height: 6.5)
                }
                .padding(.bottom, 8)
                .padding(.leading, 4)

                ForEach(MiniSidebarItem.allCases, id: \.self) { item in
                    let active = item == selected
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 10, weight: active ? .semibold : .regular))
                            .frame(width: 13)
                        Text(item.title)
                            .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(active ? accent : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(active ? accent.opacity(scheme == .dark ? 0.22 : 0.14) : Color.clear)
                    )
                    if item == .browse || item == .folders {
                        Divider().opacity(0.35).padding(.vertical, 2)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .frame(width: 112)
            .background(Color.primary.opacity(scheme == .dark ? 0.055 : 0.035))

            Divider().opacity(0.35)

            // Right Content Pane (Unified Toolbar + Page Body)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    toolbar()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.primary.opacity(scheme == .dark ? 0.03 : 0.015))

                Divider().opacity(0.30)

                ZStack {
                    bodyContent()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.985))
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.11), lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: 12, y: 4)
        .padding(16)
    }
}

private struct MiniToolbarButton: View {
    let symbol: String
    var active: Bool = false
    var accent: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? accent : Color.primary.opacity(scheme == .dark ? 0.09 : 0.06))
                .frame(width: 22, height: 22)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? .white : .secondary)
        }
    }
}

// MARK: - Page 1: Random Browse + Real Toolbar Reshuffle

private struct ShuffleMasonryStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var step = 0
    @State private var clicking = false

    private struct CardSpec: Identifiable {
        let id: Int
        let color: Color
        let symbol: String
        let heights: [CGFloat]
    }

    private let cards: [CardSpec] = [
        CardSpec(id: 0, color: .orange, symbol: "photo", heights: [92, 68, 80]),
        CardSpec(id: 1, color: .pink, symbol: "play.fill", heights: [68, 94, 72]),
        CardSpec(id: 2, color: .indigo, symbol: "photo.stack", heights: [84, 74, 90]),
        CardSpec(id: 3, color: .teal, symbol: "photo", heights: [74, 86, 66]),
        CardSpec(id: 4, color: .purple, symbol: "play.fill", heights: [86, 68, 84]),
        CardSpec(id: 5, color: .blue, symbol: "photo", heights: [70, 82, 74]),
    ]

    private let orders: [[Int]] = [
        [0, 1, 2, 3, 4, 5],
        [4, 2, 5, 1, 0, 3],
        [2, 5, 0, 4, 3, 1],
    ]

    var body: some View {
        MiniAppWindow(selected: .browse, accent: .orange) {
            Text(L("place.browse"))
                .font(.system(size: 11.5, weight: .semibold))
            Spacer(minLength: 6)
            // Capsule search bar (real Browse toolbar)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 9)).foregroundStyle(.secondary)
                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.14)).frame(width: 56, height: 4.5)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(width: 150, height: 22)
            .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
            Spacer(minLength: 6)
            MiniToolbarButton(symbol: "clock")
            MiniToolbarButton(symbol: "rectangle.stack")
            MiniToolbarButton(symbol: "arrow.down.circle")
            // Highlighted Reshuffle button with ripple
            ZStack {
                Circle()
                    .stroke(Color.orange.opacity(clicking ? 0 : 0.6), lineWidth: 1.8)
                    .scaleEffect(clicking ? 1.8 : 1.0)
                    .frame(width: 22, height: 22)
                MiniToolbarButton(symbol: "shuffle", active: true, accent: .orange)
                    .rotationEffect(.degrees(Double(step) * 180))
                    .scaleEffect(clicking ? 0.86 : 1.0)
            }
        } bodyContent: {
            GeometryReader { geo in
                let order = orders[step % orders.count]
                let pad: CGFloat = 12
                let gap: CGFloat = 9
                let colW = (geo.size.width - pad * 2 - gap * 2) / 3
                let rects = layoutMasonry(order: order, colW: colW, gap: gap, pad: pad)

                ForEach(cards) { card in
                    if let r = rects[card.id] {
                        // Faithful miniature PostCard: media top + white/dark caption pane bottom
                        VStack(spacing: 0) {
                            ZStack(alignment: .topTrailing) {
                                LinearGradient(
                                    colors: [card.color.opacity(scheme == .dark ? 0.42 : 0.28), card.color.opacity(scheme == .dark ? 0.20 : 0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: card.symbol)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(card.color.opacity(0.9))
                                    .padding(5)
                            }
                            .frame(maxHeight: .infinity)

                            // Caption pane with abstract author + tag pill
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.20)).frame(width: colW * 0.42, height: 4)
                                Spacer()
                                Capsule().fill(card.color.opacity(0.24)).frame(width: 18, height: 6)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 18)
                            .background(scheme == .dark ? Color(white: 0.18) : Color.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .inset(by: 0.5)
                                .stroke(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 0.8)
                        )
                        .frame(width: r.width, height: r.height)
                        .position(x: r.midX, y: r.midY)
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.1))
                guard !Task.isCancelled else { break }
                withAnimation(.easeOut(duration: 0.24)) { clicking = true }
                withAnimation(.spring(response: 0.62, dampingFraction: 0.78)) { step += 1 }
                try? await Task.sleep(for: .milliseconds(280))
                withAnimation(.easeOut(duration: 0.22)) { clicking = false }
            }
        }
    }

    private func layoutMasonry(order: [Int], colW: CGFloat, gap: CGFloat, pad: CGFloat) -> [Int: CGRect] {
        var colY: [CGFloat] = [pad, pad, pad]
        var out: [Int: CGRect] = [:]
        for id in order {
            let col = colY.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            let h = cards[id].heights[step % 3]
            out[id] = CGRect(x: pad + CGFloat(col) * (colW + gap), y: colY[col], width: colW, height: h)
            colY[col] += h + gap
        }
        return out
    }
}

// MARK: - Page 2: Album Grid Zoom in Real Photos Layout

private struct GridZoomStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var levelIdx = 1
    private let levels = [6, 4, 2, 4]
    private let tints: [Color] = [.blue, .indigo, .cyan, .teal, .purple, .mint]

    var body: some View {
        let cols = levels[levelIdx % levels.count]
        MiniAppWindow(selected: .photos, accent: .blue) {
            Text(L("place.photos"))
                .font(.system(size: 11.5, weight: .semibold))
            Spacer()
            MiniToolbarButton(symbol: "minus.magnifyingglass", active: cols == 6, accent: .blue)
            MiniToolbarButton(symbol: "plus.magnifyingglass", active: cols == 2, accent: .blue)
        } bodyContent: {
            GeometryReader { geo in
                let pad: CGFloat = 8
                let gap: CGFloat = 3
                let side = (geo.size.width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
                let rows = Int(ceil((geo.size.height - pad * 2) / (side + gap))) + 1
                let anchorR = max(0, min(rows - 1, rows / 2 - (cols == 2 ? 0 : 1)))
                let anchorC = cols / 2

                ZStack {
                    ForEach(0..<(rows * cols), id: \.self) { i in
                        let r = i / cols
                        let c = i % cols
                        let isAnchor = (r == anchorR && c == anchorC)
                        let tint = tints[(r * 7 + c * 3) % tints.count]
                        let x = pad + CGFloat(c) * (side + gap) + side / 2
                        let y = pad + CGFloat(r) * (side + gap) + side / 2

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(
                                isAnchor
                                    ? AnyShapeStyle(Color.blue.gradient)
                                    : AnyShapeStyle(tint.opacity(scheme == .dark ? 0.28 : 0.20))
                            )
                            .overlay(
                                Group {
                                    if isAnchor {
                                        Image(systemName: "viewfinder")
                                            .font(.system(size: min(22, side * 0.34), weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            )
                            .frame(width: side, height: side)
                            .position(x: x, y: y)
                    }
                }
            }
            .clipped()
            .animation(.spring(response: 0.56, dampingFraction: 0.82), value: levelIdx)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.85))
                guard !Task.isCancelled else { break }
                levelIdx += 1
            }
        }
    }
}

// MARK: - Page 3: Real Toolbar Quick Download Popover + Settings JSON Batch Import

private struct DownloadBatchStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0 // 0: quick download popover, 1: quick done, 2: settings JSON import, 3: batch done

    private var inSettings: Bool { phase >= 2 }

    var body: some View {
        MiniAppWindow(selected: inSettings ? .settings : .browse, accent: .cyan) {
            Text(inSettings ? L("place.settings") : L("place.browse"))
                .font(.system(size: 11.5, weight: .semibold))
            Spacer()
            if !inSettings {
                MiniToolbarButton(symbol: "clock")
                MiniToolbarButton(symbol: "arrow.down.circle.fill", active: true, accent: .cyan)
                    .scaleEffect(phase == 0 ? 1.12 : 1.0)
                MiniToolbarButton(symbol: "shuffle")
            } else {
                Text("JSON")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.cyan.opacity(0.16), in: Capsule())
            }
        } bodyContent: {
            if !inSettings {
                // Real Browse layout with Quick Download popover hanging from top-right button
                ZStack(alignment: .topTrailing) {
                    // Dimmed background masonry wireframe
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            VStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).frame(height: 86)
                                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).frame(height: 76)
                            }
                        }
                    }
                    .padding(12)

                    // Actual QuickDownloadCard popover anchored tightly under toolbar download button
                    VStack(alignment: .trailing, spacing: 0) {
                        // Subtle upward pointer triangle aimed straight at the cyan download button
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: 6))
                            p.addLine(to: CGPoint(x: 6, y: 0))
                            p.addLine(to: CGPoint(x: 12, y: 6))
                            p.closeSubpath()
                        }
                        .fill(Color.cyan.opacity(0.45))
                        .frame(width: 12, height: 6)
                        .padding(.trailing, 33)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill").font(.system(size: 13)).foregroundStyle(.cyan)
                                RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.24)).frame(width: 72, height: 6)
                                Spacer()
                            }
                            VStack(spacing: 5) {
                                ForEach(0..<2, id: \.self) { row in
                                    HStack(spacing: 5) {
                                        Image(systemName: "link").font(.system(size: 9)).foregroundStyle(.cyan)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.16)).frame(width: row == 0 ? 124 : 96, height: 5.5)
                                        Spacer()
                                        if phase == 1 {
                                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(.green)
                                        }
                                    }
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 6)
                                    .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                            HStack {
                                Spacer()
                                HStack(spacing: 4) {
                                    Image(systemName: phase == 1 ? "checkmark" : "arrow.down")
                                        .font(.system(size: 9, weight: .bold))
                                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.85)).frame(width: 30, height: 4.5)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background((phase == 1 ? Color.green : Color.cyan).gradient, in: Capsule())
                            }
                        }
                        .padding(12)
                        .frame(width: 224)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .inset(by: 0.5)
                                .stroke(Color.cyan.opacity(0.45), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 12, y: 5)
                    }
                    .padding(.top, 2)
                    .padding(.trailing, 12)
                    .transition(.scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity))
                }
            } else {
                // Real Settings -> Downloads -> JSON Batch Import card
                VStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                            .foregroundStyle(Color.cyan.opacity(0.65))
                            .background(Color.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .frame(height: 68)

                        HStack(spacing: 10) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.cyan.gradient)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("bookmarks.json")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.primary)
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.18)).frame(width: 96, height: 5)
                            }
                        }
                        .offset(y: phase == 2 ? -3 : 0)
                    }

                    VStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { i in
                            HStack(spacing: 8) {
                                Image(systemName: phase == 3 ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(phase == 3 ? .green : .cyan)
                                GeometryReader { bar in
                                    Capsule()
                                        .fill(Color.primary.opacity(0.10))
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(phase == 3 ? Color.green : Color.cyan)
                                                .frame(width: phase == 3 ? bar.size.width : bar.size.width * CGFloat(0.35 + Double(i) * 0.2))
                                        }
                                }
                                .frame(height: 6)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: 340)
                .background(Color.primary.opacity(scheme == .dark ? 0.05 : 0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.82), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.65))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 4
            }
        }
    }
}

// MARK: - Page 4: Real Settings -> AI Models Download & Auto-Tagging

private struct AIModelTagStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var step = 0 // 0: download model, 1: toggle auto-tag ON + scan, 2: purple tags added to card

    var body: some View {
        MiniAppWindow(selected: .settings, accent: .purple) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.purple)
            Text(L("common.aiModels")).font(.system(size: 11.5, weight: .semibold))
            Spacer()
        } bodyContent: {
            HStack(spacing: 14) {
                // Left: Settings -> AI Model Row + Auto-tag toggle
                VStack(spacing: 10) {
                    // Model download row
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().stroke(Color.purple.opacity(0.20), lineWidth: 3).frame(width: 32, height: 32)
                            Circle()
                                .trim(from: 0, to: step == 0 ? 0.58 : 1.0)
                                .stroke(Color.purple, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 32, height: 32)
                            Image(systemName: step == 0 ? "arrow.down" : "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.purple)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.28)).frame(width: 82, height: 6.5)
                            RoundedRectangle(cornerRadius: 2).fill(Color.purple.opacity(0.40)).frame(width: 52, height: 5)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.primary.opacity(scheme == .dark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10))

                    // Auto-tag switch row
                    HStack {
                        Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.purple)
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.24)).frame(width: 64, height: 5.5)
                        Spacer()
                        Capsule()
                            .fill(step >= 1 ? Color.purple : Color.primary.opacity(0.18))
                            .frame(width: 30, height: 17)
                            .overlay(alignment: step >= 1 ? .trailing : .leading) {
                                Circle().fill(.white).frame(width: 13, height: 13).padding(2)
                            }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(Color.primary.opacity(scheme == .dark ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                }
                .frame(width: 210)

                // Right: Live card being analyzed & tagged
                VStack(spacing: 0) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(scheme == .dark ? 0.34 : 0.18), Color.indigo.opacity(scheme == .dark ? 0.18 : 0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Color.purple.opacity(0.55))

                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, Color.purple.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: 18)
                            .offset(y: step == 1 ? 38 : -44)
                            .opacity(step == 1 ? 1 : 0)
                    }
                    .frame(height: 104)
                    .clipped()

                    // Card bottom tag strip receiving AI tags
                    HStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { idx in
                            HStack(spacing: 3) {
                                Image(systemName: "sparkles").font(.system(size: 7.5, weight: .bold))
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.purple.opacity(0.75)).frame(width: CGFloat(18 + idx * 6), height: 4)
                            }
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3.5)
                            .background(Color.purple.opacity(0.16), in: Capsule())
                            .scaleEffect(step == 2 ? 1.0 : 0.5)
                            .opacity(step == 2 ? 1.0 : 0.0)
                            .animation(.spring(response: 0.42, dampingFraction: 0.72).delay(Double(idx) * 0.09), value: step)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(scheme == .dark ? Color(white: 0.18) : Color.white)
                }
                .frame(width: 196)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(Color.purple.opacity(0.32), lineWidth: 1)
                )
            }
            .padding(.horizontal, 16)
        }
        .animation(.spring(response: 0.50, dampingFraction: 0.80), value: step)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { break }
                step = (step + 1) % 3
            }
        }
    }
}

// MARK: - Page 5: Three Tag Types Inside Real Card Tag Strip

private struct TagTrioStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0 // 0: AI tag on card, 1: Mine tag added via +, 2: AI tag approved -> Green Common

    var body: some View {
        VStack(spacing: 20) {
            // Realistic miniature PostCard bottom showing the exact tag strip where tags live
            VStack(spacing: 0) {
                // Media bottom preview
                LinearGradient(
                    colors: [Color.indigo.opacity(scheme == .dark ? 0.30 : 0.15), Color.teal.opacity(scheme == .dark ? 0.22 : 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 58)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.45))
                )

                // Caption pane + real tag strip with + button at the end
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.28)).frame(width: 74, height: 6.5)
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.13)).frame(width: 48, height: 6)
                        Spacer()
                    }

                    HStack(spacing: 7) {
                        // First tag: transitions from Purple AI (✦) -> Green Common (✓) when approved!
                        let approved = phase == 2
                        HStack(spacing: 4) {
                            Image(systemName: approved ? "checkmark" : "sparkles")
                                .font(.system(size: 10, weight: .bold))
                            Text(approved ? L("welcome.p5.chip.common") : L("welcome.p5.chip.ai"))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(approved ? .green : .purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((approved ? Color.green : Color.purple).opacity(0.16), in: Capsule())
                        .overlay(
                            Capsule().inset(by: 0.75).stroke((approved ? Color.green : Color.purple).opacity(0.55), lineWidth: 1.2)
                        )
                        .scaleEffect(phase == 0 || phase == 2 ? 1.06 : 1.0)

                        // Second tag: Blue "Mine" tag added by clicking +
                        if phase >= 1 {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                                Text(L("welcome.p5.chip.mine"))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.16), in: Capsule())
                            .overlay(
                                Capsule().inset(by: 0.75).stroke(Color.blue.opacity(0.55), lineWidth: 1.2)
                            )
                            .transition(.scale.combined(with: .opacity))
                        }

                        Spacer()

                        // Real "+" add-tag button at end of strip
                        Circle()
                            .fill(Color.primary.opacity(phase == 1 ? 0.18 : 0.09))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Image(systemName: "plus")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(phase == 1 ? .blue : .secondary)
                            )
                            .scaleEffect(phase == 1 ? 0.90 : 1.0)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(scheme == .dark ? Color(white: 0.17) : Color.white)
            }
            .frame(width: 390)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(Color.primary.opacity(scheme == .dark ? 0.16 : 0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 12, y: 4)

            // Synchronized 3-origin legend bar
            HStack(spacing: 14) {
                legendChip(icon: "sparkles", label: L("welcome.p5.chip.ai"), color: .purple, active: phase == 0)
                legendChip(icon: "tag.fill", label: L("welcome.p5.chip.mine"), color: .blue, active: phase == 1)
                legendChip(icon: "checkmark.seal.fill", label: L("welcome.p5.chip.common"), color: .green, active: phase == 2)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.78), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 3
            }
        }
    }

    private func legendChip(icon: String, label: String, color: Color, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(active ? 0.20 : 0.09), in: Capsule())
        .overlay(
            Capsule().inset(by: 0.75).stroke(color.opacity(active ? 0.65 : 0.22), lineWidth: active ? 1.3 : 1)
        )
        .scaleEffect(active ? 1.06 : 0.96)
    }
}

// MARK: - Page 6: Multi-Faceted Token Search Inside Real Browse Toolbar

private struct TokenSearchStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var tokenCount = 1

    private struct CardMatch: Identifiable {
        let id: Int
        let hasAI: Bool
        let isVideo: Bool
        let inExcludedFolder: Bool
    }

    private let cards: [CardMatch] = [
        CardMatch(id: 0, hasAI: true, isVideo: true, inExcludedFolder: false),
        CardMatch(id: 1, hasAI: true, isVideo: false, inExcludedFolder: false),
        CardMatch(id: 2, hasAI: true, isVideo: true, inExcludedFolder: true),
        CardMatch(id: 3, hasAI: false, isVideo: true, inExcludedFolder: false),
        CardMatch(id: 4, hasAI: true, isVideo: true, inExcludedFolder: false),
        CardMatch(id: 5, hasAI: true, isVideo: false, inExcludedFolder: true),
    ]

    private func matches(_ c: CardMatch) -> Bool {
        if tokenCount >= 1 && !c.hasAI { return false }
        if tokenCount >= 2 && !c.isVideo { return false }
        if tokenCount >= 3 && c.inExcludedFolder { return false }
        return true
    }

    var body: some View {
        MiniAppWindow(selected: .browse, accent: .indigo) {
            // Real MacTokenSearch capsule right inside the unified toolbar
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if tokenCount >= 1 {
                    tokenPill(symbol: "sparkles", text: L("search.kw.ai.word"), color: .purple)
                }
                if tokenCount >= 2 {
                    tokenPill(symbol: "video", text: L("search.kw.video.word"), color: .blue)
                }
                if tokenCount >= 3 {
                    tokenPill(symbol: "folder", text: "-" + L("search.kw.folder.word"), color: .red)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.05), in: Capsule())
            .overlay(Capsule().inset(by: 0.75).stroke(Color.indigo.opacity(0.40), lineWidth: 1))
        } bodyContent: {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(cards) { c in
                    let hit = matches(c)
                    VStack(spacing: 0) {
                        ZStack {
                            (hit ? Color.indigo.opacity(scheme == .dark ? 0.28 : 0.14) : Color.primary.opacity(scheme == .dark ? 0.05 : 0.035))
                            HStack(spacing: 5) {
                                Image(systemName: c.isVideo ? "play.circle.fill" : "photo.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(hit ? .indigo : .secondary.opacity(0.4))
                                if c.hasAI {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(hit ? .purple : .secondary.opacity(0.3))
                                }
                                if c.inExcludedFolder {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(tokenCount >= 3 ? .red.opacity(0.6) : .secondary.opacity(0.4))
                                }
                            }
                        }
                        .frame(height: 58)

                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(hit ? 0.22 : 0.09)).frame(width: 44, height: 4)
                            Spacer()
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(scheme == .dark ? Color(white: 0.18) : Color.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .inset(by: 0.75)
                            .stroke(hit ? Color.indigo.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: hit ? 1.4 : 0.8)
                    )
                    .scaleEffect(hit ? 1.02 : 0.94)
                    .opacity(hit ? 1.0 : 0.34)
                }
            }
            .padding(14)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.80), value: tokenCount)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.55))
                guard !Task.isCancelled else { break }
                tokenCount = (tokenCount % 3) + 1
            }
        }
    }

    private func tokenPill(symbol: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(color.opacity(0.16), in: Capsule())
        .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Page 7: Decentralized LAN Peer-to-Peer Sync

private struct LanSyncStage: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let p1 = CGFloat((t * 0.45).truncatingRemainder(dividingBy: 1.0))
            let p2 = CGFloat(((t * 0.45) + 0.33).truncatingRemainder(dividingBy: 1.0))
            let p3 = CGFloat(((t * 0.45) + 0.66).truncatingRemainder(dividingBy: 1.0))
            let ripple = CGFloat((t * 0.55).truncatingRemainder(dividingBy: 1.0))

            GeometryReader { geo in
                let cx = geo.size.width / 2
                let cy = geo.size.height / 2 + 6
                let top = CGPoint(x: cx, y: cy - 78)
                let left = CGPoint(x: cx - 134, y: cy + 62)
                let right = CGPoint(x: cx + 134, y: cy + 62)

                ZStack {
                    Circle()
                        .stroke(Color.teal.opacity(Double(1 - ripple) * 0.28), lineWidth: 1.5)
                        .frame(width: 88 + ripple * 170, height: 88 + ripple * 170)
                        .position(x: cx, y: cy)

                    Path { path in
                        path.move(to: top); path.addLine(to: left)
                        path.move(to: left); path.addLine(to: right)
                        path.move(to: right); path.addLine(to: top)
                    }
                    .stroke(
                        Color.teal.opacity(scheme == .dark ? 0.40 : 0.32),
                        style: StrokeStyle(lineWidth: 1.8, dash: [5, 5])
                    )

                    packetDot(from: top, to: left, progress: p1, color: .teal)
                    packetDot(from: left, to: right, progress: p2, color: .blue)
                    packetDot(from: right, to: top, progress: p3, color: .mint)

                    deviceNode(symbol: "laptopcomputer", at: top)
                    deviceNode(symbol: "iphone", at: left)
                    deviceNode(symbol: "desktopcomputer", at: right)
                }
            }
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private func packetDot(from a: CGPoint, to b: CGPoint, progress: CGFloat, color: Color) -> some View {
        let pt = lerp(a, b, progress)
        return Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.65), radius: 5)
            .position(pt)
    }

    private func deviceNode(symbol: String, at point: CGPoint) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(.regularMaterial)
                .frame(width: 60, height: 60)
                .overlay(Circle().inset(by: 0.75).stroke(Color.teal.opacity(0.45), lineWidth: 1.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.08), radius: 8, y: 3)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color.teal.gradient)
                )
            Circle()
                .fill(Color.green)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(scheme == .dark ? Color.black : Color.white, lineWidth: 2))
                .offset(x: -2, y: -2)
        }
        .position(point)
    }
}

// MARK: - Page 8: Import & Export Inside Real Settings -> Backup Layout

private struct ImportExportStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0 // 0: import flowing in, 1: library vault pulse, 2: .tlpack export with shield

    var body: some View {
        MiniAppWindow(selected: .settings, accent: .pink) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.pink)
            Text(L("welcome.p8.badge"))
                .font(.system(size: 11.5, weight: .semibold))
            Spacer()
        } bodyContent: {
            HStack(spacing: 20) {
                // Import sources (folders / ZIP archives)
                VStack(spacing: 10) {
                    sourceChip(symbol: "folder.fill", color: .blue)
                    sourceChip(symbol: "doc.zipper", color: .orange)
                }
                .offset(x: phase == 0 ? 10 : 0)
                .opacity(phase == 0 ? 1.0 : 0.55)

                Image(systemName: "chevron.right.2")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.blue.opacity(phase == 0 ? 0.9 : 0.25))

                // Central Library Vault
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.primary.opacity(scheme == .dark ? 0.07 : 0.04))
                        .frame(width: 86, height: 86)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .inset(by: 0.75)
                                .stroke(Color.pink.opacity(phase == 1 ? 0.65 : 0.26), lineWidth: phase == 1 ? 1.8 : 1)
                        )
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color.pink.gradient)
                }
                .scaleEffect(phase == 1 ? 1.07 : 1.0)

                Image(systemName: "chevron.right.2")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.pink.opacity(phase == 2 ? 0.9 : 0.25))

                // Exported .tlpack archive with verified shield
                VStack(spacing: 7) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.pink.opacity(scheme == .dark ? 0.24 : 0.13))
                            .frame(width: 68, height: 68)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .inset(by: 0.75)
                                    .stroke(Color.pink.opacity(0.45), lineWidth: 1.2)
                            )
                            .overlay(
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(Color.pink.gradient)
                            )
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.green)
                            .background(Circle().fill(scheme == .dark ? Color(white: 0.13) : Color.white).padding(1))
                            .offset(x: 4, y: 4)
                            .scaleEffect(phase == 2 ? 1.0 : 0.4)
                            .opacity(phase == 2 ? 1.0 : 0.0)
                    }
                    Text(".tlpack")
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.pink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(Color.pink.opacity(0.14), in: Capsule())
                }
                .offset(x: phase == 2 ? 6 : -4)
                .opacity(phase == 2 ? 1.0 : 0.55)
            }
            .padding(.horizontal, 16)
        }
        .animation(.spring(response: 0.50, dampingFraction: 0.78), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 3
            }
        }
    }

    private func sourceChip(symbol: String, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(scheme == .dark ? 0.24 : 0.14))
                .frame(width: 48, height: 48)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .inset(by: 0.75)
                        .stroke(color.opacity(0.35), lineWidth: 1)
                )
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(color.gradient)
        }
    }
}
