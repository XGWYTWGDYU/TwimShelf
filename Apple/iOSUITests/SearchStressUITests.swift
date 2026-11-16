import XCTest

/// A search, then a long while of browsing and working in its results: scrolling, turning the
/// pages of cards back and forth, opening and closing media, adding a tag of a card to the search
/// and taking it out again. Every step must answer within a few seconds (a frozen app fails it),
/// slow frames go to the hitch log (TL_HITCH_LOG), and no tag chip grows wider than its card.
/// Run with TEST_RUNNER_TL_LIBRARY_DIR (a library with posts) and TEST_RUNNER_TL_SEARCH (what
/// to search for, typed as in the field: "贴文 猫").
final class SearchStressUITests: XCTestCase {
    private var app: XCUIApplication!
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    /// Waits for `condition`; fails (as a hang) when it does not come within `timeout`.
    private func responds(_ what: String, timeout: TimeInterval = 8, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("no answer within \(Int(timeout)) s: \(what)"); return }
            usleep(150_000)
        }
    }

    /// A chip wider than the card holding it is the stretched pill seen after turning pages.
    private func stretchedChips(in list: XCUIElement) -> [String] {
        var out: [String] = []
        for cell in list.cells.allElementsBoundByIndex where cell.isHittable {
            let width = cell.frame.width
            for b in cell.buttons.allElementsBoundByIndex where b.frame.height < 40 && b.frame.height > 0 {
                if b.frame.width > width - 24 { out.append("\(b.identifier) \(Int(b.frame.width))/\(Int(width))") }
            }
        }
        return out
    }

    func testSearchResultsStress() {
        app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchEnvironment["TL_HITCH_LOG"] = "1"
        // the library may be a copy of a real one: it never syncs with that library's devices
        app.launchEnvironment["TL_SYNC_OFF"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let search = el("search")
        XCTAssertTrue(search.waitForExistence(timeout: 60))
        let list = app.collectionViews.firstMatch
        responds("the feed", timeout: 60) { list.cells.count > 0 }

        let query = ProcessInfo.processInfo.environment["TL_SEARCH"] ?? "贴文 的"
        search.tap()
        search.typeText(query + "\n")
        responds("the search results") { el("searchExit").exists && list.cells.count > 0 }
        sleep(2)
        var stretched: [String] = []
        var opened = 0, turned = 0, added = 0

        for round in 0..<8 {
            // scroll the results, fast and slow
            for _ in 0..<4 { list.swipeUp(velocity: .fast) }
            list.swipeDown(velocity: .slow)
            responds("scrolling (round \(round))") { list.cells.count > 0 }

            // a card with several pages: to its last page and back to the first
            let counters = list.descendants(matching: .any).matching(NSPredicate(format: "label MATCHES '^[0-9]+/[0-9]+$'"))
            if let counter = counters.allElementsBoundByIndex.first(where: { $0.isHittable && !$0.label.hasSuffix("/1") }),
               let pages = Int(counter.label.split(separator: "/").last ?? ""),
               let current = Int(counter.label.split(separator: "/").first ?? ""),
               let media = list.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'media-'")).allElementsBoundByIndex
                   .first(where: { $0.isHittable && abs($0.frame.midY - counter.frame.midY) < $0.frame.height }) {
                for _ in current..<pages { media.swipeLeft(); usleep(350_000) }
                for _ in 1..<pages { media.swipeRight(); usleep(350_000) }
                turned += 1
                usleep(600_000)
                stretched += stretchedChips(in: list)
            }

            // open a media and close it again
            if let media = list.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'media-'")).allElementsBoundByIndex.first(where: { $0.isHittable }) {
                let video = media.identifier == "media-video"
                media.tap()
                let close = video ? el("playerClose") : el("photoClose")
                responds("opening a media (round \(round))") { close.exists }
                if !video { el("photoViewer").swipeLeft(); usleep(400_000) }
                close.tap()
                responds("closing a media (round \(round))") { !close.exists && list.exists }
                opened += 1
            }

            // a card's tag into the search, and out again
            if round % 2 == 0, let tag = list.cells.allElementsBoundByIndex.first(where: { $0.isHittable })?
                .buttons.allElementsBoundByIndex.first(where: { $0.isHittable && !$0.identifier.isEmpty && $0.identifier != "addTag" && $0.identifier != "recentBadge" && !$0.identifier.hasPrefix("media-") }) {
                tag.tap()
                responds("searching a tag (round \(round))") { list.exists }
                added += 1
                // back to the search itself: cleared, and typed again
                el("searchExit").tap()
                responds("clearing the search (round \(round))") { !el("searchExit").exists || el("search").exists }
                search.tap()
                search.typeText(query + "\n")
                responds("the search again (round \(round))") { el("searchExit").exists && list.cells.count > 0 }
            }
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        print("SEARCH-STRESS turned=\(turned) opened=\(opened) added=\(added) stretched=\(stretched)")
        XCTAssertTrue(stretched.isEmpty, "stretched tag chips: \(stretched)")
        XCTAssertGreaterThan(turned + opened, 0, "nothing to work with in the results")
    }
}
