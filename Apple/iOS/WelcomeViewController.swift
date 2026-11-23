import SwiftUI
import UIKit

// MARK: - Welcome Presentation Controller (iPhone full screen; iPad a large sheet showing the
// app in its tab bar layout)

@MainActor
enum IOSWelcomeController {
    private static let seenKey = "ios.welcome.seen"
    private static let nextLaunchKey = "ios.welcome.nextLaunch"

    static var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    static var showOnNextLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: nextLaunchKey) }
        set { UserDefaults.standard.set(newValue, forKey: nextLaunchKey) }
    }

    static func showIfFirstLaunch(on host: UIViewController) {
        let scheduled = showOnNextLaunch
        guard !hasSeen || scheduled else { return }
        if scheduled { showOnNextLaunch = false }
        present(on: host)
    }

    static func present(on host: UIViewController) {
        guard host.presentedViewController == nil else { return }
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let vc = UIHostingController(rootView: IOSWelcomeView {
            hasSeen = true
            host.dismiss(animated: true)
        }.environment(\.welcomeTablet, tablet))
        if tablet {
            // a sheet over the app, as the Mac's welcome window over its own
            vc.modalPresentationStyle = .formSheet
            vc.preferredContentSize = CGSize(width: 720, height: 680)
            vc.isModalInPresentation = true
        } else {
            vc.modalPresentationStyle = .fullScreen
        }
        host.present(vc, animated: true)
    }
}

/// The welcome on an iPad: the pages show the app as an iPad shows it (tab bar at the top).
private struct WelcomeTabletKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var welcomeTablet: Bool {
        get { self[WelcomeTabletKey.self] }
        set { self[WelcomeTabletKey.self] = newValue }
    }
}

// MARK: - Page Model

private enum IOSWelcomePage: Int, CaseIterable, Identifiable {
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
        case .randomBrowse: L("welcome.p1.body.mobile")
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

// MARK: - Root iPhone Welcome View

private struct IOSWelcomeView: View {
    var dismiss: () -> Void
    @State private var page = 0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.welcomeTablet) private var tablet

