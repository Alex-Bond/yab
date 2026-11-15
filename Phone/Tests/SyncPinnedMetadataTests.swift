import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class SyncPinnedMetadataTests: XCTestCase {
    private func mac(_ mark: String? = "icon:star") -> SyncTab {
        SyncTab(id: "pin", space: "s", url: "https://example.test/pin", title: "Website title", pin: "E",
                name: "My workspace", customMark: mark)
    }

    private func json(_ tab: YabPhone.Tab) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
    }

    func testMacNameAndMarkAreCarriedIntoTheProfile() throws {
        for mark in ["icon:star", "🌻", "image:workspace.png"] {
            let tab = SyncMapping.tab(mac(mark), id: "pin", old: nil, fixturesEnabled: false)
            let restored = try JSONDecoder().decode(YabPhone.Tab.self, from: JSONEncoder().encode(tab))
            XCTAssertEqual(restored.title, "My workspace")
            XCTAssertEqual(try json(restored)["name"] as? String, "My workspace", "the deliberate name needs its own field")
            XCTAssertEqual(try json(restored)["customMark"] as? String, mark, "the Mac's custom icon must reach the iPhone")
        }
    }

    func testLoadingAndNavigatingThePinCannotRenameIt() throws {
        let initial = SyncMapping.tab(mac(), id: "pin", old: nil, fixturesEnabled: false)
        let app = AppModel(world: World(name: "pins", space: "s", spaces: [
            Space(id: "s", name: "Work", emoji: "", tint: RGB(240, 240, 240), pins: [initial], current: "pin")
        ]), fixturesEnabled: false, privateLockEnabled: { false })
        for path in ["pin", "next"] {
            app.pages.onMetadata?("pin", URL(string: "https://example.test/\(path)")!, "Loaded page title")
            let tab = try XCTUnwrap(app.browser.tab("pin"))
            XCTAssertEqual(tab.title, "My workspace", "page metadata must not replace the Mac's chosen name")
            XCTAssertEqual(try json(tab)["customMark"] as? String, "icon:star")
            XCTAssertEqual(tab.url, "https://example.test/\(path)")
        }
    }

    func testMacChangesAndRemovalReplaceTheOldNameAndMarkAtTheSameAddress() throws {
        let initial = SyncMapping.tab(mac(), id: "pin", old: nil, fixturesEnabled: false)
        let changed = SyncMapping.tab(mac("🌻"), id: "pin", old: initial, fixturesEnabled: false)
        XCTAssertEqual(try json(changed)["customMark"] as? String, "🌻")
        var plain = mac(nil)
        plain.name = nil
        let cleared = SyncMapping.tab(plain, id: "pin", old: changed, fixturesEnabled: false)
        XCTAssertEqual(cleared.title, "Website title")
        XCTAssertNil(try json(cleared)["name"])
        XCTAssertNil(try json(cleared)["customMark"])
    }

    func testOfflineMirrorDoesNotTurnTheChosenNameIntoAPageTitle() throws {
        let synced = mac()
        let tab = SyncMapping.tab(synced, id: "pin", old: nil, fixturesEnabled: false)
        var old = SyncMirror()
        var ids = IDs()
        old.tabs[ids.sync("pin")] = synced
        let mirrored = SyncBridge.mirror(of: [Space(id: "s", name: "Work", emoji: "", tint: RGB(1, 2, 3), pins: [tab])],
                                         ids: &ids, keeping: old, fixturesEnabled: false)
        let back = try XCTUnwrap(mirrored.tabs[ids.sync("pin")])
        XCTAssertEqual(back.name, "My workspace")
        XCTAssertEqual(back.customMark, "icon:star")
    }
}
