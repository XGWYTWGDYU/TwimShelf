import XCTest

/// A card of 浏览 follows the page it shows, with the finger, on a narrow and on a wide screen.
/// Run with TEST_RUNNER_TL_LIBRARY_DIR (a fresh folder) and TEST_RUNNER_TL_IMPORT_DIR (synthetic
/// post folders; the first post has pictures of different shapes).
final class CardPagesUITests: XCTestCase {
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
        let group = app.buttons["groupToggle"], sort = app.buttons["sortByAdded"]
        XCTAssertTrue(group.waitForExistence(timeout: 30))
        sleep(3)
        let list = app.collectionViews.firstMatch
        for i in 0..<40 {
            switch i % 5 {
            case 0: group.tap()
            case 1: sort.tap()
            case 2: list.swipeUp(velocity: .fast)
            case 3: group.tap(); sort.tap()
            default: list.swipeDown(velocity: .fast)
            }
            usleep(i % 3 == 0 ? 100_000 : 800_000)
            if !group.isHittable { list.swipeDown(velocity: .fast); usleep(500_000) }
        }
        sleep(2)
    }

    /// The quick download card: a picture of its glass.
    func testQuickDownloadCardPicture() {
        let app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let button = app.buttons["quickDownload"]
        XCTAssertTrue(button.waitForExistence(timeout: 30))
        sleep(3)
        button.tap()
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
        XCTAssertTrue(app.buttons["groupToggle"].waitForExistence(timeout: 30))
        sleep(4)
        let list = app.collectionViews.firstMatch
        for _ in 0..<10 { list.swipeUp(velocity: .fast) }
        for _ in 0..<10 { list.swipeDown(velocity: .fast) }
        for _ in 0..<6 { list.swipeUp(velocity: .slow) }
        sleep(1)
    }
}
