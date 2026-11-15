import XCTest
import UIKit
@testable import YabPhone

/// Diagnostic stage timings, distinct from a usable-window launch measurement.
@MainActor
final class LaunchWorkTests: XCTestCase {
    func testCachedIconRestoreStage() async throws {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SiteIcons")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let prefix = "launch-\(UUID().uuidString.lowercased())"
        let png = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.pngData()!
        let urls = (0..<2000).map { URL(string: "https://\(prefix)-\($0).invalid")! }
        let files = urls.map { folder.appendingPathComponent($0.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!) }
        defer { files.forEach { try? FileManager.default.removeItem(at: $0) } }
        for file in files { try png.write(to: file) }
        let icons = SiteIcons()
        var yielded = false
        let start = ProcessInfo.processInfo.systemUptime
        var heartbeatDelay = 0.0
        let heartbeat = Task { @MainActor in
            yielded = true
            heartbeatDelay = (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        await icons.restoreKept()
        let restoreMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let yieldedDuringRestore = yielded
        await heartbeat.value
        print("launch stage icons=2000 restore_ms=\(restoreMS) main_actor_yielded=\(yieldedDuringRestore) main_queue_delay_ms=\(heartbeatDelay)")
        XCTAssertTrue(yieldedDuringRestore, "disk cache restoration must let the launch field answer")
        XCTAssertNotNil(icons.image(for: urls[0]))
        XCTAssertNotNil(icons.image(for: urls[1999]))
    }

    func testSavedTabsLaunchStages() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchWork-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tabs = (0..<2000).map { i in
            PageFixtures.liveTab(for: URL(string: "https://example.com/\(i)")!, id: "saved-\(i)")
        }
        let space = Space(id: "saved", name: "Saved", emoji: "", tint: RGB(238, 233, 226), today: tabs)
        let snapshot = BrowserProfile.Snapshot(spaces: [space], spaceID: space.id)
        try JSONEncoder().encode(snapshot).write(to: folder.appendingPathComponent("profile.json"))
        for repeatIndex in 0..<4 {
            var start = ProcessInfo.processInfo.systemUptime
            let profile = BrowserProfile(folder: folder)
            print("launch stage repeat=\(repeatIndex) profile_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
            start = ProcessInfo.processInfo.systemUptime
            let app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile)
            print("launch stage repeat=\(repeatIndex) model_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
            XCTAssertEqual(app.browser.allTabs.count, 2000)
            XCTAssertNil(app.browser.tab)
            await app.flushProfile()
        }
    }
}
