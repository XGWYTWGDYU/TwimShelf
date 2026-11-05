import SwiftUI

/// The tag adder (the "+" pill, and the menus' "添加标签" items), the same on iPhone, iPad and
/// Mac: a sheet on iOS, a floating popover on the Mac. Type to filter the existing tags (yours
/// first, then by popularity) or to create one; Return adds what is typed (or closes when nothing
/// is). It stays open so several tags can go on in a row. For a media of a post, the segmented
/// control at the top switches between this media and the whole post.
@MainActor
final class TagPickerModel: ObservableObject {
    let media: FeedItem
    @Published private(set) var scope: Core.MediaScope
    @Published var wholePost: Bool { didSet { if wholePost != oldValue { added = [] } } }
    @Published var query = ""
    @Published private(set) var all: [TagCount] = []
    @Published private(set) var added: [String] = []
    @Published var error: String?
    /// After every added tag (the page refreshes its cards).
    var onChange: () -> Void = {}

    init(media: FeedItem, scope: Core.MediaScope, wholePost: Bool) {
        self.media = media
        self.scope = scope
        self.wholePost = wholePost && !media.isLoose
        Task { [weak self] in
            let tags = await Task.detached { Core.allTags() }.value
            self?.all = tags
        }
    }

    var targetIDs: [String] { wholePost ? scope.ids : [media.mediaId] }
    private var existing: Set<String> { scope.commonTags(targetIDs) }
    var trimmed: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    var canCreate: Bool { !trimmed.isEmpty && !all.contains { $0.label == trimmed } && !existing.contains(trimmed) }
    var suggestions: [TagCount] {
        let q = trimmed
        return Array(all.filter { !existing.contains($0.label) && (q.isEmpty || $0.label.contains(q)) }.userFirst.prefix(40))
    }
    func taggedText(_ t: TagCount) -> String { L("tagPicker.tagged", scope.taggedCount(t.label, ids: targetIDs), targetIDs.count) }

    /// Adds a tag to the media (or the post); false when it could not be added.
    @discardableResult
    func add(_ label: String) -> Bool {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty, !existing.contains(l) else { return false }
        do { try Core.action(.tag, media: wholePost ? [] : [media.mediaId], posts: wholePost ? [media.postId] : [], label: l) }
        catch { self.error = error.localizedDescription; return false }
        if let refreshed = try? Core.postScope(media.postId) { scope = refreshed }
        added.append(l)
        query = ""
        onChange()
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
        return true
    }
}

struct TagPickerView: View {
    @ObservedObject var model: TagPickerModel
    /// Closes the sheet or popover.
    var onDone: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            list
        }
        .background(Color.clear)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
        .alert(L("tagPicker.error"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L("common.ok"), role: .cancel) {}
        } message: { Text(model.error ?? "") }
    }

    @ViewBuilder private var titleOrScope: some View {
        if model.media.isLoose {
            Text(L("tagPicker.title")).font(.headline).lineLimit(1).fixedSize()
        } else {
            Picker("", selection: $model.wholePost) {
                Text(L("tagPicker.thisMedia")).tag(false)
                Text(L("tagPicker.wholePost", model.scope.ids.count)).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("tagPickerScope")
        }
    }

    private var doneLabel: some View { Text(L("common.done")).fontWeight(.semibold) }

    private var doneButton: some View {
        Button(action: onDone) { doneLabel }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("pickerDone")
    }

    /// Title (or the media / post switch), the pending note, and 完成.
    private var header: some View {
        VStack(spacing: 8) {
            if model.media.isLoose {
                // the title sits between 完成 and a hidden copy of it, so it stays centred and never
                // runs under 完成; a translation too long for that moves it to the leading side
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        // a copy without the shortcut, so Esc closes once
                        Button(action: {}) { doneLabel }.disabled(true).hidden().accessibilityHidden(true)
                        Spacer(minLength: 0)
                        titleOrScope
                        Spacer(minLength: 0)
                        doneButton
                    }
                    HStack(spacing: 8) { titleOrScope; Spacer(minLength: 0); doneButton }
                }
            } else {
                // the switch lines up with the search field below, 完成 at the other end; in every
                // language, whatever the length of its titles
                HStack(spacing: 8) { titleOrScope; Spacer(minLength: 8); doneButton }
            }
            if model.scope.pendingCount > 0 {
                Text(L("tagPicker.pending", model.scope.pendingCount)).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("tagPicker.placeholder"), text: $model.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                #endif
                .onSubmit {
                    if model.trimmed.isEmpty { onDone() } else { model.add(model.query) }
                    focused = true
                }
                .accessibilityIdentifier("tagPickerField")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("common.clear"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    private var list: some View {
        List {
            if model.canCreate {
                Section {
                    Button { model.add(model.query) } label: {
                        row(icon: "plus.circle.fill", tint: .accentColor, title: L("tagPicker.create", model.trimmed), titleColor: .accentColor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tagPickerCreate")
                }
            }
            if !model.added.isEmpty {
                Section(L("tagPicker.justAdded")) {
                    ForEach(model.added, id: \.self) { a in row(icon: "checkmark.circle.fill", tint: .green, title: a) }
                }
            }
            if !model.suggestions.isEmpty {
                Section(model.trimmed.isEmpty ? L("tagPicker.frequent") : L("tagPicker.matching")) {
                    ForEach(model.suggestions, id: \.label) { t in
                        Button { model.add(t.label) } label: {
                            row(icon: t.ai > 0 && t.user == 0 ? "sparkles" : "tag", tint: .accentColor, title: t.label, detail: model.taggedText(t))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("tagPickerRow-" + t.label)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        #else
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        #endif
        .animation(.snappy(duration: 0.25), value: model.added)
    }

    /// One list row: symbol, label, and the "n/m 已添加" count on the trailing side.
    private func row(icon: String, tint: Color, title: String, titleColor: Color = .primary, detail: String? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            Text(title).foregroundStyle(titleColor).lineLimit(1)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).monospacedDigit() }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}
