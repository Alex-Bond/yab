import XCTest
@testable import YabPhone

final class ChatTrayGeometryTests: XCTestCase {
    private let screen = CGSize(width: 402, height: 874)

    private func tray(_ pose: SheetPose) -> SheetGeometry {
        SheetGeometry(screen: screen, pose: pose, origin: nil,
                      now: SheetGeometry.nowShape(screen: screen), tray: true)
    }

    func testTheTrayStandsUpToTheActualFullWindow() {
        let recent = tray(SheetPose(t: 0, h: 388)).rest
        let all = tray(SheetPose(t: 1, h: 388)).rest
        XCTAssertEqual(recent.rect, CGRect(x: 8, y: 478, width: 386, height: 388))
        XCTAssertEqual(all.rect, CGRect(origin: .zero, size: screen))
        XCTAssertEqual(all.rect.maxY, screen.height)
        XCTAssertEqual(recent.top, 38)
        XCTAssertEqual(all.bottom, Metrics.Chats.trayFullRadius)
    }

    func testConversationGrowsTheExistingTrayIntoTheScreen() {
        let full = tray(SheetPose(t: 1, h: 388))
        XCTAssertEqual(full.rest.rect, CGRect(origin: .zero, size: screen))
        XCTAssertEqual(full.rest.top, 0)
        XCTAssertEqual(full.rest.bottom, 0)
        XCTAssertEqual(full.headHeight, Metrics.Chats.conversationHeader + Metrics.Chats.trayFullHeaderTop)
        let half = tray(SheetPose(t: 0.5, h: 388)).rest
        XCTAssertEqual(half.rect.minY, 239, accuracy: 0.01)
        XCTAssertEqual(half.rect.maxY, 870, accuracy: 0.01)
        XCTAssertEqual(half.top, 19)
    }

    func testNewChatAndSearchStayAboveTheActualKeyboard() {
        let new = tray(SheetPose(t: 1, k: 302, h: Metrics.Chats.newTrayHeight)).rest
        XCTAssertEqual(new.rect, CGRect(x: 0, y: 0, width: 402, height: 572))
        let search = tray(SheetPose(t: 1, k: 302, h: 388)).rest
        XCTAssertEqual(search.rect.minY, 0)
        XCTAssertEqual(search.rect.maxY, screen.height - 302)
        let answer = SheetGeometry(screen: screen, pose: SheetPose(t: 0, h: 343),
                                   origin: nil, now: SheetGeometry.nowShape(screen: screen))
        XCTAssertEqual(answer.rest.rect.height, 343, "quick answers keep their original geometry")
        XCTAssertEqual(answer.rest.top, 38)
    }
    @MainActor
    func testPinRaisesAnOlderChatOnTheChatsPageAndUnpinRestoresItsBucket() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        func recent() -> [Chat.ID] {
            Array(ChatSectioning.listed(app.chats.chats, sheet: app.chatSheet).prefix(3).map(\.id))
        }
        XCTAssertEqual(recent(), ["plan", "lisbon", "lumen"])
        app.setPinned("weekend", true)
        XCTAssertEqual(recent(), ["plan", "weekend", "lisbon"])
        XCTAssertTrue(try XCTUnwrap(app.chats.chat("weekend")).pinned)
        app.setPinned("weekend", false)
        XCTAssertEqual(recent(), ["plan", "lisbon", "lumen"])
        let rows = ChatSectioning.listed(app.chats.chats, sheet: app.chatSheet).map(\.id)
        XCTAssertGreaterThan(try XCTUnwrap(rows.firstIndex(of: "weekend")),
                             try XCTUnwrap(rows.firstIndex(of: "lisbon")))
        XCTAssertFalse(rows.contains("arch-kitchen"))
    }

}
