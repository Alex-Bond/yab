import XCTest
@testable import YabPhone

@MainActor
final class TabClearPolicyTests: XCTestCase {
    private let now = TabClearPolicy.Clock(date: Date(timeIntervalSince1970: 100_000), uptime: 50_000)
    private func tab(_ id: String) -> Tab { Tab(id: id, title: id, site: id, icon: "globe", url: "http://127.0.0.1/" + id) }
    private func space() -> Space { Space(id: "public", name: "Public", emoji: "", tint: RGB(240,240,240), today: [tab("front"), tab("old")], current: "front") }
    private func activity(_ tab: Tab, age: Double = 43_200, local: Bool = true) -> TabClearPolicy.Activity {
        .init(space: "public", address: tab.url,
              last: .init(date: now.date.addingTimeInterval(-age), uptime: now.uptime-age), localOnly: local)
    }
    func testEachKnownOwnerProtectsRegardlessOfAge() {
        let space = space(), old = tab("old")
        func reason(_ tab: Tab, _ space: Space, _ entry: TabClearPolicy.Activity?, draft: Bool = false, task: Bool = false) -> TabClearPolicy.Reason? {
            TabClearPolicy.protect(tab, in: space, activity: entry, now: now, automatic: true, authorityLocal: true, draft: draft, task: task)
        }
        XCTAssertEqual(reason(tab("front"), space, activity(tab("front"))), .current)
        var onMac = old; onMac.onMac = true
        XCTAssertEqual(reason(onMac, space, activity(old)), .remoteUnknown)
        var retained = old; retained.place = .kept
        XCTAssertEqual(reason(retained, space, activity(old)), .retained)
        var pinSpace = space; pinSpace.pins = [old]
        XCTAssertEqual(reason(old, pinSpace, activity(old)), .retained)
        XCTAssertEqual(reason(old, space, nil), .remoteUnknown)
        XCTAssertEqual(reason(old, space, activity(old, local: false)), .remoteUnknown)
        XCTAssertEqual(reason(old, space, activity(old), draft: true), .draft)
        XCTAssertEqual(reason(old, space, activity(old), task: true), .task)
        XCTAssertNil(reason(old, space, activity(old)))
    }
    /// A person's Clear, as the Mac's: shared or never observed is no reason
    /// to stay; the one in front, kept, pinned, the Mac's own, a draft and a
    /// task's still are.
    func testManualClearKeepsOnlyWhatTheMacKeeps() {
        let space = space(), old = tab("old")
        func reason(_ tab: Tab, _ space: Space, draft: Bool = false, task: Bool = false) -> TabClearPolicy.Reason? {
            TabClearPolicy.protectManual(tab, in: space, draft: draft, task: task)
        }
        XCTAssertNil(reason(old, space), "no activity, shared: it goes")
        XCTAssertEqual(reason(tab("front"), space), .current)
        var onMac = old; onMac.onMac = true
        XCTAssertEqual(reason(onMac, space), .remoteUnknown)
        var retained = old; retained.place = .kept
        XCTAssertEqual(reason(retained, space), .retained)
        var pinSpace = space; pinSpace.pins = [old]
        XCTAssertEqual(reason(old, pinSpace), .retained)
        XCTAssertEqual(reason(old, space, draft: true), .draft)
        XCTAssertEqual(reason(old, space, task: true), .task)
    }
    func testTwelveHoursUsesActualActivityAndTwoClocks() {
        let space = space(), old = tab("old")
        func reason(_ entry: TabClearPolicy.Activity, automatic: Bool = true) -> TabClearPolicy.Reason? {
            TabClearPolicy.protect(old, in: space, activity: entry, now: now, automatic: automatic, authorityLocal: true, draft: false, task: false)
        }
        XCTAssertEqual(reason(activity(old, age: 43_199)), .active)
        XCTAssertNil(reason(activity(old, age: 43_200)))
        XCTAssertNil(reason(activity(old, age: 1), automatic: false))
        var jumped = activity(old); jumped.last = .init(date: now.date.addingTimeInterval(-90_000), uptime: now.uptime-1)
        XCTAssertEqual(reason(jumped), .activityUnknown)
        var rebooted = activity(old); rebooted.last = .init(date: now.date.addingTimeInterval(-43_200), uptime: now.uptime+1)
        XCTAssertEqual(reason(rebooted), .activityUnknown)
        var moved = activity(old); moved.space = "different"
        XCTAssertEqual(reason(moved), .activityUnknown)
    }
    func testCheckedBatchAndUndoPreserveOrderAndRefuseLaterEdits() {
        var owner = space(); owner.today = [tab("a"), tab("front"), tab("b"), tab("c")]
        let browser = BrowserStore(world: World(name: "owned", space: owner.id, spaces: [owner]))
        XCTAssertFalse(browser.clearCheckedToday(["front", "a"], expected: owner))
        XCTAssertEqual(browser.space, owner)
        XCTAssertTrue(browser.clearCheckedToday(["a", "c"], expected: owner))
        let after = browser.space
        XCTAssertEqual(after.today.map(\.id), ["front", "b"])
        XCTAssertTrue(browser.restoreCheckedToday(owner, expected: after))
        XCTAssertEqual(browser.space, owner)
        XCTAssertTrue(browser.clearCheckedToday(["a", "c"], expected: owner))
        browser.open(tab("new"), deduplicate: false)
        XCTAssertFalse(browser.restoreCheckedToday(owner, expected: after))
        XCTAssertEqual(browser.space.today.map(\.id), ["new", "front", "b"])
    }
    func testActivityDiskExcludesPrivateAndReloadNeverInventsLocalAuthority() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ClearActivity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder), owner = space()
        let secret = Space(id: "private", name: "Private", emoji: "", tint: RGB(0,0,0), today: [tab("secret")], isPrivate: true)
        let browser = BrowserStore(world: World(name: "owned", space: owner.id, spaces: [owner, secret]))
        let ledger = TabActivityProfile(profile: profile)
        ledger.put(activity(tab("old")), for: tab("old"), space: owner)
        ledger.put(activity(tab("secret")), for: tab("secret"), space: secret)
        ledger.save(browser: browser)
        await ledger.flush()
        XCTAssertFalse(ledger.writeFailed)
        XCTAssertNil(ledger.entries["secret"])
        let bytes = try String(contentsOf: folder.appendingPathComponent("tab-activity.json"), encoding: .utf8)
        XCTAssertFalse(bytes.contains("secret"))
        profile.capture(browser); await profile.flush()
        let restored = TabActivityProfile(profile: BrowserProfile(folder: folder))
        XCTAssertEqual(restored.entries["old"]?.last, ledger.entries["old"]?.last, "real activity age survives")
        XCTAssertEqual(restored.entries["old"]?.localOnly, false, "relaunch or backup cannot certify an ID stayed local")
        XCTAssertNil(restored.entries["secret"])
        ledger.markShared(["old"])
        XCTAssertEqual(ledger.entries["old"]?.localOnly, false, "sync revokes before any public journal write")
    }
    func testActivitySaveReturnsBeforeWritingAndFlushKeepsLatestSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityAsync-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder), owner = space()
        let browser = BrowserStore(world: World(name: "owned", space: owner.id, spaces: [owner]))
        profile.capture(browser)
        await profile.flush()
        let ledger = TabActivityProfile(profile: profile)
        let file = folder.appendingPathComponent("tab-activity.json")
        for age in 1 ... 100 {
            ledger.put(activity(tab("old"), age: Double(age)), for: tab("old"), space: owner)
            ledger.save(browser: browser)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "scene callbacks must not write to disk")
        await ledger.flush()
        XCTAssertFalse(ledger.writeFailed)
        let restored = TabActivityProfile(profile: BrowserProfile(folder: folder))
        XCTAssertEqual(restored.entries["old"]?.last, activity(tab("old"), age: 100).last)
        XCTAssertEqual(restored.entries["old"]?.localOnly, false)
    }

    func testActivityFlushReportsFailureAndCanRecover() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityFailure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = BrowserProfile(folder: folder), owner = space()
        let browser = BrowserStore(world: World(name: "owned", space: owner.id, spaces: [owner]))
        let ledger = TabActivityProfile(profile: profile)
        let file = folder.appendingPathComponent("tab-activity.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        ledger.put(activity(tab("old")), for: tab("old"), space: owner)
        ledger.save(browser: browser)
        await ledger.flush()
        XCTAssertTrue(ledger.writeFailed)
        try FileManager.default.removeItem(at: file)
        await ledger.flush()
        XCTAssertFalse(ledger.writeFailed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

}