    private var current: IOSWelcomePage { IOSWelcomePage(rawValue: page) ?? .randomBrowse }
    private var total: Int { IOSWelcomePage.allCases.count }
    private var isLast: Bool { page == total - 1 }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .overlay(
                    RadialGradient(
                        colors: [
                            current.accent.opacity(scheme == .dark ? 0.20 : 0.11),
                            Color.clear,
                        ],
                        center: .top,
                        startRadius: 24,
                        endRadius: 420
                    )
                    .animation(.easeInOut(duration: 0.4), value: page)
                )
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: Skip on left, step counter on right
                HStack {
                    if !isLast {
                        Button(L("welcome.skip")) { dismiss() }
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(width: 48, height: 24)
                    }
                    Spacer()
                    Text(L("welcome.step", page + 1, total))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(scheme == .dark ? 0.10 : 0.06), in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Swipeable 8-page TabView (native iOS paging)
                TabView(selection: $page) {
                    ForEach(IOSWelcomePage.allCases) { p in
                        VStack(spacing: 0) {
                            IOSStageCard(accent: p.accent) {
                                stageView(for: p)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: tablet ? 400 : 382)
                            .padding(.horizontal, tablet ? 32 : 20)

                            VStack(spacing: 9) {
                                HStack(spacing: 5) {
                                    Image(systemName: p.symbol)
                                        .font(.system(size: 11.5, weight: .semibold))
                                    Text(p.badge)
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(p.accent)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 4.5)
                                .background(p.accent.opacity(scheme == .dark ? 0.22 : 0.12), in: Capsule())

                                Text(p.title)
                                    .font(.system(size: 23, weight: .bold, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.center)

                                Text(p.body)
                                    .font(.system(size: 14.5))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3.5)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 8)
                            }
                            .padding(.top, 16)
                            .padding(.horizontal, 24)

                            Spacer(minLength: 10)
                        }
                        .tag(p.rawValue)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Page indicator pills + full-width iOS primary button
                VStack(spacing: 16) {
                    HStack(spacing: 7) {
                        ForEach(IOSWelcomePage.allCases) { p in
                            let active = p.rawValue == page
                            Capsule()
                                .fill(active ? current.accent : Color.primary.opacity(scheme == .dark ? 0.24 : 0.16))
                                .frame(width: active ? 22 : 7, height: 7)
                                .animation(.spring(response: 0.34, dampingFraction: 0.78), value: page)
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page = p.rawValue }
                                }
                        }
                    }

                    Button {
                        if isLast {
                            dismiss()
                        } else {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { page += 1 }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(isLast ? L("welcome.done") : L("welcome.next"))
                                .font(.system(size: 16, weight: .semibold))
                            Image(systemName: isLast ? "checkmark" : "arrow.right")
                                .font(.system(size: 13.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(current.accent.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private func stageView(for p: IOSWelcomePage) -> some View {
        switch p {
        case .randomBrowse: IOSShuffleStage()
        case .gridZoom: IOSGridZoomStage()
        case .quickDownload: IOSDownloadStage()
        case .aiModels: IOSAIModelStage()
        case .tagOrigins: IOSTagTrioStage()
        case .tokenSearch: IOSTokenSearchStage()
        case .lanSync: IOSLanSyncStage()
        case .importExport: IOSImportExportStage()
        }
    }
}

private struct IOSStageCard<Content: View>: View {
    let accent: Color
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: scheme == .dark ? .secondarySystemBackground : .secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(scheme == .dark ? 0.16 : 0.08), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.14 : 0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Miniature iPhone Frame (Real iOS 3-Tab Layout: 浏览 / 文件夹 / 设置)

private enum IOSTabItem: CaseIterable {
    case browse, folders, settings

    var symbol: String {
        switch self {
        case .browse: "square.grid.2x2.fill"
        case .folders: "folder.fill"
        case .settings: "gearshape.fill"
        }
    }

    var title: String {
        switch self {
        case .browse: L("place.browse")
        case .folders: L("place.folders")
        case .settings: L("place.settings")
        }
    }
}

private struct MiniPhoneFrame<NavBar: View, BodyContent: View>: View {
    let selected: IOSTabItem
    let accent: Color
    var pulseTab: IOSTabItem? = nil
    var groupedBackground: Bool = false
    @ViewBuilder var navBar: () -> NavBar
    @ViewBuilder var bodyContent: () -> BodyContent
    @Environment(\.colorScheme) private var scheme

    @Environment(\.welcomeTablet) private var tablet

    var body: some View {
        if tablet { tabletBody } else { phoneBody }
    }

    /// An iPad in the tab bar layout: the floating tab bar at the top (浏览, 文件夹, 设置 and the
    /// search tab at its end), 浏览's two buttons on the same row at the right; other pages show
    /// their own bar under it.
    private var tabletBody: some View {
        ZStack {
            (groupedBackground ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: .systemBackground))
            bodyContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                ZStack {
                    HStack(spacing: 1) {
                        ForEach(IOSTabItem.allCases, id: \.self) { tab in
                            let active = tab == selected
                            Text(tab.title)
                                .font(.system(size: 7.5, weight: active ? .semibold : .regular))
                                .foregroundStyle(active ? accent : .primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3.5)
                                .background(Capsule().fill(active ? Color.primary.opacity(scheme == .dark ? 0.16 : 0.08) : Color.clear))
                                .overlay(Capsule().stroke(tab == pulseTab ? accent.opacity(0.75) : Color.clear, lineWidth: 1))
                        }
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 7.5, weight: .medium))
                            .padding(.horizontal, 7)
                    }
                    .padding(2.5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().inset(by: 0.4).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.12), lineWidth: 0.7))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.08), radius: 5, y: 2)
                    if selected == .browse {
                        HStack { Spacer(); navBar() }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 9)
                if selected != .browse {
                    HStack(spacing: 5) { navBar() }
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: 440, height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .inset(by: 0.75)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.24 : 0.15), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.11), radius: 14, y: 6)
    }

