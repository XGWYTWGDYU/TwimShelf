import UIKit
import SwiftUI

/// 浏览's search: the capsules in the field (conditions and words), the list of suggestions
/// under it, the field folding into the magnifier, and exporting what a search found. On the
/// search tab's page (`Role.search`) the same code runs with the field always open.
extension FeedViewController {
    // MARK: Between pages

    /// Hands a search to the search tab when this is 浏览 without a search of its own.
    func handOff(_ action: @escaping (FeedViewController) -> Void) -> Bool {
        guard role == .browse, searchElsewhere, let searchHandoff else { return false }
        searchHandoff(action)
        return true
    }

    /// The capsules of the search (to carry it to another layout).
    var searchKeys: [String] { searchField.tokens.compactMap { $0.representedObject as? String } }

    /// Replaces the search with these capsules.
    func setSearch(keys: [String]) {
        loadViewIfNeeded()
        searchField.text = nil
        searchField.tokens = keys.map(makeToken)
        applyTokens()
    }

    /// The search leaves this page (the layout changed and another page has it now): what it
    /// was, and this page back to its unsearched state.
    func takeSearch() -> [String] {
        guard isViewLoaded else { return [] }
        commitTypedText()
        let keys = searchKeys
        searchField.resignFirstResponder()
        exitSearch()
        if !keys.isEmpty { setSearch(keys: []) }
        return keys
    }

    /// The search tab was chosen: with nothing searched yet, the field is ready to type.
    func activateSearch() {
        guard role == .search else { return }
        loadViewIfNeeded()
        // (after this turn: a search handed over with the tab, a tag tapped, fills it first)
        DispatchQueue.main.async { if self.searchKeys.isEmpty { self.searchField.becomeFirstResponder() } }
    }

    // MARK: Search chips

    func textFieldShouldReturn(_ tf: UITextField) -> Bool {
        // the list closes and the cards of the search show (the search tab's page keeps the
        // suggestions while nothing is searched for)
        commitTypedText()
        exitSearch()
        return true
    }

    func textFieldDidBeginEditing(_ tf: UITextField) { enterSearch() }

    /// The field's clear button: the whole search goes, capsules too, and the list comes back.
    func textFieldShouldClear(_ tf: UITextField) -> Bool {
        searchField.tokens = []
        searchField.text = nil
        applyTokens()
        if suggestionsShown { rebuildSuggestions() }
        return false
    }

    /// A term to search for: a capsule in the field.
    func addTerm(_ t: String) {
        if handOff({ $0.addTerm(t) }) { return }
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !terms.contains(t) else { return }
        SearchHistory.add(t)
        insertToken(key: TokenQuery.termKey(t))
        applyTokens()
    }

