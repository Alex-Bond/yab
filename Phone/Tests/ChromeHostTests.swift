import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Crash #38 (0.0.14): the watchdog killed Yab on its way out with the main
/// thread inside ChromeHostController.update, which laid the chrome's own
/// SwiftUI host out synchronously from within the outer host's update.
/// What the chrome draws must stay the chrome's own host's business: a
/// change only its contents read never brings the outer update back.
@MainActor
final class ChromeHostTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil; Motion.disabled = oldDisabled
    }

    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }

    private func frames(_ count: Int) async {
        for _ in 0..<count {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(17))
        }
    }

    private func mount() async throws -> (AppModel, ChromeHostController) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window = owned
        let host = UIHostingController(rootView: ChromeLayer().environment(app))
        host.safeAreaRegions = []
        owned.rootViewController = host
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        var chrome: ChromeHostController?
        let deadline = Date().addingTimeInterval(5)
        while chrome == nil, Date() < deadline {
            chrome = controllers(host).compactMap { $0 as? ChromeHostController }.first
            await frames(1)
        }
        let found = try XCTUnwrap(chrome, "the chrome's native host must mount")
        await frames(10)
        return (app, found)
    }

    func testStateOnlyTheChromeDrawsDoesNotUpdateTheOuterHost() async throws {
        let (app, chrome) = try await mount()
        let settled = chrome.updates
        // The tab gallery drives this every frame of its move (TabStack).
        for step in 1...20 {
            app.surfaces.chromeOpacity = 1 - Double(step) / 40
            await frames(1)
        }
        app.surfaces.chromeOpacity = 1
        await frames(3)
        XCTAssertEqual(chrome.updates, settled,
                       "the chrome's own reads must not subscribe the outer host's update (was \(settled), now \(chrome.updates))")
    }

    /// The stack of #38: update ran the chrome's graph through layoutIfNeeded
    /// from inside SwiftUI's update. Now it only marks the host for this
    /// frame's commit.
    func testUpdateLeavesTheChromeLayoutToTheFramesCommit() async throws {
        let (app, chrome) = try await mount()
        let layer = chrome.host.view.layer
        XCTAssertFalse(layer.needsLayout(), "settled")
        chrome.update(contents: AnyView(Color.clear.environment(app)), folded: app.chrome.folded,
                      reduced: false, transaction: Transaction())
        XCTAssertTrue(layer.needsLayout(), "the chrome's host must not be laid out inside SwiftUI's update")
        await frames(3)
        XCTAssertFalse(layer.needsLayout(), "the frame's commit lays it out")
    }

    /// Reduce Motion's fold is a cross-dissolve after the update; updates
    /// meanwhile join it, so the newest contents are what it fades to.
    func testReducedFoldFadesAfterTheUpdateWithTheNewestContents() async throws {
        let (app, chrome) = try await mount()
        Motion.disabled = false
        defer { Motion.disabled = true }
        let folded = !app.chrome.folded
        chrome.update(contents: AnyView(EmptyView()), folded: folded, reduced: true, transaction: Transaction())
        chrome.update(contents: AnyView(Text("newest")), folded: folded, reduced: true, transaction: Transaction())
        XCTAssertFalse(chrome.host.view.layer.needsLayout(), "nothing is applied inside the update")
        await frames(2)
        let shown = String(reflecting: chrome.host.rootView)
        XCTAssertTrue(shown.contains("Text") && !shown.contains("EmptyView"), "the fade shows the newest contents: \(shown)")
        await frames(15)
    }

    func testFoldStillReachesTheChromeHost() async throws {
        let (app, chrome) = try await mount()
        let settled = chrome.updates
        app.chrome.fold(true)
        await frames(5)
        XCTAssertGreaterThan(chrome.updates, settled, "a fold is the outer host's input and must update the chrome")
        app.chrome.fold(false)
        await frames(5)
    }
}
