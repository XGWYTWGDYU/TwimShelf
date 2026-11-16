import XCTest

/// Scenario driver for hitch measurements on a large library (import it beforehand; these tests
/// never import). The app logs hitches with wall-clock times (TL_HITCH_LOG); this test prints the
/// wall-clock window of every phase so the two can be joined.
final class ScrollPerfTests: XCTestCase {
    func testScenarios() {
        let app = XCUIApplication()
        app.launchEnvironment["TL_HITCH_LOG"] = "1"
        if let v = ProcessInfo.processInfo.environment["TL_NO_TIMERS"] { app.launchEnvironment["TL_NO_TIMERS"] = v }
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let manage = app.descendants(matching: .any).matching(identifier: "manage").firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 15))
        sleep(3)
        func phase(_ name: String, _ body: () -> Void) {
            let t0 = Date().timeIntervalSince1970
            body()
            sleep(1)
            print(String(format: "PHASE %@ %.3f %.3f", name, t0, Date().timeIntervalSince1970))
        }
        let feed = app.collectionViews.firstMatch
        phase("feed_scroll") { for _ in 0..<8 { feed.swipeUp(velocity: .fast) } }
        phase("shuffle") { app.buttons["重新随机"].tap(); sleep(2) }
        phase("open_settings") { manage.tap(); _ = app.navigationBars["资料库"].waitForExistence(timeout: 5); sleep(1) }
        let list = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
        phase("settings_scroll") { for _ in 0..<3 { list.swipeUp(velocity: .fast); list.swipeDown(velocity: .fast) } }
        phase("close_settings") {
            let bar = app.navigationBars["资料库"]
            bar.buttons.element(boundBy: bar.buttons.count - 1).tap()
            _ = manage.waitForExistence(timeout: 5)
            sleep(1)
        }
        phase("feed_scroll_after") { for _ in 0..<8 { feed.swipeUp(velocity: .fast) } }
    }
}