    private var phoneBody: some View {
        ZStack {
            // Full-bleed screen content flowing behind floating top chrome & floating Liquid Glass tab bar
            (groupedBackground ? Color(uiColor: .systemGroupedBackground) : Color(uiColor: .systemBackground))

            bodyContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Floating Top Chrome (Dynamic Island + Transparent Floating Header)
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.primary.opacity(scheme == .dark ? 0.28 : 0.88))
                    .frame(width: 46, height: 12)
                    .padding(.top, 7)

                HStack(spacing: 5) {
                    navBar()
                }
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 6)

                Spacer(minLength: 0)
            }

            // Floating iOS 26 Liquid Glass Bottom Tab Bar + Home Indicator
            VStack(spacing: 3.5) {
                Spacer(minLength: 0)

                HStack(spacing: 1) {
                    ForEach(IOSTabItem.allCases, id: \.self) { tab in
                        let active = tab == selected
                        let pulsing = tab == pulseTab
                        VStack(spacing: 0.5) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 8.5, weight: active ? .semibold : .regular))
                                .scaleEffect(pulsing ? 0.84 : 1.0)
                            Text(tab.title)
                                .font(.system(size: 5.5, weight: active ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(active ? accent : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule()
                                .fill(active ? accent.opacity(scheme == .dark ? 0.22 : 0.14) : Color.clear)
                                .overlay(
                                    Capsule()
                                        .stroke(pulsing ? accent.opacity(0.75) : Color.clear, lineWidth: 1)
                                        .scaleEffect(pulsing ? 1.12 : 1.0)
                                )
                        )
                    }
                }
                .padding(2)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .inset(by: 0.4)
                        .stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.12), lineWidth: 0.7)
                )
                .shadow(color: .black.opacity(scheme == .dark ? 0.30 : 0.10), radius: 6, y: 2)
                .padding(.horizontal, 14)

                Capsule()
                    .fill(Color.primary.opacity(0.24))
                    .frame(width: 48, height: 2.5)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: 170, height: 348)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .inset(by: 0.75)
                .stroke(Color.primary.opacity(scheme == .dark ? 0.24 : 0.15), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.38 : 0.11), radius: 14, y: 6)
    }
}

/// Real iPhone Browse floating header (matches FeedViewController.buildBrowseChrome):
/// Large bold title left + Liquid Glass capsule [arrow.down | clock] + separate glass search circle.
private struct MiniBrowseHeader: View {
    var highlightDownload: Bool = false
    var accent: Color = .cyan
    @Environment(\.colorScheme) private var scheme
    @Environment(\.welcomeTablet) private var tablet

    var body: some View {
        // no title (浏览 shows none): the buttons float over the cards
        Spacer(minLength: 4)
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(highlightDownload ? accent : .primary)
                    .scaleEffect(highlightDownload ? 1.16 : 1.0)
                Image(systemName: "clock")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .inset(by: 0.4)
                    .stroke(highlightDownload ? accent.opacity(0.75) : Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.75)
            )

            // (an iPad has search as a tab of its own)
            if !tablet {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.primary)
                    )
                    .overlay(
                        Circle()
                            .inset(by: 0.4)
                            .stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.75)
                    )
            }
        }
    }
}

// MARK: - Page 1: Pull-to-Refresh & Double-Tap Browse Tab

