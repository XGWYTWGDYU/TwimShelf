import XCTest

/// End to end: Photos → Share → 导入 TwimShelf → the app imports the shared HEIC and MOV
/// as loose media. Needs media added to the simulator's Photos first (`xcrun simctl addmedia`),
/// so it runs only when TEST_RUNNER_TL_SHARE_TEST=1.
final class ShareExtensionUITests: XCTestCase {
    func testShareFromPhotosImportsLooseMedia() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TL_SHARE_TEST"] != nil, "set TEST_RUNNER_TL_SHARE_TEST=1 (and add media to Photos)")
        continueAfterFailure = false
        // our app first, so the share inbox exists and imports are observed
        let app = XCUIApplication()
        app.launchEnvironment["TL_RESET_UI_STATE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        // the totals are at the end of the list under the search field
        func totals() -> String {
            let field = app.descendants(matching: .any).matching(identifier: "search").firstMatch
            if field.waitForExistence(timeout: 5) { field.tap() }
            let t = app.descendants(matching: .any).matching(identifier: "statsLine").firstMatch.label
            let cancel = app.descendants(matching: .any).matching(identifier: "searchCancel").firstMatch
            if cancel.exists { cancel.tap() }
            return t
        }
        let looseBefore = totals()

        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        // dismiss "What's new" style sheets
        for t in ["Continue", "继续", "Not Now", "以后"] where photos.buttons[t].waitForExistence(timeout: 2) { photos.buttons[t].tap() }
        // select the newest items: open the first image in the grid
        let cell = photos.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Photos shows the library")
        let cells = photos.collectionViews.cells
        cells.element(boundBy: cells.count - 1).tap()
        let share = photos.buttons.matching(NSPredicate(format: "label IN {'Share', '共享', '分享'}")).firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        // the extension in the share sheet (the app row may need "More")
        let ours = photos.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'TwimShelf'")).firstMatch
        if !ours.waitForExistence(timeout: 5) {
            let more = photos.descendants(matching: .any).matching(NSPredicate(format: "label IN {'More', '更多'}")).firstMatch
            if more.exists { more.tap() }
        }
        if !ours.waitForExistence(timeout: 5) { print("TREE-SHARE", photos.debugDescription) }
        XCTAssertTrue(ours.exists, "导入 TwimShelf is offered in the share sheet")
        ours.tap()
        let done = photos.descendants(matching: .any).matching(NSPredicate(format: "label IN {'完成', '关闭'}")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the extension finished handing the file over")
        let summary = photos.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已交给 TwimShelf'")).firstMatch
        XCTAssertTrue(summary.exists, "handed over: \(photos.staticTexts.allElementsBoundByIndex.map(\.label))")
        let a = XCTAttachment(screenshot: photos.screenshot()); a.name = "share-extension-done"; a.lifetime = .keepAlways; add(a)
        done.tap()

        // back to the app: the share is imported as loose media
        app.activate()
        let toast = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '已从分享导入'")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "the app imported the share")
        let b = XCTAttachment(screenshot: app.screenshot()); b.name = "share-imported"; b.lifetime = .keepAlways; add(b)
        XCTAssertNotEqual(totals(), looseBefore, "the library grew")
    }
}
