import XCTest
@testable import YabPhone

/// The ways into Yab from outside it, on the model: what the share sheet
/// finds in shared items, the App Group's queue the extension and the app
/// share, the widgets' yab:// routes, and what the app does with the links
/// it takes. The fingers are UITests/EntrancesTests.
@MainActor
final class EntrancesTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        Motion.disabled = true
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shared-links-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func mira() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
    }

    // MARK: - what was shared

    func testAWebURLItemComesFirstWithTheTitleTheAppGave() {
        let found = SharedItems.find(urls: [URL(string: "https://lumen.events/e/design-systems-night")!],
                                     texts: ["Join us https://example.com"], title: "Design Systems Night")
        XCTAssertEqual(found, SharedItems.Found(address: "https://lumen.events/e/design-systems-night", search: false,
                                                title: "Design Systems Night"))
        XCTAssertEqual(found?.host, "lumen.events")
    }

    func testURLsThatArentWebPagesAreSkippedForALinkInTheText() {
        let found = SharedItems.find(urls: [URL(string: "file:///tmp/notes.txt")!, URL(string: "mailto:anna@example.com")!],
                                     texts: ["See https://example.com/a?b=1."])
        XCTAssertEqual(found?.address, "https://example.com/a?b=1", "the sentence's full stop isn't the link's")
        XCTAssertEqual(found?.search, false)
    }

    func testALinkWrittenWithoutASchemeStaysAsWritten() {
        XCTAssertEqual(SharedItems.link(in: "Look at www.apple.com/iphone tonight"), "www.apple.com/iphone")
        XCTAssertEqual(SharedItems.Found(address: "www.apple.com/iphone", search: false).host, "apple.com")
        XCTAssertEqual(SharedItems.link(in: "  https://news.ycombinator.com/item?id=1  "), "https://news.ycombinator.com/item?id=1")
    }

    func testWordsWithoutALinkAreASearchAnEmailAddressIsNoPage() {
        XCTAssertNil(SharedItems.link(in: "write to anna@example.com"))
        let found = SharedItems.find(urls: [], texts: ["  quiet   cafes\nnear  Södermalm "])
        XCTAssertEqual(found, SharedItems.Found(address: "quiet cafes near Södermalm", search: true, title: nil))
        let long = SharedItems.find(urls: [], texts: [String(repeating: "word ", count: 200)])
        XCTAssertEqual(long?.address.count, SharedItems.searchLimit)
        XCTAssertNil(SharedItems.find(urls: [], texts: ["   ", "\n"]))
        XCTAssertNil(SharedItems.find(urls: [], texts: []))
    }

    func testATitleIsALineNeverTheLinkAgain() {
        let link = "https://example.com/a"
        XCTAssertNil(SharedItems.clean(link, besides: link))
        XCTAssertNil(SharedItems.clean("example.com", besides: link), "a title that is itself a link says nothing")
        XCTAssertEqual(SharedItems.clean("  First line\nsecond", besides: link), "First line")
        let cut = SharedItems.clean(String(repeating: "a", count: 300), besides: link)
        XCTAssertEqual(cut?.count, SharedItems.titleLimit)
        XCTAssertEqual(cut?.last, "…")
    }

    // MARK: - the queue

    func testLinksComeOutOldestFirstOnceAndTheQueueEmpties() {
        let queue = SharedLinkQueue(folder: folder)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(queue.add(SharedLink(action: .open, address: "https://b.example", date: start.addingTimeInterval(2))))
        XCTAssertTrue(queue.add(SharedLink(action: .keep, address: "a.example/x", title: "A", date: start)))
        XCTAssertTrue(queue.add(SharedLink(action: .open, address: "cafes", search: true, date: start.addingTimeInterval(1))))
        XCTAssertEqual(queue.count, 3)
        let taken = queue.take()
        XCTAssertEqual(taken.map(\.address), ["a.example/x", "cafes", "https://b.example"])
        XCTAssertEqual(taken.first, SharedLink(action: .keep, address: "a.example/x", title: "A", date: start))
        XCTAssertEqual(taken[1].search, true)
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.take(), [], "taken once")
    }

    func testTheExtensionAndTheAppSeeOneQueueThroughTheFolder() {
        // Two values, as two processes hold them: what one writes the other takes.
        XCTAssertTrue(SharedLinkQueue(folder: folder).add(SharedLink(action: .open, address: "https://example.com")))
        XCTAssertEqual(SharedLinkQueue(folder: folder).take().map(\.address), ["https://example.com"])
    }

    func testNoAppGroupQueuesNothing() {
        let queue = SharedLinkQueue(folder: nil)
        XCTAssertFalse(queue.add(SharedLink(action: .open, address: "https://example.com")))
        XCTAssertEqual(queue.take(), [])
        XCTAssertEqual(queue.count, 0)
    }

    func testAFileThatIsntALinkGoesAndAWriteInProgressIsLeftAlone() throws {
        let queue = SharedLinkQueue(folder: folder)
        XCTAssertTrue(queue.add(SharedLink(action: .open, address: "https://example.com")))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("0-broken.json"))
        let temporary = folder.appendingPathComponent(".dat.nosync.json")
        try Data("{".utf8).write(to: temporary)
        XCTAssertEqual(queue.take().map(\.address), ["https://example.com"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("0-broken.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.path), "a hidden file is a write still going")
    }

    func testAQueueNobodyReadsKeepsOnlyTheNewest() {
        let queue = SharedLinkQueue(folder: folder)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<(SharedLinkQueue.limit + 5) {
            queue.add(SharedLink(action: .keep, address: "https://example.com/\(i)", date: start.addingTimeInterval(Double(i))))
        }
        let taken = queue.take()
        XCTAssertEqual(taken.count, SharedLinkQueue.limit)
        XCTAssertEqual(taken.first?.address, "https://example.com/5")
        XCTAssertEqual(taken.last?.address, "https://example.com/\(SharedLinkQueue.limit + 4)")
    }

    func testTestRunsReadOnlyTheQueueATestNames() {
        let test = LaunchOptions(arguments: ["-YabWorld", "mira"])
        XCTAssertNil(Entrances.queue(options: test, environment: [:]), "never the person's queue")
        XCTAssertEqual(Entrances.queue(options: test, environment: ["YAB_SHARED_LINKS": folder.path])?.folder?.path, folder.path)
    }

    func testTheLinkRidesInTheURLWhenThereIsNoQueue() {
        let url = SharedLink.wrapped("https://lumen.events/e/design-systems-night?x=1&y=2")
        XCTAssertEqual(url.flatMap(Links.page(for:))?.absoluteString, "https://lumen.events/e/design-systems-night?x=1&y=2")
    }

    // MARK: - the routes

    func testRoutesRoundTripAndNothingElseIsOne() {
        for route in YabRoute.allCases { XCTAssertEqual(YabRoute(route.url), route) }
        XCTAssertEqual(YabRoute.shared.url.absoluteString, "yab://shared")
        XCTAssertEqual(YabRoute(URL(string: "YAB://Shared")!), .shared)
        XCTAssertNil(YabRoute(URL(string: "yab://task/lumen/open")!), "a task's link is TaskDesk's")
        XCTAssertNil(YabRoute(URL(string: "yab://shared/extra")!))
        XCTAssertNil(YabRoute(URL(string: "https://shared")!))
        XCTAssertNil(YabRoute(URL(string: "yab-open://shared")!))
    }

    func testAnAddressFromAnotherAppReadsAsTheFieldReadsIt() {
        XCTAssertEqual(Links.page(address: "example.com/a")?.absoluteString, "https://example.com/a")
        XCTAssertEqual(Links.page(address: " http://localhost:5173 ")?.absoluteString, "http://localhost:5173")
        XCTAssertNil(Links.page(address: "quiet cafes"))
        XCTAssertNil(Links.page(address: ""))
    }

    // MARK: - what the app does with them

    func testAnExternalLinkDismissesAllTabsAndShowsTheNewPage() throws {
        let app = try mira()
        let stack = TabStack.of(app)
        let before = app.browser.space.today.count
        let page = URL(string: "https://external.example.test/article")!
        stack.openGallery()
        XCTAssertNotNil(stack.gallery)

        app.openLink(page)

        XCTAssertEqual(app.browser.space.today.count, before + 1)
        XCTAssertEqual(app.browser.tab?.navigationURL, page)
        XCTAssertEqual(app.browser.space.today.first?.id, app.browser.tab?.id)
        XCTAssertNil(stack.gallery, "the newly selected page must not stay behind All Tabs")
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
        XCTAssertNil(app.surfaces.statusBarLight)
    }

    func testAnExternalLinkToTheCurrentPageDismissesAllTabsWithoutDuplicatingIt() throws {
        let app = try mira()
        let stack = TabStack.of(app)
        let front = try XCTUnwrap(app.browser.tab)
        let page = try XCTUnwrap(front.navigationURL)
        let before = app.browser.space.allTabs.count
        stack.openGallery()
        XCTAssertNotNil(stack.gallery)

        app.openLink(try XCTUnwrap(Links.wrapped(page)))

        XCTAssertEqual(app.browser.space.allTabs.count, before)
        XCTAssertEqual(app.browser.tab?.id, front.id)
        XCTAssertNil(stack.gallery, "selection can stay the same while its covering gallery must close")
        XCTAssertEqual(app.surfaces.chromeOpacity, 1)
    }

    func testKeepForLaterKeepsATabWhereYouWereWithoutOpeningIt() throws {
        let app = try mira()
        let front = app.browser.tab?.id
        app.takeShared([SharedLink(action: .keep, address: "https://theverge.com", title: "The Verge")])
        let kept = try XCTUnwrap(app.browser.space.keptTabs.last)
        XCTAssertEqual(kept.title, "The Verge")
        XCTAssertEqual(kept.place, .kept)
        XCTAssertEqual(app.browser.tab?.id, front, "the tab in front stays in front")
        XCTAssertEqual(app.surfaces.toast?.text, "Kept for later: The Verge")
    }

    func testKeepingAPageTodayHasAlreadyKeepsThatRow() throws {
        let app = try mira()
        let before = app.browser.space.allTabs.count
        app.takeShared([SharedLink(action: .keep, address: "https://lumen.events/e/design-systems-night")])
        XCTAssertEqual(app.browser.space.allTabs.count, before, "one page, one row")
        XCTAssertTrue(app.browser.space.keptTabs.contains { $0.id == "work-lumen" })
        XCTAssertFalse(app.browser.space.today.contains { $0.id == "work-lumen" })
    }

    func testOpenInYabBringsTheNewestToTheFrontAndEarlierOnesWaitInToday() throws {
        let app = try mira()
        let count = app.browser.space.today.count
        app.takeShared([
            SharedLink(action: .open, address: "https://theverge.com"),
            SharedLink(action: .open, address: "https://nordbutik.se/fjord-linen-throw"),
        ])
        XCTAssertEqual(app.browser.space.today.count, count + 2)
        XCTAssertNotEqual(app.browser.tab?.title, "The Verge")
        XCTAssertEqual(app.browser.space.today.first?.id, app.browser.tab?.id, "the newest at the top of today's, in front")
        XCTAssertEqual(app.browser.space.today.dropFirst().first?.title, "The Verge", "the earlier link waits under it")
        XCTAssertNil(app.surfaces.toast, "the page answers on screen")
    }

    func testWordsSharedAreSearchedWithTheEngineChosen() throws {
        let app = try mira()
        let page = try XCTUnwrap(app.sharedPage(SharedLink(action: .open, address: "quiet cafes", search: true)))
        XCTAssertEqual(page, app.field.searchSettings.searchSelection.url(for: "quiet cafes"))
        let count = app.browser.space.today.count
        app.takeShared([SharedLink(action: .open, address: "quiet cafes", search: true)])
        XCTAssertEqual(app.browser.space.today.count, count + 1)
    }

    func testWithPrivateInFrontAKeptLinkGoesToTheSpaceYouCameFrom() throws {
        let app = try mira()
        let ordinary = app.browser.spaceID
        app.openPrivately(PageFixtures.search("gift ideas for jonas"))
        XCTAssertTrue(app.browser.space.isPrivate)
        app.takeShared([SharedLink(action: .keep, address: "https://theverge.com")])
        XCTAssertTrue(app.browser.space(ordinary)?.keptTabs.contains { $0.title == "The Verge" } == true)
        XCTAssertFalse(app.browser.space.allTabs.contains { $0.title == "The Verge" }, "never a private row")
    }

    func testTheWidgetsOpenYabAtNewAndAsk() {
        XCTAssertEqual(SearchWidgetKind.search.route.url.absoluteString, "yab://new")
        XCTAssertEqual(SearchWidgetKind.ask.route.url.absoluteString, "yab://ask")
        XCTAssertEqual(YabRoute(URL(string: "YAB://Ask")!), .ask)
        XCTAssertEqual(Set(SearchWidgetKind.allCases.map(\.widgetKind)).count, 2, "each placed widget keeps its own kind")
    }

    func testTheSearchWidgetOpensNewTabsFieldAndAskANewChat() throws {
        let app = try mira()
        app.enterNewTab(privately: false)
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertFalse(app.field.isPrivate)
        app.enterAsk()
        XCTAssertNil(app.surfaces.field, "the field goes before the chat comes")
        XCTAssertEqual(app.surfaces.chat, .newChat)
    }

    func testShortcutsSearchOpensANewTabAndAnAddressItsPage() throws {
        let app = try mira()
        let count = app.browser.space.today.count
        app.enterSearch("hacker news")
        XCTAssertEqual(app.browser.space.today.count, count + 1)
        XCTAssertEqual(app.browser.tab?.title, "hacker news · Google Search")
        app.enterSearch("theverge.com")
        XCTAssertEqual(app.browser.tab?.title, "The Verge")
    }

    func testShortcutsNewPrivateTabOpensNewTabWithTheEyesShut() throws {
        let app = try mira()
        XCTAssertEqual(YabRoute(URL(string: "yab://private")!), .privateTab)
        app.enterNewTab(privately: true)
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertTrue(app.field.isPrivate)
    }
}