private struct IOSShuffleStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var step = 0
    @State private var pulling = false
    @State private var tabPulse = false

    private struct CardSpec: Identifiable {
        let id: Int
        let color: Color
        let symbol: String
        let heights: [CGFloat]
    }

    private let cards: [CardSpec] = [
        CardSpec(id: 0, color: .orange, symbol: "photo", heights: [92, 68, 82]),
        CardSpec(id: 1, color: .pink, symbol: "play.fill", heights: [68, 94, 72]),
        CardSpec(id: 2, color: .indigo, symbol: "photo.stack", heights: [82, 74, 88]),
        CardSpec(id: 3, color: .teal, symbol: "photo", heights: [72, 84, 66]),
    ]

    private let orders: [[Int]] = [
        [0, 1, 2, 3],
        [3, 0, 2, 1],
        [1, 3, 0, 2],
    ]

    var body: some View {
        MiniPhoneFrame(selected: .browse, accent: .orange, pulseTab: tabPulse ? .browse : nil) {
            MiniBrowseHeader()
        } bodyContent: {
            GeometryReader { geo in
                let order = orders[step % orders.count]
                let pad: CGFloat = 8
                let gap: CGFloat = 6
                let colW = (geo.size.width - pad * 2 - gap) / 2
                let topShift: CGFloat = pulling ? 76 : 54
                let rects = layoutTwoCol(order: order, colW: colW, gap: gap, pad: pad, top: topShift)

                ZStack(alignment: .top) {
                    // Pull-to-refresh spinner emerging under the floating Browse header
                    if pulling {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.orange)
                            .rotationEffect(.degrees(Double(step) * 180))
                            .padding(.top, 55)
                            .transition(.scale.combined(with: .opacity))
                    }

                    ForEach(cards) { card in
                        if let r = rects[card.id] {
                            VStack(spacing: 0) {
                                ZStack(alignment: .topTrailing) {
                                    LinearGradient(
                                        colors: [card.color.opacity(scheme == .dark ? 0.42 : 0.28), card.color.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    Image(systemName: card.symbol)
                                        .font(.system(size: 8.5, weight: .semibold))
                                        .foregroundStyle(card.color)
                                        .padding(5)
                                }
                                .frame(maxHeight: .infinity)
                                HStack {
                                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.20)).frame(width: colW * 0.45, height: 4)
                                    Spacer()
                                }
                                .padding(.horizontal, 6)
                                .frame(height: 15)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).inset(by: 0.5).stroke(Color.primary.opacity(0.08), lineWidth: 0.8))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { break }
                // Alternate between pull-to-refresh and double-tap Browse tab
                if step % 2 == 0 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pulling = true }
                    try? await Task.sleep(for: .milliseconds(420))
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.80)) {
                        pulling = false
                        step += 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.22)) { tabPulse = true }
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.80)) { step += 1 }
                    try? await Task.sleep(for: .milliseconds(360))
                    withAnimation(.easeOut(duration: 0.22)) { tabPulse = false }
                }
            }
        }
    }

    private func layoutTwoCol(order: [Int], colW: CGFloat, gap: CGFloat, pad: CGFloat, top: CGFloat) -> [Int: CGRect] {
        var colY: [CGFloat] = [top, top]
        var out: [Int: CGRect] = [:]
        for id in order {
            let col = colY[0] <= colY[1] ? 0 : 1
            let h = cards[id].heights[step % 3]
            out[id] = CGRect(x: pad + CGFloat(col) * (colW + gap), y: colY[col], width: colW, height: h)
            colY[col] += h + gap
        }
        return out
    }
}

// MARK: - Page 2: iPhone Album Grid Pinch Zoom

