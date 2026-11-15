import SyncKit
import XCTest
@testable import YabPhone

/// Pins made on the iPhone reach the Mac as its own: the site's letter,
/// every device's, out of any folder.
final class SyncPinTests: XCTestCase {
    private var folder: URL!
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-pin-\(UUID())")
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    func testPinAndUnpinWriteTheMacsFields() throws {
        let engine = try PhoneSync(seal: .make(), options: .init(base: URL(string: "https://sync.test")!, folder: folder,
                                                                device: .init(id: "phone", name: "Test iPhone", model: "iPhone"),
                                                                transport: SyncMemoryServer()))
        let opened = try engine.openTab(url: "https://www.example.com/a", title: "A", in: "space")
        XCTAssertEqual(opened.device, "phone")
        let pinned = try engine.move(opened.id, list: .pinned, at: .bottom)
        XCTAssertEqual(pinned.pin, "E")
        XCTAssertEqual(pinned.list, .pinned)
        XCTAssertNil(pinned.device)
        XCTAssertEqual(engine.tab(opened.id)?.pin, "E")
        let back = try engine.move(opened.id, list: .today, at: .top)
        XCTAssertNil(back.pin)
        XCTAssertEqual(back.list, .today)
        XCTAssertEqual(back.device, "phone")
        XCTAssertNil(engine.tab(opened.id)?.pin)
    }

    func testLetterIsTheSitesFirst() {
        XCTAssertEqual(SyncTab.monogram("https://www.github.com/x"), "G")
        XCTAssertEqual(SyncTab.monogram("about:blank"), "•")
    }

    func testOpenedAsAPinIsSharedImmediatelyAndKeepsItsLetterWhenMoved() throws {
        let engine = try PhoneSync(seal: .make(), options: .init(base: URL(string: "https://sync.test")!, folder: folder,
                                                                device: .init(id: "phone", name: "Test iPhone", model: "iPhone"),
                                                                transport: SyncMemoryServer()))
        let tab = try engine.openTab(url: "https://www.example.com/a", title: "A", in: "space", list: .pinned)
        XCTAssertEqual(tab.pin, "E")
        XCTAssertNil(tab.device)
        try engine.rename(tab.id, "Custom name")
        let moved = try engine.move(tab.id, to: "other", at: .bottom)
        XCTAssertEqual(moved.pin, "E")
        XCTAssertEqual(moved.name, "Custom name")
        XCTAssertNil(moved.device)
    }
}
