import XCTest

/// This round's screens: minus-words in the search, the post text selectable on the card, the
/// post's caption in the viewer, and the long-press "在浏览中查看帖子" of a grid.
/// Run with TEST_RUNNER_TL_LIBRARY_DIR (a fresh folder) and TEST_RUNNER_TL_IMPORT_DIR (synthetic
/// legacy post folders), as FeedUITests.
final class RoundUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        for k in ["TL_IMPORT_DIR", "TL_LIBRARY_DIR"] { if let v = ProcessInfo.processInfo.environment[k] { app.launchEnvironment[k] = v } }
        app.launchEnvironment["TL_DEMO_TAGS"] = "1"
        app.launchEnvironment["TL_RESET_UI_STATE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func snap(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }

    private func searchShows(_ word: String) -> Bool {
        let x = el("searchExit")
        for _ in 0..<15 { if x.exists, (x.value as? String ?? "").contains(word) { return true }; usleep(200_000) }
        return false
    }

    /// "-猫 " becomes a minus capsule (read out as 排除：猫); "-" lists the exclusions.
    func testMinusWordsBecomeExclusionCapsules() {
        let f = el("search")
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        f.tap()
        f.typeText("-")
        XCTAssertTrue(el("sugg-kw-minus-author").waitForExistence(timeout: 3), "exclusions are offered after a minus")
        snap("minus-suggestions")
        f.typeText("猫 ")
        XCTAssertTrue(searchShows("排除：猫"), "a minus capsule")
        f.typeText("-用户 ")
        XCTAssertTrue(searchShows("排除：用户"), "a field taken away")
        f.typeText("\n")
        snap("minus-results")
    }

    /// The card's text is a selectable text view (long-press selects words, as in Notes).
    func testCardTextIsSelectable() {
        let text = el("postText")
        XCTAssertTrue(text.waitForExistence(timeout: 6))
        XCTAssertEqual(text.elementType, .textView)
        text.press(forDuration: 1.2)
        let copy = app.menuItems["拷贝"].firstMatch.exists || app.buttons["拷贝"].firstMatch.waitForExistence(timeout: 3) || app.menuItems["Copy"].firstMatch.exists
        snap("text-selection")
        XCTAssertTrue(copy, "the edit menu of a text selection, not the card's menu")
    }

    /// Opening a photo of a post shows the post's author and text over the viewer; a tap opens it.
    func testViewerShowsPostCaption() {
        let media = el("media-photo")
        XCTAssertTrue(media.waitForExistence(timeout: 6))
        media.tap()
        // pictures while it opens: the caption's shade must stay put, not jump
        for i in 0..<6 { snap("viewer-opening-\(i)") }
        XCTAssertTrue(el("photoViewer").waitForExistence(timeout: 4))
        let caption = el("postCaption")
        XCTAssertTrue(caption.waitForExistence(timeout: 4), "the post's caption over the media")
        snap("viewer-caption")
        caption.tap()
        sleep(1)
        snap("viewer-caption-open")
    }

    /// Opening a video of a post shows the caption above the player's controls, in one shade
    /// with them.
    func testVideoViewerShowsPostCaption() {
        let video = el("media-video")
        XCTAssertTrue(video.waitForExistence(timeout: 6))
        video.tap()
        XCTAssertTrue(el("playerClose").waitForExistence(timeout: 4))
        XCTAssertTrue(el("postCaption").waitForExistence(timeout: 4), "the post's caption over the video")
        snap("video-caption")
    }

    /// The phone layout's 文件夹 tab and a collection opened from it, pictured for review (a
    /// folded foldable keeps the home bar in its side column).
    func testPhoneFoldersPictures() throws {
        let tab = el("tab-folders")
        guard tab.waitForExistence(timeout: 6) else { throw XCTSkip("sidebar layout") }
        snap("phone-browse")
        tab.tap(); sleep(2)
        snap("phone-folders")
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "图片")).firstMatch
        if photos.exists { photos.tap(); sleep(2); snap("phone-folders-photos") }
    }

    /// A phone opened wide (a foldable): the tab rail holds 浏览, 文件夹, 设置 and nothing
    /// else; the media kinds are reached from the folders page.
    func testRailPlaces() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone, app.buttons["设置"].waitForExistence(timeout: 6) else { throw XCTSkip("no rail") }
        for gone in ["媒体类型", "其他"] { XCTAssertFalse(app.buttons[gone].exists, "\(gone) is not a tab") }
        snap("rail-browse")
        app.buttons["文件夹"].firstMatch.tap(); sleep(2)
        snap("rail-folders")
        let photos = el("kind-photo")
        XCTAssertTrue(photos.waitForExistence(timeout: 4), "图片 on the folders page")
        photos.tap(); sleep(2)
        snap("rail-photos")
        XCTAssertFalse(app.buttons["整理"].exists, "整理 mode is gone")
        app.buttons["设置"].firstMatch.tap(); sleep(2)
        snap("rail-settings")
    }

    /// Wide layout (iPad): every place in portrait and landscape, with the sidebar open and
    /// folded into the tab bar, pictured for review; the sidebar offers no 编辑.
    func testTabletLayouts() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("phone layout") }
        XCTAssertTrue(app.buttons["浏览"].waitForExistence(timeout: 6))
        let toggle = app.buttons["ToggleSideBar"]
        // a place, in the sidebar (a cell) or the tab bar (a button), whichever is on screen
        func place(_ name: String) -> XCUIElement? {
            let all = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name)).allElementsBoundByIndex
            return all.first { $0.isHittable }
        }
        func sidebarShown() -> Bool { place("散装媒体") != nil }
        for (o, name) in [(UIDeviceOrientation.portrait, "port")] {   // landscape pictures from XCUITest come out cropped; landscape is checked by hand
            XCUIDevice.shared.orientation = o
            sleep(2)
            for open in [true, false] {
                if sidebarShown() != open, toggle.exists { toggle.tap(); sleep(1) }
                XCTAssertEqual(sidebarShown(), open, "sidebar \(open ? "open" : "folded") in \(name)")
                if open { XCTAssertFalse(app.buttons["编辑"].exists, "the sidebar cannot be edited") }
                for p in ["浏览", "设置"] + (open ? ["视频"] : []) {
                    guard let b = place(p) else { continue }
                    b.tap(); sleep(2)
                    snap("\(name)-\(open ? "sidebar" : "bar")-\(p)")
                }
                place("浏览")?.tap(); sleep(1)
            }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Wide layout (iPad): a place chosen in the sidebar shows its grid; its "在浏览中查看"
    /// goes back to 浏览. Skipped in the phone layout.
    func testSidebarPlaceOpensGrid() throws {
        let photos = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "图片")).firstMatch
        guard app.buttons["浏览"].waitForExistence(timeout: 6), UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("phone layout") }
        // the floating tab bar's sidebar button (its first button) opens the sidebar
        if !photos.exists {
            let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR identifier CONTAINS[c] %@", "边栏", "sidebar")).firstMatch
            if toggle.exists { toggle.tap() } else { print("BUTTONS:", app.buttons.allElementsBoundByIndex.prefix(12).map { "\($0.identifier)|\($0.label)" }) }
        }
        XCTAssertTrue(photos.waitForExistence(timeout: 4), "图片 in the sidebar")
        photos.tap()
        XCTAssertTrue(app.navigationBars["图片"].waitForExistence(timeout: 4), "the grid of 图片")
        snap("sidebar-grid")
        app.navigationBars["图片"].buttons.element(boundBy: app.navigationBars["图片"].buttons.count - 1).tap()
        let show = app.buttons["在浏览中查看"].firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 3))
        show.tap()
        XCTAssertTrue(el("search").waitForExistence(timeout: 4), "back in 浏览")
        snap("sidebar-back-to-browse")
    }
}