private struct IOSGridZoomStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var levelIdx = 1
    private let levels = [5, 3, 2, 3]
    private let tints: [Color] = [.blue, .indigo, .cyan, .teal, .purple, .mint]

    var body: some View {
        let cols = levels[levelIdx % levels.count]
        MiniPhoneFrame(selected: .folders, accent: .blue) {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "chevron.left").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.primary))
                .overlay(Circle().inset(by: 0.4).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.75))
            Text(L("place.photos")).font(.system(size: 12, weight: .bold))
            Spacer()
        } bodyContent: {
            GeometryReader { geo in
                let pad: CGFloat = 3
                let gap: CGFloat = 2
                let topInset: CGFloat = 52
                let side = (geo.size.width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)
                let rows = Int(ceil((geo.size.height - topInset) / (side + gap))) + 1
                let anchorR = max(0, min(rows - 1, rows / 2 - 1))
                let anchorC = cols / 2

                ZStack {
                    ForEach(0..<(rows * cols), id: \.self) { i in
                        let r = i / cols
                        let c = i % cols
                        let isAnchor = (r == anchorR && c == anchorC)
                        let tint = tints[(r * 5 + c * 3) % tints.count]
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(isAnchor ? AnyShapeStyle(Color.blue.gradient) : AnyShapeStyle(tint.opacity(scheme == .dark ? 0.30 : 0.22)))
                            .overlay(
                                Group {
                                    if isAnchor {
                                        Image(systemName: "viewfinder")
                                            .font(.system(size: min(18, side * 0.36), weight: .semibold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            )
                            .frame(width: side, height: side)
                            .position(x: pad + CGFloat(c) * (side + gap) + side / 2, y: topInset + CGFloat(r) * (side + gap) + side / 2)
                    }

                    // Subtle two-finger pinch indicator
                    let spread: CGFloat = cols == 5 ? 14 : (cols == 3 ? 24 : 34)
                    ZStack {
                        Circle().fill(Color.white.opacity(0.85)).frame(width: 14, height: 14).shadow(radius: 4)
                            .offset(x: -spread, y: spread * 0.6)
                        Circle().fill(Color.white.opacity(0.85)).frame(width: 14, height: 14).shadow(radius: 4)
                            .offset(x: spread, y: -spread * 0.6)
                    }
                    .opacity(0.8)
                }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: levelIdx)
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

// MARK: - Page 3: iPhone Quick Download Sheet + Settings JSON Batch Import

private struct IOSDownloadStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0
    private var inSettings: Bool { phase >= 2 }

    var body: some View {
        MiniPhoneFrame(selected: inSettings ? .settings : .browse, accent: .cyan, groupedBackground: inSettings) {
            if !inSettings {
                MiniBrowseHeader(highlightDownload: true, accent: .cyan)
            } else {
                Text(L("place.settings")).font(.system(size: 13.5, weight: .bold))
                Spacer()
            }
        } bodyContent: {
            if !inSettings {
                ZStack(alignment: .bottom) {
                    // Dimmed background feed
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: 80)
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)).frame(height: 80)
                        }
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).frame(height: 70)
                            RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)).frame(height: 70)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 54)

                    // Native iOS Bottom Sheet for Quick Download
                    VStack(spacing: 7) {
                        Capsule().fill(Color.primary.opacity(0.22)).frame(width: 24, height: 3)
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 10.5)).foregroundStyle(.cyan)
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.25)).frame(width: 56, height: 5)
                            Spacer()
                        }
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 4) {
                                Image(systemName: "link").font(.system(size: 8)).foregroundStyle(.cyan)
                                RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.16)).frame(width: row == 0 ? 74 : 58, height: 4.5)
                                Spacer()
                                if phase == 1 {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                        }
                        RoundedRectangle(cornerRadius: 7)
                            .fill((phase == 1 ? Color.green : Color.cyan).gradient)
                            .frame(height: 22)
                            .overlay(
                                Image(systemName: phase == 1 ? "checkmark" : "arrow.down")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                    }
                    .padding(10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 0.5).stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                    .padding(.horizontal, 7)
                    .padding(.bottom, 54)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                VStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .foregroundStyle(Color.cyan.opacity(0.65))
                        .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                        .frame(height: 54)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: "doc.text.fill").font(.system(size: 16)).foregroundStyle(.cyan)
                                Text("bookmarks.json").font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            }
                        )
                    VStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { i in
                            HStack(spacing: 5) {
                                Image(systemName: phase == 3 ? "checkmark.circle.fill" : "arrow.down.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(phase == 3 ? .green : .cyan)
                                GeometryReader { bar in
                                    Capsule().fill(Color.primary.opacity(0.10))
                                        .overlay(alignment: .leading) {
                                            Capsule()
                                                .fill(phase == 3 ? Color.green : Color.cyan)
                                                .frame(width: phase == 3 ? bar.size.width : bar.size.width * CGFloat(0.35 + Double(i) * 0.2))
                                        }
                                }
                                .frame(height: 5)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 56)
                .padding(.bottom, 56)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.65))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 4
            }
        }
    }
}

// MARK: - Page 4: iPhone Settings -> AI Models + Auto-Tag Scan

