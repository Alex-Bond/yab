import XCTest
@testable import YabPhone

/// The field's own rules: drafts wait at their page, New Tab keeps one of
/// its own, the eyes keep nothing, choosing forgets; a link from another app
/// is a tab, one row of one page.
@MainActor
final class FieldModelTests: XCTestCase {
    private var app: AppModel!

    override func setUp() async throws {
        Motion.disabled = true
        FieldMotion.forced = false
        app = AppModel(world: try World.load(named: "mira"))
    }

    override func tearDown() async throws {
        FieldMotion.forced = false
    }

    // MARK: - the search sheet's way out and in

    private func sheetGeometry(_ pose: SearchSheetPose) -> FieldGeometry {
        FieldGeometry(size: CGSize(width: 375, height: 812), keyboard: 288, mode: .newTab, textScale: 1, resting: false, sheet: pose)
    }

    func testGoingUpTheSheetReachesTheScreensTop() {
        var pose = SearchSheetPose(expand: 0, rise: 1, body: 244)
        XCTAssertGreaterThan(sheetGeometry(pose).sheetRect(pose).minY, 100)
        pose.leave = 1
        XCTAssertEqual(sheetGeometry(pose).sheetRect(pose).minY, 0)
    }

    func testTheSheetGrowsOutOfTheControlTapped() {
        let plus = CGRect(x: 133, y: 736, width: 110, height: 52)
        var pose = SearchSheetPose(expand: 0, rise: 0, body: 244, origin: plus)
        let start = sheetGeometry(pose)
        let field = start.sheetField(pose, height: 48)
        XCTAssertEqual(field.minX, plus.minX)
        XCTAssertEqual(field.width, plus.width)
        XCTAssertEqual(field.minY + start.sheetDrop(pose), plus.minY, accuracy: 0.5)
        pose.rise = 1
        let end = sheetGeometry(pose)
        XCTAssertEqual(end.sheetDrop(pose), 0)
        XCTAssertEqual(end.sheetField(pose, height: 48).width, 343)
    }


    // MARK: - opening

