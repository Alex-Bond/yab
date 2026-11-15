import XCTest
@testable import YabPhone

/// The worlds the app carries load, and mira is the prototype's.
@MainActor
final class WorldTests: XCTestCase {
    func testEveryWorldLoads() throws {
        XCTAssertFalse(World.available.isEmpty, "the app carries no worlds")
        for name in World.available {
            XCTAssertNoThrow(try World.load(named: name), name)
        }
    }

    func testMiraIsThePrototypesWorld() throws {
        let world = try World.load(named: "mira")
        XCTAssertEqual(world.spaces.map(\.name), ["Personal", "Work", "Lisbon"])
        XCTAssertEqual(world.spaces.map(\.emoji), ["🏠", "💼", "✈️"])
        XCTAssertEqual(world.space, "work")
        let work = try XCTUnwrap(world.spaces.first { $0.id == "work" })
        XCTAssertEqual(work.tint, RGB(226, 233, 244))
        XCTAssertEqual(work.current, "work-figma-onb")
        XCTAssertEqual(work.pins.count, 5)
        // Mail stays on the Mac.
        XCTAssertEqual(work.visiblePins.map(\.site), ["Daybook", "Linear", "Slack", "Figma"])
        XCTAssertEqual(work.folders.map(\.name), ["Onboarding v3"])
        XCTAssertEqual(work.today.map(\.id), ["work-hn", "work-gh-pr", "work-tern-local", "work-lumen", "work-linear-method"])
        XCTAssertEqual(work.onMac?.id, "work-tern-local")
        XCTAssertEqual(work.tab("work-tern-local")?.port, ":5173")
        XCTAssertEqual(world.taskDefinitions.map(\.id), ["lumen", "lisbon", "anna"])
        XCTAssertTrue(world.tasks.isEmpty, "the atlas starts with nothing running")
        XCTAssertEqual(world.chats.filter(\.archived).count, 2)
        XCTAssertEqual(world.chats.first { $0.id == "plan" }?.pinned, true)
        XCTAssertNil(world.problem)
    }

    func testPlacesAreSetFromWhereTabsLive() throws {
        let world = try World.load(named: "mira")
        let work = try XCTUnwrap(world.spaces.first { $0.id == "work" })
        XCTAssertTrue(work.pins.allSatisfy { $0.place == .pinned })
        XCTAssertTrue(work.keptTabs.allSatisfy { $0.place == .kept })
        XCTAssertTrue(work.today.allSatisfy { $0.place == .today })
    }

    func testDarkPagesAreMarked() throws {
        let world = try World.load(named: "mira")
        let personal = try XCTUnwrap(world.spaces.first { $0.id == "personal" })
        XCTAssertEqual(personal.today[1].page, "youtube")
        XCTAssertTrue(personal.today[1].dark)
        XCTAssertFalse(personal.today[0].dark)
    }

    func testEveryTabsPageIsInTheApp() throws {
        for name in World.available {
            for space in try World.load(named: name).spaces {
                for tab in space.allTabs {
                    guard let page = tab.page else { continue }
                    XCTAssertTrue(PageSchemeHandler.hasPage(page), "\(name): \(tab.id) shows \(page).html, which the app doesn't carry")
                }
            }
        }
    }

    func testAWrongWorldSaysWhy() {
        let tab = Tab(id: "a", title: "A", site: "A", icon: "a")
        let world = World(name: "x", space: "s", spaces: [Space(id: "s", name: "S", emoji: "", tint: RGB(0, 0, 0), today: [tab, tab])])
        XCTAssertEqual(world.problem, "tab a twice")
        let elsewhere = World(name: "y", space: "nowhere", spaces: [Space(id: "s", name: "S", emoji: "", tint: RGB(0, 0, 0))])
        XCTAssertEqual(elsewhere.problem, "no space nowhere to start in")
    }

    func testWorldDataStoresDiffer() throws {
        let mira = try World.load(named: "mira")
        XCTAssertEqual(mira.dataStoreID, try World.load(named: "mira").dataStoreID)
        XCTAssertNotEqual(mira.dataStoreID, World(name: "other", space: "s", spaces: []).dataStoreID)
    }
}