private struct IOSAIModelStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var step = 0

    var body: some View {
        MiniPhoneFrame(selected: .settings, accent: .purple, groupedBackground: true) {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "chevron.left").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.primary))
                .overlay(Circle().inset(by: 0.4).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.75))
            Text(L("common.aiModels")).font(.system(size: 11, weight: .bold)).lineLimit(1)
            Spacer()
        } bodyContent: {
            VStack(spacing: 9) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().stroke(Color.purple.opacity(0.20), lineWidth: 2).frame(width: 22, height: 22)
                        Circle().trim(from: 0, to: step == 0 ? 0.55 : 1.0)
                            .stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 22, height: 22)
                        Image(systemName: step == 0 ? "arrow.down" : "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(.purple)
                    }
                    VStack(alignment: .leading, spacing: 2.5) {
                        RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.26)).frame(width: 50, height: 5)
                        RoundedRectangle(cornerRadius: 2).fill(Color.purple.opacity(0.4)).frame(width: 34, height: 4)
                    }
                    Spacer(minLength: 2)
                    Capsule()
                        .fill(step >= 1 ? Color.purple : Color.primary.opacity(0.18))
                        .frame(width: 24, height: 14)
                        .overlay(alignment: step >= 1 ? .trailing : .leading) {
                            Circle().fill(.white).frame(width: 10, height: 10).padding(2)
                        }
                }
                .padding(8)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                // Preview card being scanned
                VStack(spacing: 0) {
                    ZStack {
                        LinearGradient(
                            colors: [Color.purple.opacity(scheme == .dark ? 0.34 : 0.18), Color.indigo.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 20, weight: .light)).foregroundStyle(Color.purple.opacity(0.55))
                        Rectangle()
                            .fill(LinearGradient(colors: [.clear, Color.purple.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: 14)
                            .offset(y: step == 1 ? 30 : -34)
                            .opacity(step == 1 ? 1 : 0)
                    }
                    .frame(height: 82)
                    .clipped()

                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { idx in
                            HStack(spacing: 2) {
                                Image(systemName: "sparkles").font(.system(size: 6.5, weight: .bold))
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.purple.opacity(0.7)).frame(width: CGFloat(13 + idx * 4), height: 3.5)
                            }
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2.5)
                            .background(Color.purple.opacity(0.16), in: Capsule())
                            .scaleEffect(step == 2 ? 1 : 0.5)
                            .opacity(step == 2 ? 1 : 0)
                            .animation(.spring(response: 0.4, dampingFraction: 0.72).delay(Double(idx) * 0.08), value: step)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).inset(by: 0.5).stroke(Color.purple.opacity(0.32), lineWidth: 1))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 56)
            .padding(.bottom, 56)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.8), value: step)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { break }
                step = (step + 1) % 3
            }
        }
    }
}

// MARK: - Page 5: Three Tag Types Inside Real iOS Card Strip

private struct IOSTagTrioStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.indigo.opacity(scheme == .dark ? 0.30 : 0.16), Color.teal.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 76)
                .overlay(Image(systemName: "photo").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary.opacity(0.45)))

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.28)).frame(width: 72, height: 6)
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.primary.opacity(0.14)).frame(width: 44, height: 5.5)
                        Spacer()
                    }
                    HStack(spacing: 7) {
                        let approved = phase == 2
                        HStack(spacing: 4) {
                            Image(systemName: approved ? "checkmark" : "sparkles").font(.system(size: 10, weight: .bold))
                            Text(approved ? L("welcome.p5.chip.common") : L("welcome.p5.chip.ai")).font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(approved ? .green : .purple)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((approved ? Color.green : Color.purple).opacity(0.16), in: Capsule())
                        .overlay(Capsule().inset(by: 0.75).stroke((approved ? Color.green : Color.purple).opacity(0.55), lineWidth: 1.2))
                        .scaleEffect(phase == 0 || phase == 2 ? 1.06 : 1.0)

                        if phase >= 1 {
                            HStack(spacing: 4) {
                                Image(systemName: "tag.fill").font(.system(size: 9.5, weight: .semibold))
                                Text(L("welcome.p5.chip.mine")).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.blue.opacity(0.16), in: Capsule())
                            .overlay(Capsule().inset(by: 0.75).stroke(Color.blue.opacity(0.55), lineWidth: 1.2))
                            .transition(.scale.combined(with: .opacity))
                        }
                        Spacer()
                        Circle()
                            .fill(Color.primary.opacity(phase == 1 ? 0.18 : 0.09))
                            .frame(width: 24, height: 24)
                            .overlay(Image(systemName: "plus").font(.system(size: 10.5, weight: .bold)).foregroundStyle(phase == 1 ? .blue : .secondary))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Color(uiColor: .systemBackground))
            }
            .frame(width: 288)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).inset(by: 0.5).stroke(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.08), radius: 12, y: 4)

            HStack(spacing: 10) {
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
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
            Text(label).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5.5)
        .background(color.opacity(active ? 0.20 : 0.09), in: Capsule())
        .overlay(Capsule().inset(by: 0.75).stroke(color.opacity(active ? 0.65 : 0.22), lineWidth: active ? 1.3 : 1))
        .scaleEffect(active ? 1.06 : 0.96)
    }
}

