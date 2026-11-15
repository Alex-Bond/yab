import XCTest
@testable import YabPhone

@MainActor
final class WatchdogPersistenceTests: XCTestCase {
    func testActivitySaveDoesNotWriteDuringSceneCallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WatchdogSave-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder)
        let tabs = (0..<1000).map { Tab(id: "tab-\($0)", title: "Owned", site: "Owned", icon: "globe", url: "about:blank") }
        let space = Space(id: "owned", name: "Owned", emoji: "", tint: RGB(238,233,226), today: tabs, current: tabs[0].id)
        let browser = BrowserStore(world: World(name: "owned", space: space.id, spaces: [space]))
        let ledger = TabActivityProfile(profile: profile)
        for tab in tabs {
            ledger.put(.init(space: space.id, address: tab.url, last: .now, localOnly: true), for: tab, space: space)
        }
        ledger.save(browser: browser)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("tab-activity.json").path),
                       "scene callback must return before encoding and writing the activity ledger")
    }
}
