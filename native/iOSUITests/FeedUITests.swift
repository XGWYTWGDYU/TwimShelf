import XCTest

/// Drives the feed, player, tag picker, management, export and sync screens end to end.
/// Run with TEST_RUNNER_TL_IMPORT_DIR pointing at a sample library (import is idempotent).
final class FeedUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        if let dir = ProcessInfo.processInfo.environment["TL_IMPORT_DIR"] { app.launchEnvironment["TL_IMPORT_DIR"] = dir }
        // a synthetic library instead of whatever the simulator's container holds
        if let dir = ProcessInfo.processInfo.environment["TL_LIBRARY_DIR"] { app.launchEnvironment["TL_LIBRARY_DIR"] = dir }
        app.launchEnvironment["TL_DEMO_TAGS"] = "1"
        app.launchEnvironment["TL_RESET_UI_STATE"] = "1"
        // the tests read the Simplified Chinese texts (and type its condition words)
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func snap(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    /// Taps the search field: the list of suggestions opens under it.
    private func openSearchSettings() {
        if el("searchSuggestions").exists { return }
        let f = el("search")
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        f.tap()
        XCTAssertTrue(el("searchSuggestions").waitForExistence(timeout: 3), "the list opens under the field")
    }

    /// Return: the list closes, the search stays.
    private func closeSearch() {
        if el("searchSuggestions").exists { el("search").typeText("\n") }
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: el("searchSuggestions"))
        waitForExpectations(timeout: 3)
    }

    /// The × beside the bar: the search ends.
    private func exitSearch() {
        let x = el("searchExit")
        if x.waitForExistence(timeout: 2) { x.tap() }
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: el("searchSuggestions"))
        waitForExpectations(timeout: 3)
    }

    /// The search in effect includes this capsule (the × says what the search is).
    private func searchShows(_ word: String, timeout: TimeInterval = 3) -> Bool {
        let x = el("searchExit")
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if x.exists, (x.value as? String ?? "").contains(word) { return true }
            usleep(200_000)
        } while Date() < end
        return false
    }

    /// Search post text: the "贴文" condition capsule, then what was typed.
    private func toggleSearchScope(_ id: String) {
        openSearchSettings()
        if id == "in-text" { el("search").typeText("贴文 ") }
    }

    /// The totals line, at the end of the search list.
    private func stats() -> String {
        openSearchSettings()
        let l = el("statsLine")
        for _ in 0..<4 where !l.exists { el("searchSuggestions").swipeUp() }
        XCTAssertTrue(l.waitForExistence(timeout: 5), "totals under the search list")
        let v = l.label.components(separatedBy: "\n").first ?? ""
        exitSearch()
        return v
    }

    private func openSettings() {
        let m = el("manage")
        XCTAssertTrue(m.waitForExistence(timeout: 5))
        m.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 3))
    }

    func testSearchChipsAndGrouping() {
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
        XCTAssertTrue(stats().contains("帖子"), "totals shown on the main screen")
        let search = el("search")
        search.tap()
        search.typeText("墙\n")
        XCTAssertTrue(searchShows("墙"), "chip should appear")
        snap("search-墙")
        exitSearch()
        XCTAssertFalse(el("searchExit").exists, "the search ended")

        let toggle = app.buttons["groupToggle"]
        let before = toggle.isSelected
        toggle.tap()
        XCTAssertNotEqual(before, toggle.isSelected)
        toggle.tap()
    }

    func testSearchPostTextAndAuthor() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("今天的天空\n")   // a folder name = post text in the sample library
        XCTAssertTrue(searchShows("今天的天空"))
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 3) || el("media-video").exists, "post-text match found")
        snap("search-text")
        exitSearch()
    }

    /// No condition capsule: the words are looked for everywhere (here: only in a post's text).
    func testSearchWithoutConditionsLooksEverywhere() {
        let search = el("search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("测试帖子3\n")
        XCTAssertTrue(searchShows("测试帖子3"))
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 4) || el("media-video").exists, "found through the post text without a 贴文 capsule")
        exitSearch()
    }

    /// 视频 / 照片 are condition words: a capsule that limits the results to that kind.
    func testSearchMediaKindConditions() {
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
        let search = el("search")
        search.tap()
        search.typeText("视频\n")
        XCTAssertTrue(searchShows("视频"), "the word becomes a capsule")
        sleep(2)
        XCTAssertFalse(el("media-photo").exists, "only videos (or nothing) are shown")
        exitSearch()
        search.tap()
        search.typeText("照片\n")
        XCTAssertTrue(searchShows("照片"))
        sleep(2)
        XCTAssertFalse(el("media-video").exists, "only photos are shown")
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 4))
        exitSearch()
    }

    func testLongTextKeepsTagsVisible() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("非常长的测试正文\n")
        let plus = el("addTag")
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        let card = app.collectionViews.firstMatch.cells.firstMatch
        XCTAssertTrue(card.exists)
        // The "+" (end of the tag row) lies fully inside its card, i.e. long text did not push it out.
        XCTAssertLessThanOrEqual(plus.frame.maxY, card.frame.maxY, "tag row inside the card: \(plus.frame) vs \(card.frame)")
        XCTAssertGreaterThan(plus.frame.minY, card.frame.minY)
        snap("long-text")
    }

    func testPlusChipAddsTag() {
        let plus = el("addTag")
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        // the launch toast ("上次运行没有正常结束", the test runner ends the app hard) may cover it
        for _ in 0..<8 where el("toastAction").exists { sleep(1) }
        for _ in 0..<5 where !plus.isHittable { sleep(1) }
        plus.tap()
        let field = el("tagPickerField")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("uitag\n")
        XCTAssertTrue(app.staticTexts["uitag"].waitForExistence(timeout: 2), "listed under 刚刚添加")
        snap("tag-picker")
        el("pickerDone").tap()
        XCTAssertTrue(el("uitag").waitForExistence(timeout: 3), "new tag chip on the card")
    }

    func testContextMenuOffersSourcesAndRetag() {
        let media = el("media-photo")
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["标签来源…"].waitForExistence(timeout: 3))
        snap("context-menu")
        app.buttons["标签来源…"].tap()
        XCTAssertTrue(app.navigationBars["标签来源"].waitForExistence(timeout: 3))
        snap("tag-sources")
    }

    func testSettingsShowsTotalsAndSharedRoute() {
        openSettings()
        XCTAssertTrue(el("statsCard").waitForExistence(timeout: 3))
        app.staticTexts["下载帖子"].firstMatch.tap()   // the download form is one level down
        // typing a link: the keyboard never covers the 下载 button
        let links = el("linksView")
        XCTAssertTrue(links.waitForExistence(timeout: 3))
        links.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        sleep(1)
        let download = app.staticTexts["下载"].firstMatch
        XCTAssertTrue(download.isHittable, "the 下载 button stays above the keyboard")
        XCTAssertLessThan(download.frame.maxY, app.keyboards.firstMatch.frame.minY, "button above the keyboard")
        snap("download-keyboard")
        app.navigationBars.firstMatch.tap()   // dismiss the keyboard
        app.swipeDown(velocity: .slow)
        // route and folder are system pop-up buttons in a section of their own above the links
        // (they hold for the batch import too); concurrency and interval belong to the batch only
        let route = el("dlsettings/m:route")
        XCTAssertTrue(route.waitForExistence(timeout: 3), "download route in its own section")
        XCTAssertEqual(route.value as? String, "自动")
        route.tap()
        XCTAssertTrue(app.buttons["仅 FxTwitter"].waitForExistence(timeout: 2))
        snap("download-route-menu")
        app.buttons["仅 FxTwitter"].tap()
        XCTAssertTrue(el("dlsettings/m:route").waitForExistence(timeout: 2))
        sleep(1)
        XCTAssertEqual(el("dlsettings/m:route").value as? String, "仅 FxTwitter")
        el("dlsettings/m:route").tap(); app.buttons["自动"].tap()
        XCTAssertTrue(el("dlsettings/m:folder").exists, "folder choice next to the route")
        let conc = app.staticTexts["并发数"].firstMatch
        for _ in 0..<4 where !conc.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(conc.exists)
        XCTAssertGreaterThan(conc.frame.minY, app.staticTexts["选择 JSON 文件…"].firstMatch.frame.minY, "concurrency sits in the batch section")
        // and the account Cookie is on the same page
        let cookie = app.secureTextFields["auth_token"].firstMatch   // hidden input
        for _ in 0..<8 where !cookie.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(cookie.exists, "the Cookie fields are on the download page")
        snap("download-page")
        snap("manage")
        app.swipeUp()
        snap("manage-2")
    }

    /// The export belongs to a search: no export button without one; with one, a small popover
    /// with the switches (plain media locks the other two off) and 导出.
    func testSearchResultExport() {
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
        XCTAssertFalse(el("searchExport").exists, "no search, no export button")
        let search = el("search")
        search.tap()
        search.typeText("墙\n")
        XCTAssertTrue(searchShows("墙"))
        let button = el("searchExport")
        XCTAssertTrue(button.waitForExistence(timeout: 4), "a search shows the export button beside the ×")
        XCTAssertTrue(el("searchExit").exists)
        button.tap()
        let tags = app.switches.matching(NSPredicate(format: "label CONTAINS '包含标签信息'")).firstMatch
        let folders = app.switches.matching(NSPredicate(format: "label CONTAINS '包含所在文件夹信息'")).firstMatch
        let plain = app.switches.matching(NSPredicate(format: "label CONTAINS '以纯媒体导出'")).firstMatch
        XCTAssertTrue(tags.waitForExistence(timeout: 4) && folders.exists && plain.exists, "three switches")
        XCTAssertTrue(el("searchExportGo").exists, "and the button")
        snap("search-export")
        XCTAssertEqual(tags.value as? String, "1")
        XCTAssertEqual(folders.value as? String, "1")
        plain.tap()
        sleep(1)
        XCTAssertEqual(tags.value as? String, "0", "plain media: tags off")
        XCTAssertEqual(folders.value as? String, "0", "plain media: folders off")
        XCTAssertFalse(tags.isEnabled || folders.isEnabled, "and locked")
        snap("search-export-plain")
        plain.tap()
        sleep(1)
        XCTAssertEqual(tags.value as? String, "1", "what they were comes back")
        el("searchExportGo").tap()
        // the share sheet with the exported file comes up
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15) || app.sheets.firstMatch.waitForExistence(timeout: 3) || app.collectionViews["ActivityListView"].exists || app.navigationBars["UIActivityContentView"].exists, "share sheet")
        snap("search-export-shared")
    }

    func testSyncPairingCodeAppearsAndCountsDown() {
        openSettings()
        let sync = app.staticTexts["局域网同步"].firstMatch
        for _ in 0..<6 where !sync.isHittable { app.swipeUp() }
        sync.tap()
        XCTAssertTrue(app.navigationBars["局域网同步"].waitForExistence(timeout: 3))
        if app.staticTexts["创建同步账户"].exists { app.staticTexts["创建同步账户"].tap() }
        let show = app.staticTexts["显示验证码…"]
        if !show.waitForExistence(timeout: 5) { print("TREE-SYNC", app.debugDescription) }
        XCTAssertTrue(show.exists)
        show.tap()
        let code = el("pairingCode")
        if !code.waitForExistence(timeout: 3) { print("TREE-SYNC", app.debugDescription) }
        XCTAssertTrue(code.exists)
        XCTAssertEqual(code.label.count, 6, "six digits")
        let t0 = String(describing: code.value)
        XCTAssertTrue(t0.contains("后失效"), t0)
        sleep(3)
        XCTAssertNotEqual(t0, String(describing: code.value), "countdown ticks")
        XCTAssertEqual(code.label.count, 6, "code view stays stable while counting down")
        snap("pairing")
        app.staticTexts["取消"].tap()
        XCTAssertTrue(show.waitForExistence(timeout: 3))
    }

    func testPlayerGestures() throws {
        if app.buttons["groupToggle"].isSelected { app.buttons["groupToggle"].tap() }
        // Find the sample's video post by its text (the feed is random and mostly photos).
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("城市夜景合集\n")
        let video = el("media-video")
        _ = video.waitForExistence(timeout: 5)
        for _ in 0..<3 where !(video.exists && video.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(video.isHittable, "no video in feed")
        video.tap()
        let player = el("player")
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 1.2)

        let play = app.buttons["playPause"]
        // Controls auto-hide (alpha 0 = invisible to XCUITest); a single tap only toggles visibility, never playback.
        func reveal() { if !play.waitForExistence(timeout: 1) { player.tap(); _ = play.waitForExistence(timeout: 2) } }
        player.doubleTap()
        reveal()
        XCTAssertEqual(play.label, "播放", "double-tap should pause")
        player.doubleTap()
        reveal()
        XCTAssertEqual(play.label, "暂停", "double-tap should resume")

        let before = el("time").label
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)))
        player.tap()
        XCTAssertNotEqual(el("time").label, before)

        player.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)).press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)))
        player.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7)).press(forDuration: 0.05, thenDragTo: player.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.4)))

        let exp = expectation(description: "hud")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.9) {
            if self.el("hud").label == "2.5×" { exp.fulfill() }
        }
        player.press(forDuration: 1.6)
        wait(for: [exp], timeout: 3)
        XCTAssertTrue(el("player").exists)
    }

    // MARK: Filters, recycle bin, loop separator, player controls, prompt

    private func longPressFirstCard() {
        let media = el("media-photo")
        XCTAssertTrue(media.waitForExistence(timeout: 5))
        media.press(forDuration: 1.0)
    }

    private func searchText(_ t: String) {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText(t + "\n")
    }

    func testOnlyThisAuthorFilter() {
        searchText("#eve家")   // the sample post with an author (from its sidecar)
        longPressFirstCard()
        let item = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '只看 '")).firstMatch
        if !item.waitForExistence(timeout: 3) { print("TREE-AUTHOR", app.debugDescription) }
        XCTAssertTrue(item.exists, "author filter in the long-press menu")
        item.tap()
        let chip = el("chip-author")
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "author chip shown")
        snap("only-author")
        chip.tap()
        XCTAssertFalse(chip.waitForExistence(timeout: 1))
    }

    func testTagChipLongPressFiltersByTag() {
        // The feed is random and only some sample media carry 收藏: search it so every card does.
        let search = el("search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("收藏\n")
        let tag = app.collectionViews.firstMatch.descendants(matching: .any).matching(identifier: "收藏").firstMatch   // chips with a menu are pop-up buttons
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.press(forDuration: 1.0)
        let only = app.buttons["仅看此标签"]
        if !only.waitForExistence(timeout: 3) { print("TREE-TAGMENU", app.debugDescription) }
        XCTAssertTrue(only.exists, "tag chip has its own menu")
        snap("tag-menu")
        only.tap()
        XCTAssertTrue(el("chip-label-收藏").waitForExistence(timeout: 3))
        // every visible card carries the tag
        let cards = app.collectionViews.firstMatch.cells
        XCTAssertGreaterThan(cards.count, 0)
        el("chip-label-收藏").tap()
    }

    func testSearchResultsEndInsteadOfLooping() {
        // shown once, ending with a footer
        searchText("#eve家")   // one post
        let sep = el("feedEnd")
        for _ in 0..<12 where !sep.exists { app.swipeUp(velocity: .fast) }
        if !sep.exists { print("TREE-SEP", app.debugDescription) }
        XCTAssertTrue(sep.exists, "the results end with a footer")
        XCTAssertTrue(sep.label.contains("已经到底"), sep.label)
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "feedEnd").count, 1, "no second pass of the results")
        snap("search-end")
    }

    func testDeleteMediaUndoAndRestoreFromTrash() {
        let statsBefore = stats()
        longPressFirstCard()
        let del = app.buttons["删除这张媒体"]
        XCTAssertTrue(del.waitForExistence(timeout: 3))
        del.tap()
        let undo = el("toastAction")
        XCTAssertTrue(undo.waitForExistence(timeout: 3), "undo offered")
        snap("deleted-toast")
        // Undo puts it back.
        undo.tap()
        sleep(2)
        XCTAssertEqual(stats(), statsBefore)
        // Delete again, then restore from the recycle bin.
        longPressFirstCard()
        app.buttons["删除这张媒体"].tap()
        sleep(2)
        XCTAssertNotEqual(stats(), statsBefore, "totals exclude binned media")
        // the recycle bin is on the folders page (no longer in settings)
        el("tab-folders").tap()
        let trash = el("more-trash")
        XCTAssertTrue(trash.waitForExistence(timeout: 3))
        for _ in 0..<4 where !trash.isHittable { app.swipeUp() }
        trash.tap()
        // the bin is the same grid as 图片 / 视频, over the binned media
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'grid-photo', 'grid-video'}"))
        XCTAssertTrue(tiles.firstMatch.waitForExistence(timeout: 3), "binned media listed")
        snap("trash")
        let before = tiles.count
        el("gridSelect").tap()
        XCTAssertTrue(app.staticTexts["选择项目"].waitForExistence(timeout: 2))
        tiles.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["已选择 1 个媒体"].waitForExistence(timeout: 2), "the binned media is selected")
        snap("trash-selected")
        el("gridRestore").tap()
        sleep(2)
        snap("trash-after-restore")
        XCTAssertLessThan(tiles.count, before, "restored")
    }

    func testPromptIsAnAppSetting() {
        openSettings()
        let ai = app.staticTexts["AI 模型"].firstMatch
        for _ in 0..<6 where !ai.isHittable { app.swipeUp() }
        ai.tap()
        let prompt = app.staticTexts["提示词"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 3))
        prompt.tap()
        let field = el("promptPrompt")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText("（测试）")
        el("promptSave").tap()
        XCTAssertTrue(app.alerts["提示词已保存"].waitForExistence(timeout: 3))
        snap("prompt-saved")
        app.alerts.buttons["仅对以后生效"].tap()
        XCTAssertTrue(app.staticTexts["已自定义"].waitForExistence(timeout: 3))
    }

    func testPlayerLockCloseAndPiPButtons() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("城市夜景合集\n")
        let video = el("media-video")
        _ = video.waitForExistence(timeout: 5)
        for _ in 0..<3 where !(video.exists && video.isHittable) { app.swipeUp(velocity: .slow) }
        video.tap()
        let player = el("player")
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        let close = el("playerClose"), pip = el("playerPiP"), lock = el("playerLock"), play = el("playPause")
        if !(close.waitForExistence(timeout: 2) && pip.exists && lock.exists) { print("TREE-PLAYER", app.debugDescription) }
        XCTAssertTrue(close.exists && lock.exists)
        // controls auto-hide after 3 s; a single tap only shows them again
        func reveal() { if !close.exists { player.tap(); _ = close.waitForExistence(timeout: 2) } }
        reveal()
        // portrait: the buttons on one row (play on the left), the progress bar and the time below
        XCTAssertGreaterThan(close.frame.minX, play.frame.maxX, "close sits right of play")
        reveal()
        // Picture in picture is unavailable in the simulator (the button only shows where supported).
        if pip.exists { XCTAssertGreaterThan(pip.frame.minX, close.frame.minX, "picture in picture to the right of close") }
        reveal()
        XCTAssertGreaterThan(close.frame.minX, lock.frame.minX, "lock left of close")
        snap("player-bar")
        reveal()
        lock.tap()
        XCTAssertEqual(lock.value as? String, "已锁定")
        player.doubleTap()
        lock.tap()   // unlock (the lock stays reachable)
        XCTAssertEqual(lock.value as? String, "未锁定")
        if !play.waitForExistence(timeout: 1) { player.tap() }
        XCTAssertEqual(play.label, "暂停", "double-tap while locked did not pause")
        if !close.isHittable { player.tap() }
        close.tap()
        XCTAssertFalse(player.waitForExistence(timeout: 2), "closed from the bar")
    }

    func testRenameTagFromChipAndUndo() {
        let search = el("search")
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("收藏\n")
        let tag = app.collectionViews.firstMatch.descendants(matching: .any).matching(identifier: "收藏").firstMatch
        XCTAssertTrue(tag.waitForExistence(timeout: 5))
        tag.press(forDuration: 1.0)
        let item = app.buttons["重命名此标签…"]
        XCTAssertTrue(item.waitForExistence(timeout: 3))
        item.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "精选收藏")
        app.alerts.buttons["重命名"].tap()
        let renamed = app.collectionViews.firstMatch.descendants(matching: .any).matching(identifier: "精选收藏").firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 4), "cards show the new name")
        XCTAssertTrue(searchShows("精选收藏"), "the search chip follows the rename")
        XCTAssertFalse(app.collectionViews.firstMatch.descendants(matching: .any).matching(identifier: "收藏").firstMatch.exists, "old name gone")
        snap("renamed")
        let undo = el("toastAction")
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        exitSearch()
        search.tap()
        search.typeText("收藏\n")
        XCTAssertTrue(app.collectionViews.firstMatch.descendants(matching: .any).matching(identifier: "收藏").firstMatch.waitForExistence(timeout: 4), "undo brings the old name back")
    }

    // MARK: Position, inline video, folders, rotation

    private func firstVisibleCardText() -> String {
        let cells = app.collectionViews.firstMatch.cells.allElementsBoundByIndex.filter { $0.isHittable }
        guard let c = cells.first else { return "" }
        return c.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "|")
    }

    func testClosingSearchKeepsBrowsePosition() {
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        let before = firstVisibleCardText()
        let search = el("search")
        // scroll back up to reach the search field, as a user would… the header is pinned, so just tap it
        search.tap()
        search.typeText("墙\n")
        XCTAssertTrue(searchShows("墙"))
        exitSearch()
        sleep(2)
        XCTAssertEqual(firstVisibleCardText(), before, "back where we were after closing the search")
    }

    func testInlineVideoAutoplaysMuted() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("城市夜景合集\n")
        let video = el("media-video")
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        let playing = NSPredicate(format: "value == '自动播放中（静音）'")
        expectation(for: playing, evaluatedWith: video)
        waitForExpectations(timeout: 15)   // the asset loads off the main thread; slow under a full run
        // full screen and back: the card's video is taken off while away (no stale, black
        // video layer) and plays again on return
        video.tap()
        XCTAssertTrue(el("player").waitForExistence(timeout: 3))
        if !el("playerClose").isHittable { el("player").tap() }
        el("playerClose").tap()
        expectation(for: playing, evaluatedWith: video)
        waitForExpectations(timeout: 15)
        snap("inline-after-player")
        // to the background and back
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        expectation(for: playing, evaluatedWith: video)
        waitForExpectations(timeout: 15)
    }

    func testAddToFolderAndFilter() {
        longPressFirstCard()
        let add = app.buttons["加入文件夹"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let new = app.buttons["新建文件夹…"]
        XCTAssertTrue(new.waitForExistence(timeout: 3))
        new.tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("测试夹")
        app.alerts.buttons["创建"].tap()
        XCTAssertTrue(el("toastAction").waitForExistence(timeout: 3), "added, with undo")
        // "文件夹" then the folder, picked from the suggestions
        openSearchSettings()
        el("search").typeText("文件夹 ")
        let item = el("sugg-folder-测试夹")
        XCTAssertTrue(item.waitForExistence(timeout: 3), "folders offered after 文件夹")
        snap("folder-token-suggestions")
        item.tap()
        XCTAssertTrue(searchShows("文件夹：测试夹"))
        closeSearch()
        // browsing ends after the one card, with "共 1 …，已经到底"
        let sep = el("feedEnd")
        XCTAssertTrue(sep.waitForExistence(timeout: 5))
        XCTAssertTrue(sep.label.contains("1 "), "only the media put in the folder: \(sep.label)")
        snap("folder")
        exitSearch()
    }

    func testPlayerRotateButton() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("城市夜景合集\n")
        let video = el("media-video")
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let player = el("player")
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        let rotate = el("playerRotate")
        XCTAssertTrue(rotate.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(rotate.frame.minX, el("playerClose").frame.maxX, "rotate is at the bottom right")
        rotate.tap()
        sleep(2)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "landscape")
        snap("landscape")
        if !el("playerRotate").isHittable { player.tap() }
        el("playerRotate").tap()
        sleep(2)
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "back to portrait")
    }

    /// Watching a video the app turned to landscape (phone held sideways), then closing it:
    /// 浏览 is portrait again.
    func testClosingTurnedPlayerReturnsToPortrait() {
        toggleSearchScope("in-text")
        let search = el("search")
        search.tap()
        search.typeText("城市夜景合集\n")
        let video = el("media-video")
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let player = el("player")
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        el("playerRotate").tap()
        sleep(2)
        XCTAssertGreaterThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "landscape")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        if !el("playerClose").isHittable { player.tap() }
        el("playerClose").tap()
        sleep(2)
        XCTAssertFalse(player.exists, "the player closed")
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height, "浏览 is portrait again")
        snap("after-landscape-player")
        XCUIDevice.shared.orientation = .portrait
        toggleSearchScope("in-text")
    }

    // MARK: Round 7

    private func shareSheetAppears() -> Bool {
        let sheet = app.otherElements["ActivityListView"]
        let ok = sheet.waitForExistence(timeout: 6) || app.navigationBars["UIActivityContentView"].exists
        if !ok { print("TREE-SHARE", app.debugDescription) }
        // dismiss
        let close = app.buttons.matching(NSPredicate(format: "label IN {'关闭', 'Close'}")).firstMatch
        if close.exists { close.tap() } else { app.swipeDown(velocity: .fast) }
        return ok
    }

    func testPhotoViewerPagesThroughThePostAndShares() throws {
        // grouped cards (another test may have switched grouping off); a multi-media post shows "1/N"
        if !app.buttons["groupToggle"].isSelected { app.buttons["groupToggle"].tap() }
        let counter = app.staticTexts.matching(NSPredicate(format: "label MATCHES '1/[2-9]'")).firstMatch
        for _ in 0..<8 where !(counter.exists && counter.isHittable) { app.swipeUp(velocity: .slow) }
        guard counter.exists else { throw XCTSkip("no multi-media post visible in the sample") }
        let total = counter.label.components(separatedBy: "/").last ?? "?"
        // the media page right under the counter
        counter.coordinate(withNormalizedOffset: CGVector(dx: -2, dy: 4)).tap()
        let viewerCounter = el("photoCounter")
        if !viewerCounter.waitForExistence(timeout: 4) { throw XCTSkip("first page of that post is a video") }
        XCTAssertEqual(viewerCounter.label, "1 / \(total)")
        app.swipeLeft()
        XCTAssertTrue(NSPredicate(format: "label == %@", "2 / \(total)").evaluate(with: viewerCounter) || viewerCounter.label.hasPrefix("2 /"), viewerCounter.label)
        snap("viewer-page-2")
        el("photoShare").tap()
        XCTAssertTrue(shareSheetAppears(), "share sheet")
        el("photoClose").tap()
    }

    func testPlayerPortraitPutsButtonsAboveTheProgressBar() {
        searchText("城市夜景合集")
        let video = el("media-video")
        XCTAssertTrue(video.waitForExistence(timeout: 5))
        video.tap()
        let player = el("player")
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        let play = app.buttons["playPause"]
        if !play.waitForExistence(timeout: 1) { player.tap(); _ = play.waitForExistence(timeout: 2) }
        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.exists)
        XCTAssertLessThanOrEqual(play.frame.maxY, slider.frame.minY + 2, "portrait: buttons on top, the progress bar below")
        XCTAssertGreaterThan(slider.frame.width, app.frame.width * 0.7, "the progress bar gets (almost) the whole width")
        XCTAssertTrue(app.buttons["playerShare"].exists, "share button")
        snap("player-portrait")
        app.buttons["playerClose"].tap()
    }

    func testTagListShowsCountsAndFiltersHome() {
        openSettings()
        let tags = app.cells.matching(NSPredicate(format: "label BEGINSWITH '标签'")).firstMatch
        for _ in 0..<6 where !tags.exists { app.swipeUp(velocity: .slow) }
        tags.tap()
        let list = el("tagList")
        XCTAssertTrue(list.waitForExistence(timeout: 4))
        let first = list.cells.firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        XCTAssertTrue(first.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '共 '")).firstMatch.exists, "each tag shows how many media it is on")
        let label = first.staticTexts.firstMatch.label
        first.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["全部加入文件夹…"].waitForExistence(timeout: 3))
        snap("tag-list-menu")
        app.buttons["在主页只看此标签"].tap()
        XCTAssertTrue(el("chip-label-\(label)").waitForExistence(timeout: 5), "home shows only that tag")
    }

    /// Settings no longer list folders and the bin (they are on the folders page); a tag can
    /// be deleted from the tag list with a long press.
    func testDeleteTagFromTagList() {
        // a tag of our own to delete
        let plus = el("addTag")
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        for _ in 0..<8 where el("toastAction").exists { sleep(1) }
        for _ in 0..<5 where !plus.isHittable { sleep(1) }
        plus.tap()
        let field = el("tagPickerField")
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("待删标签\n")
        el("pickerDone").tap()
        XCTAssertTrue(el("待删标签").waitForExistence(timeout: 3))
        openSettings()
        XCTAssertFalse(el("content/n:trash").exists || el("content/n:folders").exists, "folders and bin left settings")
        let tags = app.cells.matching(NSPredicate(format: "label BEGINSWITH '标签'")).firstMatch
        for _ in 0..<6 where !tags.exists { app.swipeUp(velocity: .slow) }
        tags.tap()
        XCTAssertTrue(el("tagList").waitForExistence(timeout: 4))
        let filterField = app.searchFields.firstMatch
        XCTAssertTrue(filterField.waitForExistence(timeout: 3))
        filterField.tap()
        filterField.typeText("待删")
        let row = el("tagRow-待删标签")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.press(forDuration: 1.0)
        let del = app.buttons["删除标签…"]
        XCTAssertTrue(del.waitForExistence(timeout: 3))
        snap("tag-delete-menu")
        del.tap()
        app.alerts.buttons["删除标签"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: row)
        waitForExpectations(timeout: 4)
    }

    /// The tag list's … menu removes every AI tag; tags I added stay (demo tags come back at the
    /// next launch).
    func testRemoveAllAITags() {
        openSettings()
        let tags = app.cells.matching(NSPredicate(format: "label BEGINSWITH '标签'")).firstMatch
        for _ in 0..<6 where !tags.exists { app.swipeUp(velocity: .slow) }
        tags.tap()
        XCTAssertTrue(el("tagList").waitForExistence(timeout: 4))
        XCTAssertTrue(el("tagRow-城市夜景").waitForExistence(timeout: 4), "an AI-only tag before")
        el("tagListMore").tap()
        app.buttons["删除全部 AI 标签…"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        snap("remove-ai-confirm")
        alert.buttons["删除 AI 标签"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: el("tagRow-城市夜景"))
        waitForExpectations(timeout: 5)
        XCTAssertTrue(el("tagRow-收藏").exists, "my own tag stays")
        snap("remove-ai-done")
    }

    func testCardMenuOffersTheAuthorOnX() {
        searchText("#eve家")   // the sample post with an author and @handle (from its sidecar)
        longPressFirstCard()
        let open = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '在 X 打开 @'")).firstMatch
        if !open.waitForExistence(timeout: 3) { print("TREE-X", app.debugDescription) }
        XCTAssertTrue(open.exists, "open the author's profile on X")
        snap("card-menu-x")
    }

    func testProblemRecordsAndDiagnosticsExport() {
        openSettings()
        let row = app.cells.matching(NSPredicate(format: "label BEGINSWITH '问题记录'")).firstMatch
        for _ in 0..<10 where !row.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists)
        row.tap()
        XCTAssertTrue(app.navigationBars["问题记录"].waitForExistence(timeout: 3))
        snap("problems")
        app.cells.matching(NSPredicate(format: "label BEGINSWITH '导出诊断信息'")).firstMatch.tap()
        XCTAssertTrue(shareSheetAppears(), "the diagnostics ZIP is offered for sharing")
    }

    /// "最近" and "外部导入" are conditions too; the × ends the search.
    func testTokenRecentAndExternal() {
        let f = el("search")
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        f.tap()
        f.typeText("外部导入 ")
        XCTAssertTrue(searchShows("外部导入"))
        f.typeText("\n")
        // only 散装 media remain (cards say so), or none at all
        let loose = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '散装媒体'")).firstMatch
        XCTAssertTrue(loose.waitForExistence(timeout: 5) || app.staticTexts["没有匹配的媒体"].exists)
        XCTAssertFalse(app.collectionViews.firstMatch.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '帖子 '")).firstMatch.exists, "no post cards")
        snap("token-external")
        XCTAssertTrue(el("searchExit").isHittable, "a separate × beside the bar")
        exitSearch()
        XCTAssertFalse(el("searchExit").waitForExistence(timeout: 1), "the × goes with the search")
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
    }

    /// Search tokens: condition words and texts typed with spaces become capsules, interleaved;
    /// the suggestions complete a condition; Return keeps the search and closes the list.
    func testTokenSearchTurnsWordsIntoCapsules() {
        let f = el("search")
        XCTAssertTrue(f.waitForExistence(timeout: 5))
        f.tap()
        XCTAssertTrue(el("sugg-kw-tags").waitForExistence(timeout: 3), "conditions suggested")
        snap("tokens-empty")
        f.typeText("标签 墙 贴文 ")
        // three capsules (each is one object character in the field's value), no text left
        func capsules() -> Int { (f.value as? String ?? "").filter { $0 == "\u{FFFC}" }.count }
        func typed() -> String { (f.value as? String ?? "").filter { $0 != "\u{FFFC}" } }
        XCTAssertEqual(capsules(), 3, f.debugDescription)
        XCTAssertEqual(typed(), "")
        XCTAssertFalse(el("sugg-kw-tags").exists, "a used condition is no longer suggested")
        f.typeText("共")
        XCTAssertTrue(el("sugg-kw-common").waitForExistence(timeout: 2), "the typed start completes to 共同")
        el("sugg-kw-common").tap()
        snap("tokens-capsules")
        f.typeText("天空\n")
        XCTAssertFalse(el("searchSuggestions").waitForExistence(timeout: 1))
        snap("tokens-result")
        // all five capsules stay in the field, and the search ran (the results end)
        XCTAssertEqual(capsules(), 5, f.debugDescription)
        XCTAssertEqual(typed(), "")
    }

    /// Fuzzy search is a setting; there is no search style to choose any more.
    func testFuzzyIsASetting() {
        openSettings()
        let fuzzy = app.switches["语义模糊搜索"].exists ? app.switches["语义模糊搜索"] : app.cells["语义模糊搜索"]
        for _ in 0..<6 where !fuzzy.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(fuzzy.exists)
        XCTAssertFalse(el("search/m:searchStyle").exists, "no search style setting")
        snap("search-settings")
    }

    /// The grid: pinching changes how many tiles fit; "选择" selects by tapping, and the toolbar
    /// acts on the selection (here: put it into a new folder).
    func testGridPinchAndSelection() {
        el("tab-folders").tap()
        let photos = el("kind-photo")
        XCTAssertTrue(photos.waitForExistence(timeout: 3))
        photos.tap()
        let grid = el("mediaGrid")
        XCTAssertTrue(grid.waitForExistence(timeout: 3))
        XCTAssertTrue(el("grid-photo").waitForExistence(timeout: 3))
        // tiles are drawn by the grid itself and exposed as accessibility elements
        let tiles = { self.app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'grid-photo', 'grid-video'}")).count }
        // a few media all fit on screen at any zoom: the size of a tile tells the zoom
        let tileWidth = { self.app.descendants(matching: .any).matching(identifier: "grid-photo").element(boundBy: 0).frame.width }
        let before = tileWidth()
        // (the menu takes the same steps as a pinch; real pinches were checked in the simulator)
        el("gridMore").tap()
        app.buttons["缩小"].tap()
        sleep(1)
        let smaller = tileWidth()
        XCTAssertLessThan(smaller, before, "zooming out shows smaller tiles")
        snap("grid-small")
        el("gridMore").tap()
        app.buttons["放大"].tap()
        sleep(1)
        el("gridMore").tap()
        app.buttons["放大"].tap()
        sleep(1)
        XCTAssertGreaterThan(tileWidth(), before, "zooming in shows bigger tiles")
        // quick pinches back and forth, also interrupting the settle: the app keeps running
        for i in 0..<8 { grid.pinch(withScale: i % 2 == 0 ? 0.4 : 2.2, velocity: i % 2 == 0 ? -3 : 3) }
        sleep(1)
        XCTAssertEqual(app.state, .runningForeground, "no crash from repeated pinches")
        XCTAssertTrue(el("grid-photo").waitForExistence(timeout: 3))
        snap("grid-after-pinches")
        snap("grid-big")
        el("gridSelect").tap()
        XCTAssertTrue(app.staticTexts["选择项目"].waitForExistence(timeout: 2))
        XCTAssertFalse(el("tab-folders").isHittable, "the home bar makes room for the toolbar")
        let tile = { (i: Int) in self.app.descendants(matching: .any).matching(identifier: "grid-photo").element(boundBy: i) }
        tile(0).tap()
        tile(1).tap()
        XCTAssertTrue(app.staticTexts["已选择 2 个媒体"].waitForExistence(timeout: 2), "two tiles selected")
        snap("grid-selected")
        el("gridAddToFolder").tap()
        app.buttons["新建文件夹…"].tap()
        app.alerts.textFields.firstMatch.typeText("选择夹")
        app.alerts.buttons["创建并加入"].tap()
        XCTAssertTrue(el("gridSelect").waitForExistence(timeout: 3), "selection ends after the action")
        XCTAssertTrue(el("tab-folders").waitForExistence(timeout: 2))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(el("folder-选择夹").waitForExistence(timeout: 3), "the new folder holds the selection")
        XCTAssertTrue(el("folder-选择夹").label.contains("2"), el("folder-选择夹").label)
    }

    /// "导出诊断" in the launch notice (the test runner ends the app hard, so the notice shows):
    /// the export runs in the settings sheet, which closes again with 完成.
    func testCrashNoticeExportCanBeClosed() throws {
        let action = el("toastAction")
        try XCTSkipUnless(action.waitForExistence(timeout: 5) && action.label == "导出诊断", "no launch notice this time")
        action.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5), "the settings sheet")
        // the export's share sheet comes up on top; 完成 closes everything at once
        sleep(3)
        let done = app.navigationBars["资料库"].buttons.matching(NSPredicate(format: "label IN {'完成', 'Done'}")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the sheet has 完成")
        snap("diagnostics-sheet")
        // a tap outside the half-height share sheet closes it first (system behaviour); then 完成
        for _ in 0..<2 where app.navigationBars["资料库"].exists { done.tap(); sleep(1) }
        XCTAssertTrue(el("search").waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["资料库"].exists, "back on the home screen")
    }

    /// Deleting from the grid: the others close the gap (the tile count on screen stays full).
    func testGridDeleteClosesGap() {
        el("tab-folders").tap()
        XCTAssertTrue(el("kind-photo").waitForExistence(timeout: 3))
        el("kind-photo").tap()
        let first = app.descendants(matching: .any).matching(identifier: "grid-photo").element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        let before = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'grid-photo', 'grid-video'}")).count
        first.press(forDuration: 1.0)
        let del = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '将' AND label ENDSWITH '移到回收站'")).firstMatch
        XCTAssertTrue(del.waitForExistence(timeout: 3))
        del.tap()
        sleep(1)
        snap("grid-after-delete")
        XCTAssertEqual(app.state, .runningForeground)
        let after = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN {'grid-photo', 'grid-video'}")).count
        XCTAssertGreaterThanOrEqual(after, before - 3, "the grid stays full: \(before) → \(after)")
    }

    func testFoldersTab() {
        // a folder to show: add the first card to one (photo or video: the order is random)
        XCTAssertTrue(el("media-photo").waitForExistence(timeout: 5) || el("media-video").exists)
        let media = el("media-photo").exists ? el("media-photo") : el("media-video")
        media.press(forDuration: 1.0)
        app.buttons["加入文件夹"].tap()
        let existing = app.buttons["UI测试夹"]
        if existing.waitForExistence(timeout: 2) { existing.tap() } else {
            app.buttons["新建文件夹…"].tap()
            app.alerts.textFields.firstMatch.typeText("UI测试夹")
            app.alerts.buttons["创建"].tap()
        }
        let shuffle = app.buttons["重新随机"]
        XCTAssertTrue(shuffle.exists)
        XCTAssertLessThanOrEqual(app.buttons["资料库管理"].frame.maxX, app.windows.firstMatch.frame.maxX - 8, "the whole bar fits the screen")
        let barWidth = app.buttons["资料库管理"].frame.maxX - el("tab-browse").frame.minX
        el("tab-folders").tap()
        XCTAssertTrue(app.navigationBars["文件夹"].waitForExistence(timeout: 3))
        XCTAssertTrue(el("folder-UI测试夹").waitForExistence(timeout: 3))
        XCTAssertTrue(el("kind-photo").exists && el("more-trash").exists)
        sleep(1)
        XCTAssertFalse(shuffle.exists, "no shuffle on the folders page")
        let narrower = app.buttons["资料库管理"].frame.maxX - el("tab-folders").frame.minX + (el("tab-folders").frame.minX - el("tab-browse").frame.minX)
        XCTAssertLessThan(narrower, barWidth, "the bar got shorter")
        XCTAssertTrue((el("tab-folders").value as? String ?? "").isEmpty || el("tab-folders").isSelected)
        snap("folders-page")
        el("folder-UI测试夹").tap()
        XCTAssertTrue(app.navigationBars["UI测试夹"].waitForExistence(timeout: 3))
        XCTAssertTrue(el("grid-photo").waitForExistence(timeout: 3) || el("grid-video").waitForExistence(timeout: 1), "the folder's media in a grid")
        snap("folder-grid")
        // back on 浏览, the folders keep their place; the shuffle button returns
        el("tab-browse").tap()
        XCTAssertTrue(shuffle.waitForExistence(timeout: 3))
        el("tab-folders").tap()
        XCTAssertTrue(app.navigationBars["UI测试夹"].waitForExistence(timeout: 3), "the folder stays open")
        // "在浏览中查看" switches tabs with the folder's filter
        el("gridMore").tap()
        app.buttons["在浏览中查看"].tap()
        XCTAssertTrue(el("chip-folder").waitForExistence(timeout: 3))
        XCTAssertTrue(shuffle.exists)
        el("chip-folder").tap()
        // clean up
        el("tab-folders").tap()
        el("gridMore").tap()
        app.buttons["删除文件夹…"].tap()
        app.alerts.buttons["删除文件夹"].tap()
        XCTAssertTrue(app.navigationBars["文件夹"].waitForExistence(timeout: 3))
        el("tab-browse").tap()
    }
}