// MARK: - Page 6: iPhone Capsule Token Search

private struct IOSTokenSearchStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var tokenCount = 1

    private struct CardMatch: Identifiable {
        let id: Int; let ai: Bool; let video: Bool; let excl: Bool
    }

    private let cards: [CardMatch] = [
        CardMatch(id: 0, ai: true, video: true, excl: false),
        CardMatch(id: 1, ai: true, video: false, excl: false),
        CardMatch(id: 2, ai: true, video: true, excl: true),
        CardMatch(id: 3, ai: true, video: true, excl: false),
    ]

    private func hit(_ c: CardMatch) -> Bool {
        if tokenCount >= 1 && !c.ai { return false }
        if tokenCount >= 2 && !c.video { return false }
        if tokenCount >= 3 && c.excl { return false }
        return true
    }

    var body: some View {
        MiniPhoneFrame(selected: .browse, accent: .indigo) {
            HStack(spacing: 3) {
                Image(systemName: "magnifyingglass").font(.system(size: 8)).foregroundStyle(.secondary)
                if tokenCount >= 1 {
                    chip(L("search.kw.ai.word"), color: .purple)
                }
                if tokenCount >= 2 {
                    chip(L("search.kw.video.word"), color: .blue)
                }
                if tokenCount >= 3 {
                    chip("-" + L("search.kw.folder.word"), color: .red)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().inset(by: 0.5).stroke(Color.indigo.opacity(0.50), lineWidth: 0.8))

            // Real FeedViewController separate round × exit button beside the search capsule
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "xmark").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.secondary))
                .overlay(Circle().inset(by: 0.4).stroke(Color.primary.opacity(scheme == .dark ? 0.18 : 0.10), lineWidth: 0.75))
        } bodyContent: {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(cards) { c in
                    let ok = hit(c)
                    VStack(spacing: 0) {
                        ZStack {
                            ok ? Color.indigo.opacity(scheme == .dark ? 0.30 : 0.14) : Color.primary.opacity(0.04)
                            HStack(spacing: 3) {
                                Image(systemName: c.video ? "play.circle.fill" : "photo.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(ok ? .indigo : .secondary.opacity(0.4))
                                if c.excl {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 8.5))
                                        .foregroundStyle(tokenCount >= 3 ? .red.opacity(0.6) : .secondary.opacity(0.4))
                                }
                            }
                        }
                        .frame(height: 66)
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(ok ? 0.22 : 0.08)).frame(width: 28, height: 3.5)
                            Spacer()
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).inset(by: 0.75).stroke(ok ? Color.indigo.opacity(0.75) : Color.primary.opacity(0.08), lineWidth: ok ? 1.3 : 0.8))
                    .scaleEffect(ok ? 1.02 : 0.94)
                    .opacity(ok ? 1.0 : 0.34)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 54)
            .padding(.bottom, 56)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: tokenCount)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.55))
                guard !Task.isCancelled else { break }
                tokenCount = (tokenCount % 3) + 1
            }
        }
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .lineLimit(1)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Page 7: Decentralized LAN Peer-to-Peer Sync