    func testThePlatesFieldOpensOnTheAddressSelected() {
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.mode, .address)
        XCTAssertTrue(app.field.showsAddress)
        XCTAssertEqual(app.field.text, "figma.com/design/xK29fLm8/Onboarding-v3")
        XCTAssertEqual(app.field.words, "", "the address isn't words to read")
        XCTAssertTrue(app.fieldRows.isEmpty, "the page's card, no rows")
        XCTAssertEqual(app.fieldKey, .go)
    }

    func testTypingReplacesTheAddress() {
        app.surfaces.openField(.address)
        app.field.typed("hacker")
        XCTAssertFalse(app.field.showsAddress)
        XCTAssertEqual(app.fieldRows.first?.title, "Hacker News")
        XCTAssertEqual(app.fieldRows.first?.subtitle, "Hacker News · Work")
    }

    // MARK: - the eyes in the plate's field

    func testTheEyesInThePlatesFieldAreNewTabsAndCoverNothing() throws {
        let locked = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { true })
        locked.surfaces.openField(.address)
        locked.field.typed("")
        locked.field.setPrivate(true)
        XCTAssertTrue(locked.field.isPrivate)
        XCTAssertEqual(locked.field.place, .privateTab, "what it opens is a private tab of its own, as + opens")
        XCTAssertFalse(locked.privateLock.mayReveal, "Private is still locked")
        XCTAssertFalse(locked.privateContentBlocked,
                       "the card shows Private's lock inside itself; nothing covers the whole screen as over a private tab")
    }

    // MARK: - drafts

    func testWordsLeftWaitAtTheirPage() {
        app.surfaces.openField(.address)
        app.field.typed("what to pack")
        app.surfaces.closeField()
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.text, "what to pack", "the draft is back on the same tab")
        XCTAssertFalse(app.field.showsAddress)
        app.surfaces.closeField()
        // On another tab, its address.
        app.browser.select("work-hn")
        app.surfaces.openField(.address)
        XCTAssertTrue(app.field.showsAddress)
        XCTAssertEqual(app.field.text, "news.ycombinator.com")
        app.surfaces.closeField()
        app.browser.select("work-figma-onb")
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.text, "what to pack")
    }

    func testNewTabKeepsADraftOfItsOwn() {
        app.surfaces.openField(.address)
        app.field.typed("about the page")
        app.surfaces.closeField()
        app.surfaces.openField(.newTab)
        XCTAssertEqual(app.field.text, "", "New Tab doesn't take the page's draft")
        app.field.typed("lisbon hotels")
        app.surfaces.closeField()
        app.surfaces.openField(.newTab)
        XCTAssertEqual(app.field.text, "lisbon hotels")
        app.surfaces.closeField()
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.text, "about the page")
    }

    func testChoosingForgetsTheDraft() throws {
        app.surfaces.openField(.address)
        app.field.typed("hacker")
        let row = try XCTUnwrap(app.fieldRows.first)
        app.choose(row)
        XCTAssertEqual(app.browser.tab?.id, "work-hn")
        XCTAssertNil(app.field.draft(for: "work-figma-onb"))
        XCTAssertNil(app.surfaces.field)
    }

    func testClearKeepsTheFieldOpen() {
        app.surfaces.openField(.address)
        app.field.clear()
        XCTAssertEqual(app.field.text, "")
        XCTAssertFalse(app.field.showsAddress)
        XCTAssertEqual(app.surfaces.field, .address)
    }

    // MARK: - choosing

    func testASearchFromThePlateLoadsInThisTabAndBackReturns() throws {
        // Over a tab of today's: the same tab, its own web view.
        app.browser.select("work-hn")
        let hn = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(hn.place, .today)
        let before = app.browser.space.today.count
        app.surfaces.openField(.address)
        app.field.typed("lisbon weather october")
        app.fieldReturn()
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(tab.id, hn.id, "the same tab, its own web view: Back has the page before")
        XCTAssertEqual(tab.title, "lisbon weather october · Google Search")
        XCTAssertEqual(tab.page, "google", "the prototype's own results page")
        XCTAssertEqual(app.browser.space.today.count, before, "no new tab")
        // Back: the web view is at the page before again, and the tab says so.
        app.pageCommitted(hn.id, hn.pageURL)
        XCTAssertEqual(app.browser.tab?.title, hn.title)
        XCTAssertEqual(app.browser.tab?.address, hn.address)
        // Forward: the results again.
        app.pageCommitted(hn.id, tab.pageURL)
        XCTAssertEqual(app.browser.tab?.title, "lisbon weather october · Google Search")
    }

    /// Over a folder's tab the search opens at today's top and the folder's
    /// tab stays the page it keeps (a live folder's was rewritten on every device).
    func testASearchFromThePlateOverAFoldersTabOpensInToday() throws {
        let figma = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(figma.place, .kept)
        let before = app.browser.space.today.count
        app.surfaces.openField(.address)
        app.field.typed("lisbon weather october")
        app.fieldReturn()
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertNotEqual(tab.id, figma.id)
        XCTAssertEqual(tab.place, .today)
        XCTAssertEqual(app.browser.space.today.first?.id, tab.id)
        XCTAssertEqual(app.browser.space.today.count, before + 1)
        XCTAssertEqual(app.browser.tab(figma.id)?.title, figma.title)
        XCTAssertEqual(app.browser.space.folder(holding: figma.id)?.name, "Onboarding v3")
    }

    func testAPinStaysTheSiteItPins() throws {
        let pin = try XCTUnwrap(app.browser.space.pins.first)
        app.browser.select(pin.id)
        app.surfaces.openField(.address)
        app.field.typed("lisbon weather october")
        app.fieldReturn()
        XCTAssertEqual(app.browser.tab(pin.id)?.title, pin.title, "the pin keeps its page")
        XCTAssertEqual(app.browser.space.today.first?.title, "lisbon weather october · Google Search", "the page opens as a new tab")
        XCTAssertEqual(app.browser.tab?.id, app.browser.space.today.first?.id)
    }

    func testEditingTheAddressInPlace() {
        app.surfaces.openField(.address)
        app.field.editAddress()
        XCTAssertFalse(app.field.showsAddress, "words to edit now")
        XCTAssertEqual(app.field.text, "figma.com/design/xK29fLm8/Onboarding-v3")
        XCTAssertNil(app.field.draft(for: "work-figma-onb"), "the address itself is no draft")
        XCTAssertEqual(app.fieldRows.first?.action, .open)
        app.field.typed("figma.com/design/xK29fLm8/Onboarding-v4")
        XCTAssertEqual(app.field.draft(for: "work-figma-onb"), "figma.com/design/xK29fLm8/Onboarding-v4")
    }

    func testWordsOfNoTaskAreOnlySaidSent() {
        let before = app.tasks.runs.map(\.id)
        app.startTask(for: "water the plants on friday")
        XCTAssertEqual(app.tasks.runs.map(\.id), before, "not another world's task")
        XCTAssertEqual(app.surfaces.toast?.text, "Sent to your Mac")
    }

    func testASearchFromNewTabOpensANewTabFirstInToday() throws {
        app.surfaces.openField(.newTab)
        app.field.typed("espresso grinders")
        app.fieldReturn()
        XCTAssertEqual(app.browser.space.today.first?.title, "espresso grinders · Google Search")
        XCTAssertEqual(app.browser.tab?.id, app.browser.space.today.first?.id)
        XCTAssertNotNil(app.browser.tab("work-figma-onb"))
    }

    func testATaskGoesToTheMac() {
        app.surfaces.openField(.address)
        app.field.typed("book the tap 18:35 to lisbon, window seat")
        XCTAssertEqual(app.fieldKey, .send)
        app.fieldReturn()
        XCTAssertNotNil(app.tasks.run("lisbon"))
        XCTAssertNotNil(app.nowItem, "the Now line takes it")
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.taskSent)
    }

    func testAQuestionGrowsAnAnswer() {
        app.surfaces.openField(.address)
        app.field.typed("what does anna want?")
        app.fieldReturn()
        XCTAssertEqual(app.surfaces.chat, .answer(question: "what does anna want?", aboutPage: true))
        XCTAssertNil(app.surfaces.field)
    }

    func testTheWordSettingsOpensSettings() {
        app.surfaces.openField(.newTab)
        app.field.typed("sett")
        XCTAssertEqual(app.fieldRows.first?.action, .settings)
        app.fieldReturn()
        XCTAssertTrue(app.surfaces.settings)
    }

    func testAFrequentSiteGoesToItsOpenTab() {
        app.surfaces.openField(.newTab)
        let figma = NewTabContent.miraSites.first { $0.key == "figma" }!
        app.chooseFrequent(figma)
        XCTAssertEqual(app.browser.tab?.icon, "figma")
        XCTAssertTrue(app.browser.space.allTabs.contains { $0.id == app.browser.tab?.id }, "an open Figma tab of Work")
    }

    func testNewTabsNowIsThePrototypes() {
        let content = NewTabContent.make(for: app)
        XCTAssertEqual(content.now.map(\.title), ["Paste and Go", "Lisbon: the stay is booked, the flights aren’t", "Launch notes · Tern 2.0"])
        XCTAssertEqual(content.recent.map(\.subtitle), ["Work · 15 min ago", "Work · 4 h ago"])
        XCTAssertEqual(content.frequent.prefix(5).map(\.name), ["Daybook", "Linear", "Slack", "Figma", "Lumen"])
    }

    // MARK: - Incognito

    func testTheEyesShutAndOpenSoftly() {
        app.surfaces.openField(.newTab)
        let before = Haptics.played.count
        app.field.setPrivate(true)
        XCTAssertTrue(app.field.isPrivate)
        XCTAssertEqual(app.field.place, .privateTab)
        XCTAssertEqual(Haptics.played.count, before + 1)
        XCTAssertEqual(Haptics.played.last?.kind, .soft)
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.eyes)
        app.field.setPrivate(false)
        XCTAssertEqual(Haptics.played.last?.kind, .soft)
    }

    func testIncognitoOpensAPrivateTabAndKeepsNoDraft() throws {
        app.surfaces.openField(.newTab)
        let soft = { Haptics.played.filter { $0.kind == .soft && $0.reason == Haptics.Reason.eyes }.count }
        let before = soft()
        app.field.setPrivate(true)
        app.field.typed("gift ideas for jonas")
        XCTAssertEqual(app.fieldRows.map(\.action), [.search])
        XCTAssertEqual(app.field.newTabWords, "", "nothing typed with the eyes shut is kept")
        app.fieldReturn()
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertTrue(tab.isPrivate)
        XCTAssertEqual(tab.page, "google-gift")
        XCTAssertEqual(app.browser.space.today.first?.id, tab.id, "first among today's")
        XCTAssertFalse(app.field.isPrivate, "the eyes open again once the field is gone")
        XCTAssertEqual(soft(), before + 2, "shut softly, and open again softly")
        // Never found by words, never offered by New Tab.
        XCTAssertFalse(app.tabCandidates.contains { $0.id == tab.id })
        // Closed, it is gone everywhere.
        app.closePrivate(tab.id)
        XCTAssertNil(app.browser.tab(tab.id))
        XCTAssertFalse(app.pages.isLive(tab.id))
    }

    func testPrivateOpeningSelectsOneSeparateSpaceAndPreservesOrdinaryTabs() throws {
        let ordinaryID = app.browser.spaceID
        let ordinaryTabs = app.browser.space.allTabs
        app.surfaces.openField(.newTab)
        app.field.setPrivate(true)
        app.field.typed("lumen.events")
        app.fieldReturn()
        let privateID = app.browser.spaceID
        XCTAssertNotEqual(privateID, ordinaryID)
        XCTAssertTrue(app.browser.space.isPrivate)
        XCTAssertEqual(app.browser.space.name, "Private")
        XCTAssertEqual(app.browser.spaceIndex, 0)
        XCTAssertEqual(app.browser.space(ordinaryID)?.allTabs, ordinaryTabs)
        let first = try XCTUnwrap(app.browser.tab)
        app.browser.showSpace(ordinaryID)
        app.openPrivately(PageFixtures.search("another secret"))
        XCTAssertEqual(app.browser.spaceID, privateID)
        XCTAssertEqual(app.browser.spaces.filter(\.isPrivate).count, 1)
        XCTAssertTrue(app.browser.space.allTabs.contains { $0.id == first.id })
        app.browser.move(first.id, to: ordinaryID)
        XCTAssertEqual(app.browser.space(holding: first.id)?.id, privateID)
    }

    func testNewTabWithinPrivateHasNoHistoryAndOpeningEyesReturnsToOrdinary() throws {
        let ordinaryID = app.browser.spaceID
        app.openPrivately(PageFixtures.search("private words"))
        let privateID = app.browser.spaceID
        app.surfaces.openField(.newTab)
        XCTAssertTrue(app.field.isPrivate)
        XCTAssertEqual(app.field.place, .privateTab)
        XCTAssertTrue(app.field.text.isEmpty)
        app.field.typed("second private page")
        app.fieldReturn()
        XCTAssertEqual(app.browser.spaceID, privateID)
        XCTAssertTrue(app.browser.tab?.isPrivate == true)
        app.surfaces.openField(.newTab)
        app.field.setPrivate(false)
        app.field.typed("lumen.events")
        app.fieldReturn()
        XCTAssertEqual(app.browser.spaceID, ordinaryID)
        XCTAssertFalse(try XCTUnwrap(app.browser.tab).isPrivate)
    }

    func testPrivateTabsNeverAppearInWordsAfterMovingToKept() throws {
        app.openPrivately(PageFixtures.search("private notes"))
        let id = try XCTUnwrap(app.browser.tab?.id)
        app.browser.keep(id)
        XCTAssertFalse(app.tabCandidates.contains { $0.id == id })
    }

    func testAPrivateTabsOwnFieldKeepsItPrivate() throws {
        app.openPrivately(PageFixtures.search("gift ideas for jonas"))
        let id = try XCTUnwrap(app.browser.tab?.id)
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.place, .privatePage)
        // Nothing of the agent's or the Mac's.
        XCTAssertEqual(app.pageActions, [.copy, .share])
        // No tabs, no Claude: only where the words go, in this tab.
        app.field.typed("hacker")
        XCTAssertEqual(app.fieldRows.map(\.action), [.search])
        XCTAssertEqual(app.fieldRows.first?.subtitle, "Search Google · in this tab")
        app.field.typed("what does anna want?")
        XCTAssertEqual(app.fieldRows.map(\.action), [.search])
        app.field.typed("lumen.events")
        XCTAssertEqual(app.fieldRows.map(\.action), [.open, .search])
        XCTAssertNil(app.field.draft(for: id), "words over a private tab are never kept")
        app.surfaces.closeField()
        app.surfaces.openField(.address)
        XCTAssertTrue(app.field.showsAddress, "no draft waits at a private tab")
        app.field.typed("hacker")
        app.fieldReturn()
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(tab.id, id, "in the same private tab")
        XCTAssertTrue(tab.isPrivate, "still private: never history, never synced")
        XCTAssertEqual(tab.title, "hacker · Google Search")
        XCTAssertEqual(app.browser.space.today.filter(\.isPrivate).count, 1)
        XCTAssertFalse(app.tabCandidates.contains { $0.id == id })
        // The menu's Ask and Open on Mac do nothing here.
        app.pageAction(.ask)
        XCTAssertNil(app.surfaces.chat)
    }

    /// #1603: the plate's field over an ordinary tab of Today, eyes shut,
    /// loaded the private search into that ordinary tab, which history
    /// then recorded. It opens a private tab of its own, as + does.
    func testTheEyesShutOverAnOrdinaryTabOpenAPrivateTabOfTheirOwn() throws {
        let today = try XCTUnwrap(app.browser.space.today.first { !$0.isPrivate })
        app.browser.select(today.id)
        app.surfaces.openField(.address)
        app.field.typed("")
        app.field.setPrivate(true)
        app.field.typed("gift ideas for jonas")
        XCTAssertEqual(app.fieldRows.map(\.action), [.search])
        app.fieldReturn()
        let opened = try XCTUnwrap(app.browser.tab)
        XCTAssertNotEqual(opened.id, today.id, "not loaded into the ordinary tab")
        XCTAssertTrue(opened.isPrivate, "never history, never synced")
        XCTAssertEqual(opened.page, "google-gift")
        let left = try XCTUnwrap(app.browser.tab(today.id))
        XCTAssertFalse(left.isPrivate)
        XCTAssertEqual(left.page, today.page, "the ordinary tab keeps its own page")
        XCTAssertEqual(left.title, today.title)
    }

    func testAPrivateTabClosedAnywhereLeavesNothing() async throws {
        app.openPrivately(PageFixtures.search("gift ideas for jonas"))
        let tab = try XCTUnwrap(app.browser.tab)
        _ = app.pages.view(for: tab)
        let store = app.pages.privateStore
        XCTAssertTrue(app.pages.isLive(tab.id))
        // Closed the way the column closes a row.
        app.browser.close(tab.id)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(app.pages.isLive(tab.id), "its page goes")
        XCTAssertNil(app.pages.snapshots[tab.id])
        XCTAssertFalse(app.pages.privateStore === store, "the next private tab starts on a store of its own")
        // A second private tab, while another is open, keeps the store they share.
        app.openPrivately(PageFixtures.search("one"))
        let one = try XCTUnwrap(app.browser.tab?.id)
        app.openPrivately(PageFixtures.search("two"))
        let shared = app.pages.privateStore
        app.closePrivate(one)
        XCTAssertTrue(app.pages.privateStore === shared)
    }

    func testAPrivateTabIsNothingTheMacWaitsFor() {
        app.browser.macAsleep = true
        app.openPrivately(PageFixtures.search("gift ideas for jonas"))
        let id = app.browser.tab!.id
        app.closePrivate(id)
        XCTAssertEqual(app.browser.pendingForMac, 0)
    }

    // MARK: - links from other apps

    func testLinksFromOtherApps() {
        let lumen = URL(string: "https://lumen.events/e/design-systems-night")!
        XCTAssertEqual(Links.page(for: lumen), lumen)
        XCTAssertEqual(Links.page(for: URL(string: "yab-open://https%3A%2F%2Flumen.events%2Fe%2Fdesign-systems-night")!), lumen)
        XCTAssertEqual(Links.page(for: Links.wrapped(lumen)!), lumen)
        XCTAssertEqual(Links.page(for: URL(string: "yab-open://lumen.events")!)?.absoluteString, "https://lumen.events")
        XCTAssertNil(Links.page(for: URL(string: "mailto:anna@example.com")!))
        XCTAssertNil(Links.page(for: URL(string: "yab-open://")!))
    }

    func testALinkPutsAwayWhatStoodOverThePage() {
        let lumen = URL(string: "https://lumen.events/e/design-systems-night")!
        app.surfaces.openChat(.newChat)
        app.openLink(lumen)
        XCTAssertNil(app.surfaces.chat, "nothing is left above the page")
        app.surfaces.openSettings()
        app.openLink(lumen)
        XCTAssertFalse(app.surfaces.settings)
        app.surfaces.openJoin()
        app.openLink(lumen)
        XCTAssertFalse(app.surfaces.join, "the join sheet also leaves the page in front")
        app.surfaces.openMenu(.plate)
        app.openLink(lumen)
        XCTAssertNil(app.surfaces.menu)
    }

    func testEditingALiveAddressPreservesItsSchemeHostAndEncodedParts() {
        let live = AppModel(world: app.world, fixturesEnabled: false)
        let original = "http://www.example.com/A?q=two%20words#part"
        live.browser.open(PageFixtures.liveTab(for: URL(string: original)!))
        let id = live.browser.tab?.id
        live.surfaces.openField(.address)
        XCTAssertEqual(live.field.text, original)
        live.field.editAddress()
        live.field.typed(live.field.text.replacingOccurrences(of: "/A", with: "/B"))
        live.fieldReturn()
        XCTAssertEqual(live.browser.tab?.id, id)
        XCTAssertEqual(live.browser.tab?.navigationURL?.absoluteString, "http://www.example.com/B?q=two%20words#part")
    }

    func testLiveLinkKeepPreservesSchemePathCaseAndFragment() {
        let live = AppModel(world: app.world, fixturesEnabled: false)
        let original = PageFixtures.liveTab(for: URL(string: "https://example.com/Case")!, id: "original")
        live.browser.open(original)
        live.browser.keep(original.id)
        let before = live.browser.allTabs.count
        let variants = ["http://example.com/Case", "https://example.com/case", "https://example.com/Case#second"]
        for (index, address) in variants.enumerated() {
            let page = PageFixtures.liveTab(for: URL(string: address)!)
            live.keepLink(page)
            XCTAssertEqual(live.browser.tab?.navigationURL?.absoluteString, address)
            XCTAssertNotEqual(live.browser.tab?.id, original.id)
            XCTAssertEqual(live.browser.allTabs.count, before + index + 1)
        }
        let count = live.browser.allTabs.count
        live.keepLink(original)
        XCTAssertEqual(live.browser.allTabs.count, count, "the identical kept URL still reuses its row")
        XCTAssertEqual(live.browser.tab?.id, original.id)
    }

    /// +: New Tab's field grows out of the button.
    func testPlusGrowsIntoNewTabsField() async throws {
        FieldMotion.lately = []
        let plus = CGRect(x: 346, y: 806, width: 44, height: 44)
        Motion.plusToField.run { app.surfaces.openField(.newTab, from: plus) }
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertEqual(app.field.origin, plus, "it starts in the button's frame")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FieldMotion.lately.contains("plusToField"), "\(FieldMotion.lately)")
        XCTAssertEqual(app.field.progress, 1)
    }

    func testNewTabsRowsFitOverTheIPhonesKeyboard() {
        // The 17 Pro's keyboard is 308, the prototype's 302: the card still takes its 500.
        let g = FieldGeometry(size: CGSize(width: 402, height: 874), keyboard: 308, mode: .newTab)
        XCTAssertGreaterThanOrEqual(g.newTabMaxHeight, 500)
        XCTAssertEqual(g.newTabBottom, 874 - 308 - 8)
        XCTAssertGreaterThanOrEqual(g.newTabBottom - g.newTabMaxHeight, Metrics.statusBar, "never into the status bar")
    }

    func testALinkOpensAsANewTab() {
        let count = app.browser.space.today.count
        app.openLink(URL(string: "yab-open://https%3A%2F%2Fnordbutik.se%2Ffjord-linen-throw")!)
        XCTAssertEqual(app.browser.space.today.count, count + 1)
        XCTAssertEqual(app.browser.space.today.first?.id, app.browser.tab?.id, "at the top of today's, in front")
    }

    func testALinkAlreadyOpenMovesToTheTopWithoutADouble() {
        let today = app.browser.space.today.map(\.id)
        XCTAssertTrue(today.contains("work-lumen"))
        app.openLink(URL(string: "https://lumen.events/e/design-systems-night")!)
        XCTAssertEqual(app.browser.space.today.first?.id, "work-lumen", "the same page moved to the top")
        XCTAssertEqual(app.browser.space.today.count, today.count, "no double")
        XCTAssertEqual(app.browser.tab?.id, "work-lumen")
    }
}
