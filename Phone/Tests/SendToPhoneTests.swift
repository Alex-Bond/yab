import SyncKit
import XCTest
@testable import YabPhone

/// Send to iPhone on the iPhone: its own capability, a page from the Mac
/// taken once, refused when stale, and shown at once or as the Now line's
/// chip in Today.
@MainActor
final class SendToPhoneTests: PhoneLinkTestCase {
    // MARK: - Send to iPhone, the records

    func testTheIPhoneSaysItTakesPagesInItsOwnRecord() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        let engine = try engine(server, seal)
        engine.start()
        defer { engine.stop(); mac.client.stop() }
        let said = await until {
            OpenOnPhone.supports(mac.journal.record(.init(collection: OpenOnMac.capability, id: "phone")), device: "phone")
        }
        XCTAssertTrue(said, "the Mac reads that this iPhone takes pages")
        // The Mac's own commandcap stays the Mac's: an iPhone never writes it.
        XCTAssertFalse(OpenOnPhone.supports(engine.journal.record(.init(collection: OpenOnMac.capability, id: "mac")), device: "mac"))
    }

    func testAPageFromTheMacIsTakenOnceAndTheMacHearsIt() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        let engine = try engine(server, seal)
        engine.start()
        defer { engine.stop(); mac.client.stop() }
        try mac.write("send", "page-one", OpenOnMac.fields(device: "phone", sender: "mac", url: essay, at: Date(), title: "How to Do Great Work"))
        let came = await until { !engine.arrivals().isEmpty }
        XCTAssertTrue(came)
        let page = try XCTUnwrap(engine.arrivals().first)
        XCTAssertEqual(page.title, "How to Do Great Work")
        XCTAssertEqual(page.sender, "mac")
        var opened = 0
        XCTAssertTrue(engine.take(page) { _ in opened += 1 })
        XCTAssertFalse(engine.take(page) { _ in opened += 1 }, "once")
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(engine.arrivals().isEmpty)
        let heard = await until { mac.journal.record(.init(collection: "send", id: "page-one"))?["state"]?.string == "taken" }
        XCTAssertTrue(heard, "the Mac hears it was taken")
    }

    func testAStalePageIsRefusedAndAPageForAnotherDeviceIsNotThisOnes() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try await mac(server, seal)
        let engine = try engine(server, seal)
        engine.start()
        defer { engine.stop(); mac.client.stop() }
        try mac.write("send", "late", OpenOnMac.fields(device: "phone", sender: "mac", url: essay,
                                                        at: Date().addingTimeInterval(-OpenOnMac.lifetime - 60)))
        try mac.write("send", "elsewhere", OpenOnMac.fields(device: "other-phone", sender: "mac", url: essay, at: Date()))
        let came = await until { engine.arrivals().map(\.id) == ["late"] }
        XCTAssertTrue(came, "\(engine.arrivals().map(\.id))")
        var opened = 0
        XCTAssertFalse(engine.take(try XCTUnwrap(engine.arrivals().first)) { _ in opened += 1 })
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(engine.journal.record(.init(collection: "send", id: "late"))?["state"]?.string, "expired")
        XCTAssertNil(engine.journal.record(.init(collection: "send", id: "elsewhere"))?["state"])
    }

    // MARK: - the arrived page in the app

    private func arrival(sent: Date = Date()) -> OpenOnPhone.Arrival {
        OpenOnPhone.Arrival(id: UUID().uuidString, url: essay, title: "How to Do Great Work", space: nil, sender: "mac", sent: sent)
    }

    func testThePageLandsInTodayWithItsCardAndOpenBringsItUp() throws {
        let app = try miraApp()
        app.sync.pretendMac(awake: true, front: nil)
        let before = app.browser.tab?.id
        app.sync.pretendArrival(arrival(), front: false)
        let card = try XCTUnwrap(app.nowItem)
        XCTAssertEqual(card.kind, .arrived)
        XCTAssertEqual(card.title, "From MacBook Pro")
        XCTAssertEqual(card.chip?.words, "From MacBook Pro: How to Do Great Work")
        XCTAssertEqual(card.action, "Open")
        XCTAssertNil(card.taskID)
        XCTAssertEqual(app.browser.tab?.id, before, "the page in front stays")
        let landed = try XCTUnwrap(app.tasks.arrived)
        XCTAssertEqual(app.browser.space.today.first?.id, landed.tab, "at the top of Today")
        XCTAssertEqual(app.browser.tab(landed.tab)?.title, "How to Do Great Work")
        app.tapNow(action: "Open", from: .zero)
        XCTAssertEqual(app.browser.tab?.id, landed.tab)
        XCTAssertNil(app.tasks.arrived)
    }

    func testTheCardPutAwayLeavesThePageInToday() throws {
        let app = try miraApp()
        app.sync.pretendMac(awake: true, front: nil)
        app.sync.pretendArrival(arrival(), front: false)
        let landed = try XCTUnwrap(app.tasks.arrived)
        app.dismissNow()
        XCTAssertNil(app.tasks.arrived)
        XCTAssertNotNil(app.browser.tab(landed.tab))
        XCTAssertNotEqual(app.browser.tab?.id, landed.tab)
    }

    func testAPageInFrontOpensAtOnceAndSaysFromWhere() throws {
        let app = try miraApp()
        app.surfaces.toastsStay = true
        app.sync.pretendMac(awake: true, front: nil)
        app.sync.pretendArrival(arrival(), front: true)
        XCTAssertEqual(app.browser.tab?.title, "How to Do Great Work")
        XCTAssertNil(app.tasks.arrived, "no card for a page already in front")
        XCTAssertEqual(app.surfaces.toast?.text, "From MacBook Pro")
    }

    func testAPageAlreadyOpenIsBroughtUpNotOpenedTwice() throws {
        let app = try miraApp()
        app.sync.pretendMac(awake: true, front: nil)
        app.sync.pretendArrival(arrival(), front: false)
        let count = app.browser.allTabs.count
        app.sync.pretendArrival(arrival(), front: true)
        XCTAssertEqual(app.browser.allTabs.count, count)
        XCTAssertEqual(app.browser.tab?.title, "How to Do Great Work")
    }
}
