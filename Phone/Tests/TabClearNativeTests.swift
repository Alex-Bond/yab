import UIKit
import SwiftUI
import WebKit
import XCTest
@testable import YabPhone

/// Real WK documents and a real test-owned disk profile. No external requests,
/// fake DOM/media result or fake profile flush is used.
@MainActor
final class TabClearNativeTests: XCTestCase {
    private var app: AppModel!
    private var window: UIWindow!
    private var directory: URL!
    private var previousMotion = false
    private var auto = false
    private var welcomed = false
    override func setUp() async throws {
        previousMotion = Motion.disabled; Motion.disabled = true
        auto = SettingsStore.shared.autoClearToday; SettingsStore.shared.autoClearToday = false
        welcomed = SettingsStore.shared.welcomed; SettingsStore.shared.welcomed = true
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TabClearNative-" + UUID().uuidString)
        let profile = BrowserProfile(folder: directory)
        app = AppModel(world: profile.world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        app.browser.showSpace("local.personal")
        // Only the pages each test opens: a person's Clear takes a tab with
        // no page alive as it is, and the profile's own today would count.
        for tab in app.browser.space.today { app.browser.close(tab.id) }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
    }
    override func tearDown() async throws {
        defer { Motion.disabled = previousMotion; SettingsStore.shared.autoClearToday = auto; SettingsStore.shared.welcomed = welcomed }
        if let app {
            for tab in app.browser.allTabs { app.pages.forget(tab.id) }
            await app.flushProfile()
        }
        window?.isHidden = true; window = nil; app = nil
        try? FileManager.default.removeItem(at: directory)
    }
    func testBackgroundProfileFlushIncludesPendingActivity() async throws {
        let tab = Tab(id: "background-save", title: "Save", site: "Owned", icon: "globe", url: "about:blank")
        app.browser.open(tab, deduplicate: false)
        app.tabClear.inserted(tab, in: app.browser.space)
        app.tabClear.resigned()
        await app.flushProfile()
        let restoredProfile = BrowserProfile(folder: directory)
        let restored = TabActivityProfile(profile: restoredProfile)
        XCTAssertEqual(restored.entries[tab.id]?.address, tab.url)
        XCTAssertEqual(restored.entries[tab.id]?.space, app.browser.spaceID)
        XCTAssertEqual(restored.entries[tab.id]?.localOnly, false)
    }

    @discardableResult
    private func opened(_ id: String, html: String = "<body>Plain owned document</body>", privately: Bool = false) async throws -> WKWebView {
        let tab = Tab(id: id, title: id, site: "Owned", icon: "globe", url: "about:blank", isPrivate: privately)
        app.browser.open(tab, deduplicate: false)
        let view = app.pages.activate(try XCTUnwrap(app.browser.tab(id)))
        view.frame = window.rootViewController!.view.bounds
        window.rootViewController!.view.addSubview(view)
        view.loadHTMLString(html, baseURL: nil)
        await app.pages.waitUntilPainted(id, timeout: .seconds(10))
        XCTAssertTrue(app.pages.painted.contains(id), app.pages.describe(id))
        return view
    }
    private func script(_ js: String, in view: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Any, Error>) in
            view.evaluateJavaScript(js) { result, error in
                if let error { reply.resume(throwing: error) }
                else { reply.resume(returning: result ?? NSNull()) }
            }
        }
    }
    func testClearReleasesOnlySafeLiveLocalPageAndUndoRestoresOriginalOrderAndNavigation() async throws {
        _ = try await opened("safe")
        let dirty = try await opened("form", html: "<body><input id='draft' value='before'></body>")
        _ = try await script("document.getElementById('draft').value='unfinished'", in: dirty)
        _ = try await opened("current")
        let before = app.browser.space.today.map(\.id)
        let navigation = app.pages.navigationState(for: "safe")
        let count = await app.tabClear.clear()
        XCTAssertEqual(count, 1)
        XCTAssertNil(app.browser.tab("safe")); XCTAssertFalse(app.pages.isLive("safe"))
        XCTAssertNotNil(app.browser.tab("form")); XCTAssertEqual(app.browser.tab?.id, "current")
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        XCTAssertEqual(receipt.count, 1)
        await app.tabClear.undo(receipt.id)
        XCTAssertEqual(app.browser.space.today.map(\.id), before)
        XCTAssertEqual(app.pages.navigationState(for: "safe"), navigation)
        XCTAssertEqual(app.browser.tab?.id, "current")
    }
    /// Clear stands in the spaces since the column went (aaf8443d), and the
    /// spaces are New Tab's field: a person's Clear there clears, while the
    /// address field (a draft over the page) still holds it back.
    func testClearFromTheSpacesClearsButTheAddressFieldHoldsItBack() async throws {
        _ = try await opened("safe")
        _ = try await opened("current")
        app.surfaces.openField(.address)
        XCTAssertEqual(app.field.mode, .address)
        let held = await app.tabClear.clear(in: "local.personal")
        XCTAssertEqual(held, 0, "the address field is up over the page")
        XCTAssertNotNil(app.browser.tab("safe"))
        app.surfaces.openField(.newTab)
        XCTAssertTrue(app.field.shown); XCTAssertEqual(app.field.mode, .newTab)
        let cleared = await app.tabClear.clear(in: "local.personal")
        XCTAssertEqual(cleared, 1, "Clear in the spaces clears")
        XCTAssertNil(app.browser.tab("safe")); XCTAssertEqual(app.browser.tab?.id, "current")
        app.surfaces.closeField()
    }
    /// Clear stands on each space's page: pressed on one that isn't in
    /// front, it clears that one.
    func testClearOnAnotherSpacesPageClearsThatSpace() async throws {
        _ = try await opened("asleep")
        _ = try await opened("current")
        app.pages.forget("asleep")
        let owner = app.browser.spaceID
        let other = app.browser.createSpace(name: "Other", emoji: "", look: SpaceLook(color: RGB(200, 200, 200)))
        app.browser.showSpace(other)
        XCTAssertNotEqual(app.browser.spaceID, owner)
        // The switch's own bookkeeping (selectionChanged) runs a turn later.
        try await Task.sleep(for: .milliseconds(200))
        app.surfaces.openField(.newTab)
        let cleared = await app.tabClear.clear(in: owner)
        XCTAssertEqual(cleared, 1)
        XCTAssertNil(app.browser.tab("asleep")); XCTAssertNotNil(app.browser.tab("current"))
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        await app.tabClear.undo(receipt.id)
        XCTAssertNotNil(app.browser.tab("asleep"), "Undo brings it back on its own space")
        app.surfaces.closeField()
    }
    #if DEBUG
    private func blockTheOwnedProfileWriter() throws {
        // A real regular file at the directory path makes createDirectory fail.
        // It is the test's own temporary profile, not a fake flush result.
        try FileManager.default.removeItem(at: directory)
        try Data("Owned write failure".utf8).write(to: directory)
    }

    func testFailedActualProfileWriteRollsBackOnlyTheOwnedBatchAndItsNavigation() async throws {
        _ = try await opened("safe", html: "<title>Old document</title><body>Old document</body>")
        _ = try await opened("current")
        await app.flushProfile()
        let before = app.browser.space
        let navigation = try XCTUnwrap(app.pages.navigationState(for: "safe"))
        XCTAssertEqual(navigation.entries.last?.title, "Old document")
        app.tabClear.beforePublicFlushForTests = { [weak self] in
            guard let self else { return }
            do { try self.blockTheOwnedProfileWriter() }
            catch { XCTFail("owned write failure setup failed: \(error)") }
        }
        defer { app.tabClear.beforePublicFlushForTests = nil }
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 0)
        XCTAssertNotNil(app.profile?.lastWriteError, "the actual profile writer must fail")
        XCTAssertEqual(app.browser.space, before)
        XCTAssertEqual(app.profile?.navigation["safe"], navigation,
                       "the checked rollback must restore portable history before publication")
        XCTAssertEqual(app.pages.navigationState(for: "safe"), navigation)
        XCTAssertNil(app.tabClear.visibleReceipt)
        XCTAssertEqual(app.tabClear.message, "Couldn’t save Clear · tabs were kept")
    }

    func testFailedWriteCannotPutOldNavigationIntoAReusedIDAfterTheOwnerChanged() async throws {
        _ = try await opened("safe", html: "<title>Old document</title><body>Old document</body>")
        _ = try await opened("current")
        await app.flushProfile()
        let original = app.browser.space
        let oldNavigation = try XCTUnwrap(app.pages.navigationState(for: "safe"))
        var replacementOwner: Space.ID?
        var replacementNavigation: BrowserNavigation?
        var replacementRecord: YabPhone.Tab?
        var replacementView: WKWebView?
        app.tabClear.beforePublicFlushForTests = { [weak self] in
            guard let self else { return }
            XCTAssertNil(self.app.browser.tab("safe"), "suspension starts after the actual checked removal")
            do {
                replacementOwner = self.app.browser.createSpace(name: "Later owner", emoji: "", look: SpaceLook(color: RGB(238, 233, 226)))
                replacementView = try await self.opened("safe", html: "<title>Replacement document</title><body>Replacement document</body>")
                replacementRecord = self.app.browser.tab("safe")
                replacementNavigation = self.app.pages.navigationState(for: "safe")
                await self.app.flushProfile()
                try self.blockTheOwnedProfileWriter()
            } catch { XCTFail("actual owner replacement/write failure setup failed: \(error)") }
        }
        defer { app.tabClear.beforePublicFlushForTests = nil }
        let cleared = await app.tabClear.clear()
        let expected = try XCTUnwrap(replacementNavigation)
        let owner = try XCTUnwrap(replacementOwner)
        let view = try XCTUnwrap(replacementView)
        XCTAssertNotEqual(expected, oldNavigation)
        XCTAssertEqual(expected.entries.last?.title, "Replacement document")
        XCTAssertEqual(cleared, 0)
        XCTAssertNotNil(app.profile?.lastWriteError, "the awaited real flush must fail")
        XCTAssertEqual(app.browser.spaceID, owner)
        XCTAssertEqual(app.browser.tab("safe"), replacementRecord)
        XCTAssertFalse(try XCTUnwrap(app.browser.space(original.id)).today.contains { $0.id == "safe" })
        // Read the profile BEFORE recapturing the live WK navigation. Otherwise
        // recapture could conceal injection of the old record's memory.
        XCTAssertEqual(app.profile?.navigation["safe"], expected)
        XCTAssertTrue(app.pages.isLive("safe"))
        let title = try await script("document.title", in: view)
        XCTAssertEqual(title as? String, "Replacement document")
        XCTAssertEqual(app.pages.navigationState(for: "safe"), expected)
        XCTAssertNil(app.tabClear.visibleReceipt)
        XCTAssertEqual(app.tabClear.message, "Couldn’t save Clear · browser changed")
    }
    #endif

    /// A person's Clear is the Mac's: a tab with no page alive goes as it
    /// is, asleep; a live page with media stays, and so does a document that
    /// changed under its proof.
    func testColdGoesMediaAndChangedDocumentRemainProtected() async throws {
        _ = try await opened("cold")
        _ = try await opened("media", html: "<body><video controls></video></body>")
        _ = try await opened("current")
        app.pages.forget("cold")
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 1)
        XCTAssertNil(app.browser.tab("cold")); XCTAssertNotNil(app.browser.tab("media"))
        let view = try await opened("probe")
        _ = try await opened("current2")
        let probeTab = try XCTUnwrap(app.browser.tab("probe"))
        let observed = await app.pages.clearProof(for: probeTab)
        let probe = try XCTUnwrap(observed)
        view.loadHTMLString("<body>Different document</body>", baseURL: nil)
        XCTAssertFalse(app.pages.acceptsClearProof(probe), "same URL cannot reuse a retired document proof")
    }
    func testClientWorldFindsRealDirtyInputEvenWhenThePageReplacesItsQueryGlobals() async throws {
        let dirty = try await opened("overridden.form", html: "<body><input id='draft' value='before'></body>")
        _ = try await script("""
          document.getElementById('draft').value='unsent actual input';
          document.querySelector = () => null;
          document.querySelectorAll = () => [];
          true;
        """, in: dirty)
        let pageWorldLie = try await script(PageClearSafety.script, in: dirty)
        XCTAssertEqual(pageWorldLie as? Bool, true, "this real page defeats the old page-world inspection")
        _ = try await opened("current")
        let inspected = await PageClearSafety.inspect(dirty)
        XCTAssertFalse(inspected, "client DOM wrappers still see the actual changed value")
        let protectedTab = try XCTUnwrap(app.browser.tab("overridden.form"))
        let proof = await app.pages.clearProof(for: protectedTab)
        XCTAssertNil(proof)
        let removed = await app.tabClear.clear()
        XCTAssertEqual(removed, 0)
        XCTAssertNotNil(app.browser.tab("overridden.form"))
    }

    func testActualNativePresentationProtectsPagesDuringSystemHandoff() async throws {
        _ = try await opened("safe")
        _ = try await opened("current")
        let alert = UIAlertController(title: "Owned native handoff", message: "Cleanup waits", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        window.rootViewController?.present(alert, animated: false)
        XCTAssertTrue(window.rootViewController?.presentedViewController === alert)
        let safe = try XCTUnwrap(app.browser.tab("safe"))
        let refused = await app.pages.clearProof(for: safe)
        XCTAssertNil(refused)
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 0)
        XCTAssertNotNil(app.browser.tab("safe"))
        await withCheckedContinuation { (reply: CheckedContinuation<Void, Never>) in
            alert.dismiss(animated: false) { reply.resume() }
        }
    }

    func testUndoExpiresAndRefusesOwnerChangesWithoutOverwritingNewTab() async throws {
        _ = try await opened("safe")
        _ = try await opened("current")
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 1)
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        app.browser.open(Tab(id: "new", title: "New", site: "Owned", icon: "globe", url: "about:blank"), deduplicate: false)
        await app.tabClear.undo(receipt.id)
        XCTAssertNil(app.browser.tab("safe")); XCTAssertEqual(app.browser.tab?.id, "new")
    }
    func testSixSecondExpiryDoesNotRestoreOrReorderAnything() async throws {
        _ = try await opened("safe")
        _ = try await opened("current")
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 1)
        let waiting = try XCTUnwrap(app.tabClear.visibleReceipt)
        app.tabClear.seen(waiting.id)
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        XCTAssertFalse(receipt.waiting)
        let before = app.browser.space
        let future = TabClearPolicy.Clock(date: Date().addingTimeInterval(7), uptime: receipt.until + 1)
        app.tabClear.clock = { future }
        XCTAssertNil(app.tabClear.visibleReceipt)
        await app.tabClear.undo(receipt.id)
        XCTAssertEqual(app.browser.space, before)
        XCTAssertNil(app.browser.tab("safe"))
    }
    /// Clear in the spaces makes its receipt while they cover the toast:
    /// Undo's six seconds start once the toast is on screen, not under them.
    func testUndosSixSecondsStartWhenItsToastIsOnScreen() async throws {
        _ = try await opened("safe")
        _ = try await opened("current")
        let root = UIHostingController(rootView: RootView().environment(app))
        window.rootViewController = root
        root.view.frame = window.bounds; root.view.layoutIfNeeded()
        app.surfaces.openField(.newTab)
        try await Task.sleep(for: .milliseconds(200))
        let cleared = await app.tabClear.clear(in: "local.personal")
        XCTAssertEqual(cleared, 1, "Clear in the spaces clears")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(app.tabClear.receipt?.waiting, true, "under the spaces the toast isn't seen yet")
        let start = TabClearPolicy.Clock.now
        let later = TabClearPolicy.Clock(date: start.date.addingTimeInterval(30), uptime: start.uptime + 30)
        app.tabClear.clock = { later }
        XCTAssertNotNil(app.tabClear.visibleReceipt, "seconds under the spaces don't count")
        app.surfaces.closeField()
        let deadline = Date().addingTimeInterval(5)
        while app.tabClear.receipt?.waiting != false && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt, "Undo is offered once the spaces go")
        XCTAssertFalse(receipt.waiting, "its toast came on screen")
        XCTAssertEqual(receipt.until, later.uptime + TabClearCoordinator.undoWindow, accuracy: 0.001)
        let gone = TabClearPolicy.Clock(date: later.date.addingTimeInterval(7), uptime: later.uptime + 7)
        app.tabClear.clock = { gone }
        XCTAssertNil(app.tabClear.visibleReceipt, "six seconds after it was seen, Undo goes")
    }

    func testAutomaticCleanupRequiresTwelveHoursAndStopsOnRealCurrentActivity() async throws {
        // Deterministic age clock only; the WK DOM/paint/media proof remains real.
        let currentClock = TabClearPolicy.Clock(date: Date(), uptime: 100_000)
        let oldClock = TabClearPolicy.Clock(date: currentClock.date.addingTimeInterval(-43_200), uptime: currentClock.uptime - 43_200)
        app.tabClear.clock = { oldClock }
        _ = try await opened("old")
        app.tabClear.clock = { currentClock }
        _ = try await opened("recent")
        _ = try await opened("current")
        SettingsStore.shared.autoClearToday = true
        let automatic = await app.tabClear.clear(automatic: true)
        XCTAssertEqual(automatic, 1)
        XCTAssertNil(app.browser.tab("old"))
        XCTAssertNotNil(app.browser.tab("recent")); XCTAssertEqual(app.browser.tab?.id, "current")
    }
    func testNextEligibleForegroundDeadlineCreatesARealBrowserReceiptAndUndo() async throws {
        // The clock supplies age only. The deadline task, DOM/media inspection,
        // disk flush, rendered Root and restoration are actual native paths.
        let now = TabClearPolicy.Clock(date: Date(), uptime: 100_000)
        app.tabClear.clock = { .init(date: now.date.addingTimeInterval(-43_200), uptime: now.uptime - 43_200) }
        _ = try await opened("deadline.safe")
        app.tabClear.clock = { now }
        _ = try await opened("deadline.current")
        SettingsStore.shared.autoClearToday = true
        app.tabClear.becameActive()
        let deadline = Date().addingTimeInterval(5)
        while app.tabClear.visibleReceipt == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        XCTAssertEqual(receipt.count, 1)
        XCTAssertNil(app.browser.tab("deadline.safe"))
        XCTAssertEqual(app.browser.tab?.id, "deadline.current")
        let root = UIHostingController(rootView: RootView().environment(app))
        window.rootViewController = root
        root.view.frame = window.bounds; root.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let capture = XCTAttachment(image: image)
        capture.name = "Actual browser automatic receipt above the existing chrome"
        capture.lifetime = .keepAlways; add(capture)
        await app.tabClear.undo(receipt.id)
        XCTAssertNotNil(app.browser.tab("deadline.safe"))
        XCTAssertEqual(app.browser.tab?.id, "deadline.current")
    }

    func testPrivateBatchAndUndoNeverWritePrivateActivityOrTabsToDisk() async throws {
        _ = try await opened("private.secret", privately: true)
        _ = try await opened("private.current", privately: true)
        let cleared = await app.tabClear.clear()
        XCTAssertEqual(cleared, 1)
        let receipt = try XCTUnwrap(app.tabClear.visibleReceipt)
        await app.tabClear.undo(receipt.id)
        await app.flushProfile()
        XCTAssertNotNil(app.browser.tab("private.secret"))
        for file in ["profile.json", "tab-activity.json"] {
            let url = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: url.path) {
                let bytes = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(bytes.contains("private.secret")); XCTAssertFalse(bytes.contains("private.current"))
            }
        }
    }
}