private struct IOSLanSyncStage: View {
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
                let cy = geo.size.height / 2 + 8
                let top = CGPoint(x: cx, y: cy - 86)
                let left = CGPoint(x: cx - 98, y: cy + 68)
                let right = CGPoint(x: cx + 98, y: cy + 68)

                ZStack {
                    Circle()
                        .stroke(Color.teal.opacity(Double(1 - ripple) * 0.28), lineWidth: 1.5)
                        .frame(width: 76 + ripple * 160, height: 76 + ripple * 160)
                        .position(x: cx, y: cy)

                    Path { path in
                        path.move(to: top); path.addLine(to: left)
                        path.move(to: left); path.addLine(to: right)
                        path.move(to: right); path.addLine(to: top)
                    }
                    .stroke(Color.teal.opacity(0.36), style: StrokeStyle(lineWidth: 1.8, dash: [5, 5]))

                    packet(top, left, p1, .teal)
                    packet(left, right, p2, .blue)
                    packet(right, top, p3, .mint)

                    node("iphone", at: top)
                    node("ipad", at: left)
                    node("laptopcomputer", at: right)
                }
            }
        }
    }

    private func packet(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat, _ color: Color) -> some View {
        Circle().fill(color).frame(width: 9, height: 9)
            .shadow(color: color.opacity(0.6), radius: 5)
            .position(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    private func node(_ symbol: String, at pt: CGPoint) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .frame(width: 60, height: 60)
                .overlay(Circle().inset(by: 0.75).stroke(Color.teal.opacity(0.45), lineWidth: 1.5))
                .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.08), radius: 8, y: 3)
                .overlay(Image(systemName: symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(Color.teal.gradient))
            Circle()
                .fill(Color.green)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                .offset(x: -2, y: -2)
        }
        .position(pt)
    }
}

// MARK: - Page 8: iPhone Import & Export Backup

private struct IOSImportExportStage: View {
    @Environment(\.colorScheme) private var scheme
    @State private var phase = 0

    var body: some View {
        MiniPhoneFrame(selected: .settings, accent: .pink) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.pink)
            Text(L("welcome.p8.badge")).font(.system(size: 11.5, weight: .bold))
            Spacer()
        } bodyContent: {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    chip("folder.fill", .blue)
                    chip("doc.zipper", .orange)
                }
                .offset(y: phase == 0 ? 6 : 0)
                .opacity(phase == 0 ? 1 : 0.55)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.blue.opacity(phase == 0 ? 0.9 : 0.25))

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 66, height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).inset(by: 0.75).stroke(Color.pink.opacity(phase == 1 ? 0.65 : 0.26), lineWidth: 1.4))
                    .overlay(Image(systemName: "tray.full.fill").font(.system(size: 24)).foregroundStyle(Color.pink.gradient))
                    .scaleEffect(phase == 1 ? 1.08 : 1.0)

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.pink.opacity(phase == 2 ? 0.9 : 0.25))

                HStack(spacing: 8) {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.pink.opacity(0.14))
                            .frame(width: 44, height: 44)
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).inset(by: 0.75).stroke(Color.pink.opacity(0.45), lineWidth: 1))
                            .overlay(Image(systemName: "shippingbox.fill").font(.system(size: 18)).foregroundStyle(Color.pink.gradient))
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                            .background(Circle().fill(Color(uiColor: .systemBackground)).padding(1))
                            .offset(x: 3, y: 3)
                            .scaleEffect(phase == 2 ? 1 : 0.4)
                            .opacity(phase == 2 ? 1 : 0)
                    }
                    Text(".tlpack")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.pink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.pink.opacity(0.14), in: Capsule())
                }
                .offset(y: phase == 2 ? 4 : -4)
                .opacity(phase == 2 ? 1 : 0.55)
            }
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.78), value: phase)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 3
            }
        }
    }

    private func chip(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color.opacity(scheme == .dark ? 0.24 : 0.14))
            .frame(width: 40, height: 40)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).inset(by: 0.75).stroke(color.opacity(0.35), lineWidth: 1))
            .overlay(Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color.gradient))
    }
}