    func clearTerms() {
        searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("t:") ?? false) }
        query = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
        updateExitButton()
    }

    /// The × beside the bar: the whole search goes (capsules and text) and the list closes.
    func clearSearch() {
        let wasEmpty = searchField.tokens.isEmpty && (searchField.text ?? "").isEmpty
        searchField.tokens = []
        searchField.text = nil
        if role == .search {
            // the search tab's page stays: × empties the field, and a second × puts the keyboard away
            applyTokens()
            if wasEmpty { exitSearch() } else { rebuildSuggestions() }
            return
        }
        if searching {
            exitSearch()
        } else {
            applyTokens()
        }
    }

    /// A tag was renamed: the search follows the new name.
    func replaceTerm(_ old: String, with new: String) {
        for key in [TokenQuery.termKey(old), TokenQuery.minus + TokenQuery.termKey(old)] {
            if let k = searchField.tokens.firstIndex(where: { ($0.representedObject as? String) == key }) {
                searchField.removeToken(at: k)
                searchField.insertToken(makeToken(key.hasPrefix(TokenQuery.minus) ? TokenQuery.minus + TokenQuery.termKey(new) : TokenQuery.termKey(new)), at: k)
            }
        }
        query = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
    }

    /// Once something is searched for, the mascot mode's search icon.
    func updateSearchIcon() {
        if plainSearchIcon == nil { plainSearchIcon = searchField.leftView }
        searchField.leftView = Mascot.isOn && !terms.isEmpty ? UIImageView(image: Mascot.icon("search", side: 24)) : plainSearchIcon
    }

    // MARK: Search mode

    /// Tapping the field: the list of suggestions (or filters) opens under it.
    func enterSearch() {
        guard !searching else { return }
        searching = true
        detachInline()   // (not just paused: a paused video layer can go black)
        loadSuggestionSources()
        view.layoutIfNeeded()   // the field's final place (it may have just unfolded) before the list is placed under it
        showSuggestions(true, animated: true)
        updateExitButton()
    }

    /// The tags and folders the suggestions offer, fresh each time the list opens.
    func loadSuggestionSources() {
        Task { [weak self] in
            let (tags, folders) = await Task.detached { (Core.allTags(), Core.folders()) }.value
            guard let self, self.searching || self.role == .search else { return }
            self.tagCache = tags
            self.folderCache = folders
            self.rebuildSuggestions()
        }
        rebuildSuggestions()
    }

    func showSuggestions(_ show: Bool, animated: Bool) {
        let show = show || (role == .search && searchKeys.isEmpty)
        if show {
            if !suggestionsShown { suggestions.scrollToTop() }
            suggestionsShown = true
            suggestions.isHidden = false
            suggestions.superview?.bringSubviewToFront(suggestions)
            searchChrome.superview?.bringSubviewToFront(searchChrome)
            searchChrome.bringSubviewToFront(exitButton)
            searchChrome.bringSubviewToFront(exportButton)
            let appear = { self.suggestions.alpha = 1 }
            if animated { UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: appear) } else { appear() }
            return
        }
        guard suggestionsShown else { return }
        suggestionsShown = false
        let hide = { self.suggestions.alpha = 0 }
        let done = {
            if !self.suggestionsShown { self.suggestions.isHidden = true }
            self.view.bringSubviewToFront(self.activityPanel)
            self.view.bringSubviewToFront(self.toast)
            self.updateInlinePlayback()
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, animations: hide) { _ in done() }
        } else { hide(); done() }
    }

    /// Return or another tab: the list closes; the search itself stays.
    func exitSearch() {
        searchField.resignFirstResponder()
        guard searching else { return }
        searching = false
        unfolded = false
        commitTypedText()
        updateExitButton()
        showSuggestions(false, animated: true)
    }

    @objc func searchTextChanged() {
        if searchField.markedTextRange == nil {
            // a word followed by a space becomes a capsule (a condition, or text to search for)
            let (keys, rest) = TokenQuery.split(searchField.text ?? "")
            if !keys.isEmpty {
                for k in keys { addKey(k) }
                searchField.text = rest
            }
            applyTokens()
        }
        if suggestionsShown { rebuildSuggestions() }
    }

    /// A capsule from typed text. A word right after a pending L("place.folders") capsule names the folder
    /// (matched to an existing folder regardless of case); a second folder replaces the first.
    func addKey(_ key: String) {
        var k = key
        let last = searchField.tokens.last?.representedObject as? String
        // a word right after a pending L("place.folders") (or "-文件夹") names the folder
        if k.hasPrefix("t:") || k.hasPrefix(TokenQuery.minus + "t:"), last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder {
            searchField.removeToken(at: searchField.tokens.count - 1)
            let word = k.hasPrefix(TokenQuery.minus) ? String(k.dropFirst(3)) : String(k.dropFirst(2))
            k = (last == TokenQuery.pendingFolder ? "" : TokenQuery.minus) + TokenQuery.folderKey(word)
        }
        let negative = k.hasPrefix(TokenQuery.minus)
        let bare = negative ? String(k.dropFirst()) : k
        if bare.hasPrefix("d:") {
            let typed = String(bare.dropFirst(2))
            let name = folderCache.first { $0.name.lowercased() == typed.lowercased() }?.name ?? typed
            k = (negative ? TokenQuery.minus : "") + TokenQuery.folderKey(name)
            // one folder to look in (a new one replaces it); folders to leave out add up
            if !negative { searchField.tokens = searchField.tokens.filter { !(($0.representedObject as? String)?.hasPrefix("d:") ?? false) } }
        }
        guard !searchField.tokens.contains(where: { ($0.representedObject as? String) == k }) else { return }
        if bare.hasPrefix("t:") {
            let t = String(bare.dropFirst(2)).lowercased()
            k = (negative ? TokenQuery.minus : "") + TokenQuery.termKey(t)
            if !negative { SearchHistory.add(t) }
        }
        insertToken(key: k)
    }

    /// Text left in the field when the search closes becomes a capsule too (the last word may
    /// be a condition, or a folder's name after L("place.folders"), typed without a space after it).
    func commitTypedText() {
        let t = (searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        searchField.text = nil
        if !t.isEmpty { addKey(TokenQuery.key(for: t, after: nil)) }
        // a L("place.folders") capsule still waiting for a name means nothing: it goes
        if let last = searchField.tokens.last?.representedObject as? String, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder { searchField.removeToken(at: searchField.tokens.count - 1) }
        applyTokens()
    }

    /// What a capsule reads (VoiceOver: with "排除" for a minus capsule).
    func tokenTitle(_ key: String) -> String { TokenQuery.spoken(key) }

    /// A capsule: its symbol (a minus capsule a ⊖) and title.
    func makeToken(_ key: String) -> UISearchToken {
        let icon = TokenQuery.symbol(key).flatMap { UIImage(systemName: $0) }
        let token = UISearchToken(icon: TokenQuery.isExcluded(key) ? icon?.withTintColor(.systemRed, renderingMode: .alwaysOriginal) : icon, text: TokenQuery.title(key))
        token.representedObject = key
        return token
    }

    func insertToken(key: String) {
        searchField.insertToken(makeToken(key), at: searchField.tokens.count)
    }

    /// The capsules decide the search: conditions, then the texts (all must match).
    func applyTokens() {
        let q = TokenQuery(keys: searchField.tokens.compactMap { $0.representedObject as? String })
        let changed = q != query
        query = q
        updateExitButton()
        guard changed else { return }
        updateSearchIcon()
        // the search tab's page: the suggestions while nothing is searched for, else the cards
        if role == .search && !searching { showSuggestions(false, animated: true) }
        reload()
    }

    /// The × shows while searching and while a search is in effect; it also says (to VoiceOver)
    /// what the search is.
    func updateExitButton() {
        let words = searchField.tokens.compactMap { ($0.representedObject as? String).map(tokenTitle) } + [searchField.text ?? ""].filter { !$0.isEmpty }
        syncSearchFold(animated: true)
        guard !folding else { return }
        // the search tab's page has no × to leave by (another tab leaves it); the field's own
        // clear button empties it
        let show = role == .browse && (searching || !words.isEmpty)
        // exporting is offered while a search or a filter is in effect (not while only typing begins)
        let showExport = !words.isEmpty || !currentFilter.isEmpty
        // These buttons are siblings of the header, so hiding the header cannot hide them.
        exitButton.isHidden = !show
        exportButton.isHidden = !showExport
        exitButton.accessibilityValue = words.joined(separator: L("list.separator"))
        guard show != exitShown || showExport != exportShown else { return }
        exitShown = show; exportShown = showExport
        // switch the old constraints off before the new ones on (never two required ones at odds)
        [headerTrailing, headerBesideExit, headerBesideExport, exportBesideExit, exportAtEdge].forEach { $0?.isActive = false }
        headerTrailing.isActive = !show && !showExport
        headerBesideExit.isActive = show && !showExport
        headerBesideExport.isActive = showExport
        exportBesideExit.isActive = show
        exportAtEdge.isActive = !show
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            for (b, on) in [(self.exitButton, show), (self.exportButton, showExport)] {
                b.alpha = on ? 1 : 0
                b.transform = on ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            }
            self.view.layoutIfNeeded()
        } completion: { _ in
            if !self.exitShown && self.exitButton.alpha == 0 { self.exitButton.isHidden = true }
            if !self.exportShown && self.exportButton.alpha == 0 { self.exportButton.isHidden = true }
        }
    }

    // MARK: Export of a search

    /// The export button: a small popover (the switches, then 导出) for exactly the media the
    /// search shows now.
    func showExport() {
        searchField.resignFirstResponder()
        guard shownGeneration == reloadGeneration else { return alert(L("search.busy.title"), L("search.busy.message")) }
        let ids = allItems.map(\.mediaId)
        let host = UIHostingController(rootView: SearchExportView(count: ids.count) { [weak self] in
            self?.dismiss(animated: true) {
                let options = SearchExportPrefs.options
                self?.exportAndShare(fileName: SearchExportPrefs.fileName(terms: self?.query.terms ?? [])) { out in try Core.exportMedia(ids, options: options, to: out) }
            }
        })
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .popover
        host.sizingOptions = .preferredContentSize
        if let pop = host.popoverPresentationController {
            let anchor = exportButton
            pop.sourceView = anchor
            pop.sourceRect = anchor.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = self
        }
        present(host, animated: true)
    }

    /// A real popover on the iPhone too (not a full sheet).
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle { .none }

    func updatePlaceholder() {
        searchField.placeholder = L("search.placeholder")
    }

    func updateSuggestionFooter() {
        let stats = ActivityCenter.shared.statsLine
        suggestions.setFooter((stats.isEmpty ? "" : stats + "\n") + SearchHighlight.guide)
    }

    func rebuildSuggestions() {
        let typed = (searchField.text ?? "").trimmingCharacters(in: .whitespaces)
        suggestions.sections = tokenSuggestions(typed)
        updateSuggestionFooter()
    }

    /// The shared list (conditions, words, tags, folders, recent searches; with a minus typed,
    /// the same as exclusions) as system list rows.
    func tokenSuggestions(_ typed: String) -> [SearchSuggestionsView.Section] {
        let keys = searchField.tokens.compactMap { $0.representedObject as? String }
        return SearchSuggestions.sections(typed: typed, keys: keys, tags: tagCache, folders: folderCache).map { sec in
            .init(title: sec.title, rows: sec.rows.map { r in
                let tint: UIColor = switch r.tint { case .accent: .tintColor; case .folder: .systemTeal; case .secondary: .secondaryLabel; case .exclude: .systemRed }
                return SearchSuggestionsView.Row(id: r.id, title: r.title, subtitle: r.subtitle, symbol: r.symbol, tint: tint, destructive: r.destructive,
                                                 action: r.action.map { a in { [weak self] in self?.perform(a) } })
            })
        }
    }

    func perform(_ a: SearchSuggestion.Action) {
        switch a {
        case .key(let k):
            searchField.text = nil
            addKey(k)
            applyTokens()
        case .folder(let name, let excluded):
            searchField.text = nil
            // the pending L("place.folders") capsule gives way to the folder
            if let last = searchField.tokens.last?.representedObject as? String, last == TokenQuery.pendingFolder || last == TokenQuery.minus + TokenQuery.pendingFolder {
                searchField.removeToken(at: searchField.tokens.count - 1)
            }
            addKey((excluded ? TokenQuery.minus : "") + TokenQuery.folderKey(name))
            applyTokens()
        case .clearHistory:
            SearchHistory.clear()
        }
        rebuildSuggestions()
    }
}
