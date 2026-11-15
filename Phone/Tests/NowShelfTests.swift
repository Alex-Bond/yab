import Foundation
import SyncKit
import XCTest
@testable import YabPhone

/// The Now widget's rows: a Mac's `now` records reach the phone in order
/// and leave with the Mac's; the shelf keeps at most three and draws again
/// only on a change; a row's link names it; Mail's link finds a message.
@MainActor
final class NowShelfTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-now-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    private func row(_ n: Int, order: Int) -> NowShelfRow {
        NowShelfRow(id: "mail.t\(n)", title: "Row \(n)", detail: "12m · Re: \(n)", who: "Danny", host: "gmail.com",
                    web: "https://mail.google.com/mail/u/me@example.com/#all/t\(n)", message: "<t\(n)@mail>", order: order)
    }

    func testAMacsRowsComeAndGo() async throws {
        let server = SyncMemoryServer(), seal = Seal.make()
        let mac = try TestMac(server: server, seal: seal, id: "mac")
        mac.client.start()
        let live = await until { mac.client.state == .live }
        XCTAssertTrue(live)
        try mac.write(SyncCollection.now, "mail.t2", ["title": "Chase card payment", "detail": "Chase · today 12:00", "who": "Chase",
                                                      "host": "chase.com", "order": 1, "device": "mac"])
        try mac.write(SyncCollection.now, "mail.t1", ["title": "Danny says hi", "detail": "12m · Re: Hi", "who": "Danny",
                                                      "host": "gmail.com", "web": "https://mail.google.com/mail/u/me@example.com/#all/t1",
                                                      "message": "<t1@mail>", "order": 0, "device": "mac"])
        let phone = try PhoneSync(seal: seal, options: .init(base: URL(string: "https://sync.test")!, folder: folder.appendingPathComponent("sync"),
                                                              device: .init(id: "phone", name: "Test iPhone", model: "iPhone"),
                                                              transport: server))
        defer { phone.stop(); mac.client.stop() }
        phone.start()
        let came = await until { phone.nowRows().count == 2 }
        XCTAssertTrue(came)
        let shelf = NowShelf(file: folder.appendingPathComponent("now.json"))
        phone.shelveNow(shelf)
        XCTAssertEqual(shelf.read().map(\.id), ["mail.t1", "mail.t2"])
        XCTAssertEqual(shelf.read().first?.message, "<t1@mail>")

        // Answered on the Mac: its row leaves the phone.
        try mac.journal.remove(.init(collection: SyncCollection.now, id: "mail.t1"))
        mac.client.kick()
        let went = await until { phone.nowRows().map(\.id) == ["mail.t2"] }
        XCTAssertTrue(went)
    }

    func testTheShelfKeepsThreeInOrderAndWritesOnlyChanges() {
        let shelf = NowShelf(file: folder.appendingPathComponent("now.json"))
        XCTAssertTrue(shelf.read().isEmpty)
        XCTAssertTrue(shelf.write([row(4, order: 3), row(2, order: 1), row(1, order: 0), row(3, order: 2)]))
        XCTAssertEqual(shelf.read().map(\.id), ["mail.t1", "mail.t2", "mail.t3"])
        XCTAssertFalse(shelf.write([row(1, order: 0), row(2, order: 1), row(3, order: 2)]))
        XCTAssertTrue(shelf.write([]))
        XCTAssertTrue(shelf.read().isEmpty)
        XCTAssertFalse(NowShelf(file: nil).write([row(1, order: 0)]))
    }

    func testARowsLinkNamesIt() {
        let link = row(1, order: 0).link
        XCTAssertEqual(link.scheme, "yab")
        XCTAssertEqual(NowShelf.id(in: link), "mail.t1")
        XCTAssertNil(YabRoute(link))
        XCTAssertNil(NowShelf.id(in: URL(string: "yab://new")!))
    }

    func testMailsLinkFindsTheMessage() {
        XCTAssertEqual(NowOpen.mailLink("<CAB123@mail.gmail.com>")?.absoluteString, "message://%3CCAB123@mail.gmail.com%3E")
        XCTAssertEqual(NowOpen.mailLink("abc@x.com")?.absoluteString, "message://%3Cabc@x.com%3E")
        XCTAssertNil(NowOpen.mailLink(""))
        XCTAssertNil(NowOpen.mailLink(nil))
    }
}
