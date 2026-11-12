import SwiftUI

/// The post a media belongs to, shown over the bottom of the full-screen viewer (photo or video)
/// as X does: the author, then the text cut to three lines. A tap on cut text opens all of it
/// (scrollable when long, selectable, with the date), another tap closes it again. Loose media
/// (no post) and posts without author or text show nothing. The same view on iOS and the Mac.
struct PostCaptionView: View {
    let item: FeedItem?
    /// The most the open text may take (the rest of the viewer stays visible above it).
    var maxExpandedHeight: CGFloat = 320
    /// Room kept free on the trailing side (the viewer's buttons sit there).
    var trailingInset: CGFloat = 16
    /// Called when the caption opens or closes (the viewer may hide other controls meanwhile).
    var onExpandedChange: (Bool) -> Void = { _ in }
    /// How tall the caption is: the host fills the viewer's height and lets touches and clicks
    /// above this pass through to the media.
    var onHeight: (CGFloat) -> Void = { _ in }
    /// Opens already (the Mac tour pictures the open caption).
    var startsExpanded = false

    static func shows(_ item: FeedItem?) -> Bool {
        guard let item, !item.isLoose else { return false }
        return !(item.text ?? "").isEmpty || item.authorName != nil || item.screenName != nil
    }

    /// Bottom-aligned in whatever height the host gives it (the host fills the viewer, so the
    /// caption can grow when opened without the host having to be measured again).
    ///
    /// No shade behind it: the text stands on the media with a soft shadow of its own. Moving to
    /// another media of the same post keeps it as it is (still open if it was); another post's
    /// caption fades in as the old one fades out, rather than jumping.
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if let item, Self.shows(item) {
                PostCaptionContent(item: item, maxExpandedHeight: maxExpandedHeight, trailingInset: trailingInset, onExpandedChange: onExpandedChange, expanded: startsExpanded)
                    .id(item.postId + (startsExpanded ? "#open" : ""))      // a new post starts closed
                    .transition(.opacity)
                    .background(GeometryReader { g in Color.clear.preference(key: CaptionHeightKey.self, value: g.size.height) })
            }
        }
        .animation(.easeInOut(duration: 0.22), value: Self.shows(item) ? item?.postId : nil)
        .onPreferenceChange(CaptionHeightKey.self) { onHeight($0) }
    }
}

private struct CaptionHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PostCaptionContent: View {
    let item: FeedItem
    let maxExpandedHeight: CGFloat
    let trailingInset: CGFloat
    let onExpandedChange: (Bool) -> Void
    @State var expanded = false
    @State private var cut = false

    var body: some View { content(item) }

    private func content(_ item: FeedItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            author(item)
            if let text = item.text, !text.isEmpty {
                if expanded {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(PostCaptionView.linked(text))
                                .font(.body)
                                .foregroundStyle(.white)
                                .tint(Color(red: 0.45, green: 0.72, blue: 1))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            if let d = PostCaptionView.dateText(item.createdAt) {
                                Text(d).font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: maxExpandedHeight)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text)
                        .font(.body)
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(truncationProbe(text))
                }
                if cut || expanded {
                    Text(expanded ? L("caption.less") : L("caption.more"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityHidden(true)
                }
            }
        }
        // legible on any picture without a shade: a tight dark edge and a soft halo
        .shadow(color: .black.opacity(0.7), radius: 1.5, y: 0.5)
        .shadow(color: .black.opacity(0.5), radius: 6)
        // a comfortable line length on a wide window
        .frame(maxWidth: 680, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, trailingInset)
        .padding(.top, 28)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard cut || expanded else { return }
            withAnimation(.snappy(duration: 0.28)) { expanded.toggle() }
            onExpandedChange(expanded)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("postCaption")
        .accessibilityValue(expanded ? L("caption.expanded") : L("caption.collapsed"))
        .accessibilityAddTraits(cut || expanded ? .isButton : [])
    }

    private func author(_ item: FeedItem) -> some View {
        HStack(spacing: 6) {
            if let name = item.authorName {
                Text(name).font(.headline).foregroundStyle(.white).lineLimit(1)
            }
            if let sn = item.screenName {
                Text("@" + sn).font(.subheadline).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 8)
        }
    }

    /// Whether three lines cut the text: the whole text laid out at the same width, compared.
    private func truncationProbe(_ text: String) -> some View {
        GeometryReader { limited in
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
                .frame(width: limited.size.width, alignment: .leading)
                .hidden()
                .background(GeometryReader { full in
                    Color.clear
                        .onAppear { cut = full.size.height > limited.size.height + 1 }
                        .onChange(of: full.size.height) { _, h in cut = h > limited.size.height + 1 }
                        .onChange(of: limited.size.height) { _, h in cut = full.size.height > h + 1 }
                })
        }
        .hidden()
    }

}

extension PostCaptionView {
    /// The text with its web links tappable.
    static func linked(_ text: String) -> AttributedString {
        var a = AttributedString(text)
        guard let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return a }
        let ns = text as NSString
        for m in det.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = m.url, let r = Range(m.range, in: text), let ar = Range(r, in: a) else { continue }
            a[ar].link = url
        }
        return a
    }

    /// "3 小时前" for the last week, then the date (and time) in the user's format.
    static func dateText(_ raw: String?) -> String? {
        guard let d = PostDate.parse(raw) else { return nil }
        if Date().timeIntervalSince(d) < 7 * 86_400, d <= Date() {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return f.localizedString(for: d, relativeTo: Date())
        }
        return d.formatted(date: .long, time: .shortened)
    }
}

/// Dates of posts as the sources write them: X's "Fri Oct 24 08:13:11 +0000 2025" (FxTwitter,
/// the legacy 推文内容.txt), ISO 8601, or seconds since 1970.
enum PostDate {
    private static let twitter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let d = twitter.date(from: s) { return d }
        if let d = try? Date(s, strategy: .iso8601) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        if let n = Double(s), n > 1_000_000_000 { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        return nil
    }
}
