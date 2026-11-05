import SwiftUI

/// 存储空间: a ring of what the app takes, how that compares with the free space, and the parts
/// from largest to smallest. Parts that can be made again or are asked to go have a tick and are
/// cleared together; the library and the app itself are only shown.
struct StorageUsageView: View {
    /// The page's own heading (off where a title bar already says it).
    let showsTitle: Bool
    /// Opens the models' page (the page of 模型 is each app's own).
    let manageModels: () -> Void

    @State private var usage: Core.StorageUsage?
    @State private var error: String?
    @State private var selected = StorageReport.selectedAtFirst
    @State private var expanded: Set<String> = []
    @State private var clearing = false
    @State private var confirming = false
    @State private var result: ClearResult?
    /// Went to manage the models: they may be gone when this page shows again.
    @State private var stale = false

    private struct ClearResult: Identifiable {
        let id = UUID()
        let freed: UInt64
        let skipped: [(path: String, reason: String)]
        var message: String { skipped.prefix(10).map { "\($0.path)\n\($0.reason)" }.joined(separator: "\n\n") }
    }

    private static func color(_ key: String) -> Color { StorageRing.color(key) }

    private var parts: [Core.StorageGroup] { (usage?.groups ?? []).filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes } }
    private var total: Double { max(1, Double(parts.reduce(0) { $0 + $1.bytes })) }
    private var chosen: [Core.StorageGroup] { parts.filter { StorageReport.clearable.contains($0.key) && selected.contains($0.key) } }

    var body: some View {
        VStack(spacing: 0) {
            if usage != nil {
                content
            } else {
                VStack(spacing: 12) {
                    if error == nil { ProgressView() }
                    Text(error.map { L("storage.failed", $0) } ?? L("storage.measuring")).foregroundStyle(.secondary)
                    if error != nil { Button(L("storage.refresh")) { measure() } }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .onAppear {
            if usage == nil || stale { measure() }
            stale = false
        }
        .confirmationDialog(L("storage.clear.title"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L("storage.clear.confirm"), role: .destructive) { clear() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            let freed = StorageReport.bytes(chosen.reduce(0) { $0 + $1.bytes })
            Text(L("storage.clear.message", freed) + (selected.contains("bin") ? "\n" + L("storage.clear.binWarning") : ""))
        }
        .alert(item: $result) { r in
            Alert(title: Text(L("storage.clear.done", StorageReport.bytes(r.freed))),
                  message: r.skipped.isEmpty ? nil : Text(L("storage.clear.skipped") + "\n\n" + r.message))
        }
    }

    @ViewBuilder private var content: some View {
        StorageRing(parts: parts)
            .frame(width: 200, height: 200)
            .padding(.top, 16)
            .accessibilityHidden(true)
        if showsTitle {
            Text(L("storage.title")).font(.system(size: 20, weight: .semibold)).padding(.top, 23)
        }
        Text(summary)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, showsTitle ? 6 : 23)
            .padding(.horizontal, 15)
            .padding(.bottom, 20)

        VStack(spacing: 0) {
            ForEach(Array(parts.enumerated()), id: \.element.key) { i, part in
                if i > 0 { Divider().padding(.leading, 52) }
                row(part)
            }
            let size = chosen.reduce(0) { $0 + $1.bytes }
            Button { confirming = true } label: {
                HStack(spacing: 8) {
                    Text(L("storage.clear.selected")).font(.system(size: 17, weight: .semibold))
                    if size > 0 { Text(StorageReport.bytes(size)).font(.system(size: 17)).opacity(0.75) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
            }
            .blueGlassButton()
            .disabled(size == 0 || clearing)
            .accessibilityIdentifier("storageClear")
            .padding(16)
        }
        .background(cardColor, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

        Text(L("storage.footer"))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        Button(L("storage.refresh")) { measure() }
            .disabled(clearing)
            .padding(.top, 16)
    }

    private var cardColor: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        // the settings canvas is this colour itself: a tone of the text, so the card shows
        Color.primary.opacity(0.05)
        #endif
    }

    private var summary: String {
        let used = UInt64(total)
        let free = StorageReport.freeSpace().map { Double($0) } ?? 0
        return L("storage.usage.summary", StorageReport.bytes(used), free > 0 ? StorageReport.percent(total / free) : "—")
    }

    private func row(_ part: Core.StorageGroup) -> some View {
        let open = expanded.contains(part.key)
        let canClear = StorageReport.clearable.contains(part.key)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                check(part, canClear: canClear)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if open { expanded.remove(part.key) } else { expanded.insert(part.key) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(StorageReport.title(part.key)).foregroundStyle(.primary).lineLimit(1)
                        Text(StorageReport.percent(Double(part.bytes) / total)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(StorageReport.bytes(part.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .padding(.leading, 4)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("storage-" + part.key)
                .padding(.trailing, part.key == "models" ? 8 : 16)
                if part.key == "models" {
                    Button(L("storage.manage")) { stale = true; manageModels() }
                        .font(.system(size: 13))
                        .accessibilityIdentifier("storageManageModels")
                        .padding(.trailing, 16)
                }
            }
            if open {
                Text(StorageReport.detail(part.key) + (part.files > 0 && part.key != "app" ? " · " + L("storage.files", Int(part.files)) : ""))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 52)
                    .padding(.trailing, 16)
                    .padding(.bottom, 10)
            }
        }
    }

    /// A round tick in the part's colour; a plain dot when the part cannot be cleared here.
    @ViewBuilder private func check(_ part: Core.StorageGroup, canClear: Bool) -> some View {
        let color = Self.color(part.key)
        if canClear {
            let on = selected.contains(part.key)
            Button {
                withAnimation(.spring(duration: 0.4)) {
                    if on { selected.remove(part.key) } else { selected.insert(part.key) }
                }
            } label: {
                ZStack {
                    Circle().fill(on ? color : .clear)
                    Circle().strokeBorder(on ? color : Color.secondary.opacity(0.5), lineWidth: 1.5)
                    if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) }
                }
                .frame(width: 22, height: 22)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(clearing)
            .accessibilityLabel(StorageReport.title(part.key))
            .accessibilityValue(L(on ? "a11y.selected" : "a11y.notSelected"))
            .accessibilityIdentifier("storageCheck-" + part.key)
        } else {
            Circle().fill(color).frame(width: 10, height: 10).frame(width: 52, height: 44)
        }
    }

    private func measure() {
        usage = nil; error = nil
        StorageReport.measure { r in
            switch r {
            case .success(let u): usage = u
            case .failure(let e): error = e.localizedDescription
            }
        }
    }

    private func clear() {
        let before = usage?.total ?? 0
        clearing = true
        StorageReport.clear(Set(chosen.map(\.key))) { skipped in
            StorageReport.measure { r in
                clearing = false
                switch r {
                case .success(let u):
                    withAnimation(.spring(duration: 0.4)) { usage = u }
                    result = ClearResult(freed: before > u.total ? before - u.total : 0, skipped: skipped)
                case .failure(let e):
                    error = e.localizedDescription
                    usage = nil
                }
            }
        }
    }
}

extension View {
    /// Blue liquid glass, on systems before it a plain blue button of the same shape.
    @ViewBuilder func blueGlassButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(.blue)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(.blue)
        }
    }
}

/// The ring: a slice per part, its share as a label when it has room. Parts left unticked sit
/// smaller, so the ring shows what stays after clearing.
private struct StorageRing: View {
    let parts: [Core.StorageGroup]

    /// One colour per group that nothing else comes close to, the same as the Flutter app's.
    private static let colors: [Color] = [.indigo, .orange, .red, .brown, .blue, .teal, .purple, .green, .gray]
    static func color(_ key: String) -> Color { colors[(StorageReport.palette[key] ?? 0) % colors.count] }
    private static let inner: CGFloat = 50
    private static let outer: CGFloat = 100
    /// Every part stays visible, however small.
    private static let minAngle = 0.05
    /// A label needs about this much of the ring.
    private static let labelAngle = 0.42

    private struct Slice: Identifiable {
        let id: String
        let start, end: Double
        let radius: CGFloat
        let color: Color
        let label: String
    }

    private var slices: [Slice] {
        let total = max(1, Double(parts.reduce(0) { $0 + $1.bytes }))
        let angles = parts.map { max(Self.minAngle, Double($0.bytes) / total * 2 * .pi) }
        let scale = 2 * .pi / max(angles.reduce(0, +), 0.001)
        var at = -Double.pi / 2
        return parts.enumerated().map { i, part in
            let start = at
            at += angles[i] * scale
            return Slice(id: part.key, start: start, end: at, radius: Self.outer,
                         color: Self.color(part.key),
                         label: StorageReport.percent(Double(part.bytes) / total))
        }
    }

    var body: some View {
        let all = slices
        ZStack {
            ForEach(all) { s in
                RingSlice(start: s.start, end: s.end, inner: Self.inner, outer: s.radius, whole: all.count == 1)
                    .fill(s.color)
            }
            ForEach(all.filter { $0.end - $0.start >= Self.labelAngle }) { s in
                let mid = (s.start + s.end) / 2
                let r = (Self.inner + s.radius) / 2
                Text(s.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .position(x: 100 + r * CGFloat(cos(mid)), y: 100 + r * CGFloat(sin(mid)))
            }
        }
        .frame(width: 200, height: 200)
    }
}

/// A slice of a ring with a 2 pt gap to its neighbours; its outer edge animates.
private struct RingSlice: Shape {
    var start, end: Double
    var inner: CGFloat
    var outer: CGFloat
    var whole: Bool

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGFloat> {
        get { AnimatablePair(AnimatablePair(start, end), outer) }
        set { start = newValue.first.first; end = newValue.first.second; outer = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        let outerGap = whole ? 0 : 1 / Double(outer)
        let innerGap = whole ? 0 : 1 / Double(inner)
        // too thin for the inner gap: it comes to a point rather than turning inside out
        let middle = (start + end) / 2
        let a0 = min(start + outerGap, middle), a1 = max(end - outerGap, middle)
        let b0 = min(start + innerGap, middle), b1 = max(end - innerGap, middle)
        p.addArc(center: c, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .radians(b1), endAngle: .radians(b0), clockwise: true)
        p.closeSubpath()
        return p
    }
}
