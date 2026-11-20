import XCTest

/// A card of 浏览 follows the page it shows, with the finger, on a narrow and on a wide screen.
/// Run with TEST_RUNNER_TL_LIBRARY_DIR (a fresh folder) and TEST_RUNNER_TL_IMPORT_DIR (synthetic
/// post folders; the first post has pictures of different shapes).
final class CardPagesUITests: XCTestCase {
    func testSingleSearchSuggestionAfterRotation() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad dropdown")
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        if let directory = ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] {
            app.launchEnvironment["TL_LIBRARY_DIR"] = directory
        }
        app.launch()
        let search = app.buttons["searchButton"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        let field = app.textFields["search"].firstMatch
        field.typeText("啊")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(field.value as? String, "啊")
        let suggestion = app.tables["searchSuggestions"].cells.firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        let rotated = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        rotated.name = "Single search suggestion after rotation"
        rotated.lifetime = .keepAlways
        add(rotated)
    }

    func testLandscapeTabsRestoreBrowseWithoutMovingTheFirstCard() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad tab bar layout")
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] {
            if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v }
        }
        app.launchEnvironment["TL_SEARCH_LAYOUT_STATE"] = "landscape-tabs"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }

        let search = app.buttons["searchButton"].firstMatch
        let sort = app.buttons["sortByAdded"].firstMatch
        let download = app.buttons["quickDownload"].firstMatch
        let title = app.staticTexts["browseTitle"].firstMatch
        let sharedRow = NSPredicate { _, _ in
            search.exists && sort.exists && download.exists && !title.exists && search.frame.midY < 100 && app.frame.width > app.frame.height
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sharedRow, object: app)], timeout: 20), .completed)
        let card = app.collectionViews["browseCards"].cells.firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        let originalTop = card.frame.minY

        search.tap()
        let suggestions = app.descendants(matching: .any)["searchSuggestions"].firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5))
        XCTAssertLessThan(suggestions.frame.width, app.frame.width / 2)
        let dropdown = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        dropdown.name = "Landscape search dropdown"
        dropdown.lifetime = .keepAlways
        add(dropdown)
        XCTAssertFalse(download.exists)
        let field = app.textFields["search"].firstMatch
        field.typeText("sam")
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(field.value as? String, "sam")
        field.typeText("ple\n")
        XCTAssertTrue(suggestions.exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5))
        XCTAssertLessThan(suggestions.frame.width, app.frame.width / 2)
        let close = app.buttons["searchExit"].firstMatch
        XCTAssertTrue((close.value as? String)?.contains("sample") == true)
        close.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sharedRow, object: app)], timeout: 5), .completed)
        XCTAssertFalse(suggestions.exists)
        XCTAssertEqual(card.frame.minY, originalTop, accuracy: 1)

        let toggle = app.buttons.matching(NSPredicate(format: "identifier ==[c] %@", "ToggleSidebar")).firstMatch
        let actions = [download, sort, search]
        let frames = actions.map(\.frame)
        XCTAssertTrue(toggle.isHittable)
        toggle.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(actions.map(\.frame), frames)
        let sidebarTop = card.frame.minY
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sharedRow, object: app)], timeout: 5), .completed)
        XCTAssertEqual(actions.map(\.frame), frames)
        XCTAssertLessThanOrEqual(card.frame.minY, sidebarTop + 1)
        XCTAssertEqual(card.frame.minY, originalTop, accuracy: 1)

        toggle.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        app.collectionViews["browseCards"].swipeUp()
        toggle.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: sharedRow, object: app)], timeout: 5), .completed)
        let frost = app.descendants(matching: .any)["topFrost"].firstMatch
        if frost.exists {
            XCTAssertLessThanOrEqual(frost.frame.maxY, search.frame.maxY + 7)
        }

        // Portrait + tab bar also places the three buttons in the top-right bar row without the title.
        XCUIDevice.shared.orientation = .portrait
        let portraitRow = NSPredicate { _, _ in
            search.exists && sort.exists && download.exists && !title.exists && search.frame.midY < 100 && app.frame.height > app.frame.width
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: portraitRow, object: app)], timeout: 10), .completed)
    }

    func testCardFollowsThePage() {
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let photo = app.descendants(matching: .any).matching(identifier: "media-photo")
        XCTAssertTrue(photo.firstMatch.waitForExistence(timeout: 30))
        // the card with several pages: the widest of the first shapes is found by swiping
        var seen: [CGFloat] = []
        var card: XCUIElement?
        for i in 0..<photo.count where photo.element(boundBy: i).isHittable {
            let e = photo.element(boundBy: i)
            let before = e.frame.height
            e.swipeLeft()
            usleep(900_000)
            let after = app.descendants(matching: .any).matching(identifier: "media-photo").allElementsBoundByIndex.first { $0.isHittable && abs($0.frame.minX - e.frame.minX) < e.frame.width / 2 && abs($0.frame.minY - e.frame.minY) < 4 }
            if let a = after, abs(a.frame.height - before) > 8 { seen = [before, a.frame.height]; card = a; break }
        }
        XCTAssertFalse(seen.isEmpty, "no card changed height when its page was turned")
        guard let card else { return }
        let x = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        x.lifetime = .keepAlways
        add(x)
        // and back: the first height again
        card.swipeRight()
        usleep(900_000)
        let back = app.descendants(matching: .any).matching(identifier: "media-photo").allElementsBoundByIndex.first { $0.isHittable && abs($0.frame.minX - card.frame.minX) < card.frame.width / 2 && abs($0.frame.minY - card.frame.minY) < 4 }
        XCTAssertEqual(back?.frame.height ?? 0, seen[0], accuracy: 2)
    }

    /// The buttons on top, over and over with scrolling between: TL_FEED_CHECK collects what the
    /// feed itself finds wrong.
    func testButtonsOnTopKeepTheCards() {
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR", "TL_FEED_CHECK"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let sort = app.buttons["sortByAdded"].firstMatch
        XCTAssertTrue(sort.waitForExistence(timeout: 30))
        sleep(3)
        let list = app.collectionViews.firstMatch
        for i in 0..<24 {
            switch i % 3 {
            case 0: sort.tap()
            case 1: list.swipeUp(velocity: .fast)
            default: list.swipeDown(velocity: .fast)
            }
            usleep(i % 3 == 0 ? 150_000 : 800_000)
            if !sort.isHittable { list.swipeDown(velocity: .fast); usleep(500_000) }
        }
        sleep(2)
    }

    /// The quick download card: a picture of its glass.
    func testQuickDownloadCardPicture() {
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let download = app.buttons["quickDownload"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 30))
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "Before opening quick download"
        before.lifetime = .keepAlways
        add(before)
        download.tap()
        XCTAssertTrue(app.descendants(matching: .any)["quickDownloadLinks"].waitForExistence(timeout: 5))
        sleep(1)
        let x = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        x.lifetime = .keepAlways
        add(x)
    }

    /// Scrolling and turning pages, for the hitch log (TL_HITCH_LOG): with TL_NO_CARD_GLASS set,
    /// the same without the glass on the cards.
    func testScrollForHitches() {
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR", "TL_NO_CARD_GLASS"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchEnvironment["TL_HITCH_LOG"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["searchButton"].firstMatch.waitForExistence(timeout: 30))
        sleep(4)
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 { list.swipeUp(velocity: .fast) }
        for _ in 0..<10 { list.swipeDown(velocity: .fast) }
        for _ in 0..<6 { list.swipeUp(velocity: .slow) }
        sleep(1)
    }
}