/// The stores do what the column and the plate will ask of them.
@MainActor
final class StoreTests: XCTestCase {
    func testSelectBringsTheSpaceAndOpensTheFolder() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        XCTAssertEqual(store.tab?.id, "work-figma-onb")
        store.select("personal-rams")
        XCTAssertEqual(store.space.id, "personal")
        XCTAssertEqual(store.tab?.id, "personal-rams")
        XCTAssertTrue(store.space.folders.first?.open ?? false)
    }

    func testPagingWalksTheRowsInOrder() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        XCTAssertEqual(store.pagingOrder.prefix(3).map(\.id), ["work-figma-onb", "work-onb-spec", "work-onb-funnel"])
        XCTAssertNil(store.neighbors.before)
        XCTAssertTrue(store.page(by: 1))
        XCTAssertEqual(store.tab?.id, "work-onb-spec")
        store.select("work-linear-method")
        XCTAssertFalse(store.page(by: 1), "past the last tab is New Tab's, not a tab")
    }

    func testClearKeepsTheTabInFront() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        store.select("work-lumen")
        XCTAssertEqual(store.clearToday(), 4)
        XCTAssertEqual(store.space.today.map(\.id), ["work-lumen"])
    }

    func testKeepAndUnkeep() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        store.keep("work-hn")
        XCTAssertEqual(store.tab("work-hn")?.place, .kept)
        store.unkeep("work-hn")
        XCTAssertEqual(store.space.today.first?.id, "work-hn")
        store.move("work-hn", to: "lisbon")
        XCTAssertEqual(store.space("lisbon")?.today.first?.id, "work-hn")
        XCTAssertNil(store.space("work")?.tab("work-hn"))
    }

    func testPinAndUnpinAsOnTheMac() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        let pins = store.space("work")?.pins.count ?? 0
        store.pin("work-hn")
        XCTAssertEqual(store.tab("work-hn")?.place, .pinned)
        XCTAssertEqual(store.space("work")?.pins.last?.id, "work-hn")
        XCTAssertEqual(store.space("work")?.pins.count, pins + 1)
        XCTAssertFalse(store.space("work")?.today.contains { $0.id == "work-hn" } ?? true)
        store.unpin("work-hn")
        XCTAssertEqual(store.tab("work-hn")?.place, .today)
        XCTAssertEqual(store.space("work")?.today.first?.id, "work-hn")
        XCTAssertEqual(store.space("work")?.pins.count, pins)
        // A kept tab leaves its actual folder, keeping the selected tab.
        store.select("work-onb-spec")
        XCTAssertNotNil(store.space("work")?.folder(holding: "work-onb-spec"))
        store.pin("work-onb-spec")
        store.pin("work-onb-spec")
        XCTAssertEqual(store.tab("work-onb-spec")?.place, .pinned)
        XCTAssertNil(store.space("work")?.folder(holding: "work-onb-spec"))
        XCTAssertFalse(store.space("work")?.keptTabs.contains { $0.id == "work-onb-spec" } ?? true)
        XCTAssertEqual(store.space("work")?.pins.filter { $0.id == "work-onb-spec" }.count, 1)
        XCTAssertEqual(store.space("work")?.current, "work-onb-spec")
    }

    func testPrivateTabsCannotBePinnedAndMailCannotBeUnpinned() throws {
        let secret = Tab(id: "secret", title: "Secret", site: "Example", icon: "example", isPrivate: true)
        let store = BrowserStore(world: World(name: "private", space: "s", spaces: [
            Space(id: "s", name: "S", emoji: "", tint: RGB(0, 0, 0), today: [secret])
        ]))
        store.pin(secret.id)
        XCTAssertTrue(store.space.pins.isEmpty)
        XCTAssertEqual(store.space.today.map(\.id), [secret.id])
        let mira = BrowserStore(world: try World.load(named: "mira"))
        let mail = try XCTUnwrap(mira.space.pins.first { $0.isMail })
        mira.unpin(mail.id)
        XCTAssertEqual(mira.tab(mail.id)?.place, .pinned)
    }

    func testTheNowLineSaysTheMostImportantThing() throws {
        let world = try World.load(named: "mira")
        let tasks = TaskStore(world: world)
        XCTAssertNil(NowLine.item(tasks: tasks, parked: nil), "nothing running: no line")
        tasks.start("lisbon")
        tasks.set("lisbon", status: .running, step: 1)
        var item = try XCTUnwrap(NowLine.item(tasks: tasks, parked: nil))
        XCTAssertEqual(item.title, "Lisbon flights")
        XCTAssertEqual(item.subtitle, "Comparing 4 direct flights")
        XCTAssertEqual(item.short, "4 direct")
        XCTAssertEqual(item.icon, .favicon("google"))
        XCTAssertNil(item.more)
        tasks.start("lumen")
        tasks.set("lumen", status: .running, step: 1)
        tasks.set("lisbon", status: .code, step: 2)
        item = try XCTUnwrap(NowLine.item(tasks: tasks, parked: nil))
        XCTAssertEqual(item.kind, .warn)
        XCTAssertEqual(item.action, "Enter Code")
        XCTAssertEqual(item.subtitle, "Needs the code TAP sent you")
        XCTAssertEqual(item.more, "+1")
        tasks.set("lisbon", status: .yes, step: 3)
        XCTAssertEqual(NowLine.item(tasks: tasks, parked: nil)?.action, "Review")
        tasks.set("lisbon", status: .done, step: 3)
        tasks.set("lumen", status: .done)
        item = try XCTUnwrap(NowLine.item(tasks: tasks, parked: nil))
        XCTAssertEqual(item.kind, .done)
        XCTAssertEqual(item.more, "+1 done")
    }
}
