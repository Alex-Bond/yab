import XCTest
import UIKit
import WebKit
@testable import YabPhone

@MainActor
final class BrowserWorkspaceTests: XCTestCase {
    func testUnfoldedUsesTheRegularSizeClassAndVerticalBarSelectsTheRail() {
        let workspace = BrowserWorkspace()
        workspace.windowSize = CGSize(width: 951, height: 669)
        workspace.resize(expanded: true)
        XCTAssertFalse(workspace.unfolded)
        workspace.regularWidth = true
        XCTAssertTrue(workspace.unfolded)
        workspace.legacyTabletWindow = true
        workspace.windowSize = CGSize(width: 700, height: 500)
        XCTAssertFalse(workspace.unfolded)
        workspace.legacyTabletWindow = false
        workspace.windowSize = CGSize(width: 466, height: 678)
        workspace.verticalBarLeading = true
        XCTAssertTrue(workspace.verticalControls)
        XCTAssertTrue(workspace.leadingRail)
        workspace.verticalBarLeading = false
        XCTAssertFalse(workspace.leadingRail)
        workspace.windowSize = CGSize(width: 951, height: 669)
        workspace.openBeside(current: "a", other: "b")
        workspace.verticalBarLeading = true
        XCTAssertFalse(workspace.leadingRail)
        workspace.selected("a", valid: ["a", "b"])
        workspace.verticalBarLeading = false
        XCTAssertTrue(workspace.leadingRail)
        workspace.tabletControls = true
        XCTAssertFalse(workspace.unfolded)
        XCTAssertFalse(workspace.verticalControls)
    }

    func testCompactPhoneAndNarrowTabletNeverInventACompanion() {
        let workspace = BrowserWorkspace()
        XCTAssertFalse(workspace.paired)
        for size in [CGSize(width: 402, height: 874), CGSize(width: 500, height: 900)] {
            let layout = BrowserWorkspaceLayout(size: size, regular: true, paired: false)
            XCTAssertFalse(layout.expanded)
            XCTAssertEqual(layout.pane(false).size, size)
        }
    }

    func testRegularPhoneSizedWindowsSplitOnlyInLandscape() {
        // Representative compact/regular bounds, not a simulated Duo runtime.
        let portrait = BrowserWorkspaceLayout(size: CGSize(width: 626, height: 890), regular: true, paired: true)
        let landscape = BrowserWorkspaceLayout(size: CGSize(width: 890, height: 626), regular: true, paired: true)
        let cover = BrowserWorkspaceLayout(size: CGSize(width: 678, height: 466), regular: false, paired: true)
        XCTAssertFalse(portrait.split)
        XCTAssertTrue(landscape.split)
        XCTAssertEqual(portrait.pane(true), CGRect(origin: .zero, size: portrait.size))
        XCTAssertGreaterThan(landscape.pane(true).minX, 0)
        XCTAssertFalse(cover.expanded)
        XCTAssertFalse(cover.split)
    }

    func testPairRotatesWithoutChangingSelectionOrOrder() {
        let workspace = BrowserWorkspace()
        workspace.resize(expanded: true)
        workspace.openBeside(current: "a", other: "b")
        let landscape = BrowserWorkspaceLayout(size: CGSize(width: 1366, height: 1024), regular: true, paired: true)
        let portrait = BrowserWorkspaceLayout(size: CGSize(width: 1024, height: 1366), regular: true, paired: true)
        XCTAssertTrue(landscape.split)
        XCTAssertEqual(landscape.pane(false).minY, landscape.pane(true).minY)
        XCTAssertEqual(portrait.pane(false).minX, portrait.pane(true).minX)
        XCTAssertFalse(portrait.split)
        XCTAssertEqual(portrait.pane(false), portrait.pane(true))
        XCTAssertEqual(workspace.companion, "a")
        workspace.selected("a", valid: ["a", "b"])
        XCTAssertFalse(workspace.secondFocused)
        workspace.resize(expanded: false)
        workspace.selected("a", valid: ["a", "b"])
        workspace.resize(expanded: true)
        XCTAssertEqual(workspace.first, "a")
        XCTAssertEqual(workspace.second, "b")
        XCTAssertFalse(workspace.secondFocused)
    }

    func testDifferentTabOnCoverReplacesTheRememberedSpread() {
        let workspace = BrowserWorkspace()
        workspace.resize(expanded: true)
        workspace.openBeside(current: "a", other: "b")
        workspace.resize(expanded: false)
        workspace.selected("c", valid: ["a", "b", "c"])
        workspace.resize(expanded: true)
        XCTAssertFalse(workspace.paired)
    }

    func testClosingPageOrEnteringPrivateDropsTheCompanion() {
        let workspace = BrowserWorkspace()
        workspace.resize(expanded: true)
        workspace.openBeside(current: "a", other: "b")
        workspace.selected("private", valid: ["private"])
        XCTAssertFalse(workspace.paired)
        workspace.openBeside(current: "a", other: "b")
        workspace.selected("a", valid: ["a"])
        XCTAssertFalse(workspace.paired)
    }

    func testCancelledNewTabDoesNotLeaveAPlaceholderForALaterSelection() {
        let workspace = BrowserWorkspace()
        workspace.openBeside(current: "a", other: "blank")
        workspace.newPage = "blank"
        workspace.fieldClosed()
        XCTAssertNil(workspace.newPage)
        workspace.newPage = "blank"
        workspace.openBeside(current: "a", other: "b")
        XCTAssertNil(workspace.newPage)
        XCTAssertEqual(workspace.second, "b")
    }

    func testChoosingTheOriginalTabFromOpenBesideRemovesTheEmptyTodayTab() throws {
        let oldDisabled = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = oldDisabled }
        let app = AppModel(world: try World.load(named: "mira"))
        let original = try XCTUnwrap(app.browser.tab)
        let allIDs = Set(app.browser.space.allTabs.map(\.id))
        let todayIDs = app.browser.space.today.map(\.id)
        app.workspace.resize(expanded: true)
        app.workspace.windowSize = CGSize(width: 890, height: 626)
        app.newTabBeside()
        let placeholder = try XCTUnwrap(app.workspace.newPage)
        XCTAssertTrue(app.field.shown)
        XCTAssertNotNil(app.browser.space.tab(placeholder))
        XCTAssertEqual(app.browser.space.today.count, todayIDs.count + 1)

        app.choose(WordRow(action: .tab(id: original.id), icon: .globe,
                           title: original.title, subtitle: original.site, key: .go, group: .tabs))
        app.reconcileWorkspace()
        app.workspace.fieldClosed()

        XCTAssertEqual(app.browser.tab?.id, original.id)
        XCTAssertEqual(app.browser.tab?.navigationURL, original.navigationURL)
        XCTAssertFalse(app.workspace.paired)
        XCTAssertNil(app.workspace.newPage)
        XCTAssertNil(app.browser.space.tab(placeholder))
        XCTAssertEqual(app.browser.space.today.map(\.id), todayIDs)
        XCTAssertEqual(Set(app.browser.space.allTabs.map(\.id)), allIDs)
        XCTAssertTrue(app.pages.workspaceTabs.isEmpty)
        app.reconcileWorkspace()
        XCTAssertEqual(app.browser.space.today.map(\.id), todayIDs)
    }

    func testChoosingAnotherExistingTabFromOpenBesideKeepsOnlyTheRequestedPair() throws {
        let oldDisabled = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = oldDisabled }
        let app = AppModel(world: try World.load(named: "mira"))
        let original = try XCTUnwrap(app.browser.tab)
        let other = try XCTUnwrap(app.browser.space.allTabs.first { $0.id != original.id && !$0.isPrivate && !$0.isMail })
        let allIDs = Set(app.browser.space.allTabs.map(\.id))
        let todayIDs = app.browser.space.today.map(\.id)
        app.workspace.resize(expanded: true)
        app.workspace.windowSize = CGSize(width: 890, height: 626)
        app.newTabBeside()
        let placeholder = try XCTUnwrap(app.workspace.newPage)

        app.choose(WordRow(action: .tab(id: other.id), icon: .globe,
                           title: other.title, subtitle: other.site, key: .go, group: .tabs))
        app.reconcileWorkspace()
        app.workspace.fieldClosed()

        XCTAssertEqual(app.browser.tab?.id, other.id)
        XCTAssertEqual(app.workspace.first, original.id)
        XCTAssertEqual(app.workspace.second, other.id)
        XCTAssertTrue(app.workspace.secondFocused)
        XCTAssertNil(app.browser.space.tab(placeholder))
        XCTAssertEqual(app.browser.space.today.map(\.id), todayIDs)
        XCTAssertEqual(Set(app.browser.space.allTabs.map(\.id)), allIDs)
        XCTAssertEqual(app.pages.workspaceTabs, Set([original.id, other.id]))
    }

    func testFoldedLandscapeRailStillOpensTheStack() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        let stack = TabStack.of(app)
        stack.touch("work-hn", in: app.browser.spaceID)
        stack.touch(try XCTUnwrap(app.browser.tab?.id), in: app.browser.spaceID)
        app.chrome.setFolded(true)
        app.workspace.windowSize = CGSize(width: 890, height: 626)
        XCTAssertTrue(stack.canFlick)
        app.workspace.windowSize = CGSize(width: 402, height: 874)
        XCTAssertFalse(stack.canFlick)
    }

    func testGalleryUsesTheSameOuterRailAsItsActivePane() throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.workspace.resize(expanded: true)
        app.workspace.windowSize = CGSize(width: 1366, height: 1024)
        app.workspace.openBeside(current: "work-hn", other: try XCTUnwrap(app.browser.tab?.id))
        app.workspace.selected("work-hn", valid: Set(app.browser.space.allTabs.map(\.id)))
        let stack = TabStack.of(app)
        stack.screen = CGSize(width: 682.5, height: 1024)
        XCTAssertEqual(stack.stackGeometry.circle.minX, Metrics.Edge.bar)
        let layout = TabGalleryLayout(screen: stack.screen, count: 2, verticalControls: true, leadingRail: true)
        XCTAssertEqual(layout.gear, stack.stackGeometry.circle)
        XCTAssertEqual(layout.chats.minX, Metrics.Edge.bar)
        XCTAssertLessThan(layout.chats.maxY, layout.gear.minY)
    }

    func testWideAnswerColumnStartsBelowTheSafeTopAndRidesTheKeyboard() {
        let screen = CGSize(width: 360, height: 1024)
        var geometry = SheetGeometry(screen: screen, pose: SheetPose(), origin: nil,
                                     now: SheetGeometry.nowShape(screen: screen), column: true)
        XCTAssertEqual(geometry.rest.rect.minY, Metrics.statusBar)
        XCTAssertEqual(geometry.rest.rect.maxY, screen.height)
        XCTAssertEqual(geometry.rest.rect.width, 360)
        XCTAssertTrue(geometry.opaque)
        geometry.pose.k = 300
        XCTAssertEqual(geometry.rest.rect.maxY, screen.height - 300)
    }

    func testWideToolbarKeepsThePlateReadableAndControlsOnTheEdges() {
        let size = CGSize(width: 1366, height: 1024)
        let geometry = ChromeGeometry(size: size, folded: false, hasNow: false)
        XCTAssertTrue(geometry.usesRail)
        XCTAssertEqual(geometry.plate.width, 600)
        XCTAssertLessThan(geometry.back.maxY, geometry.plate.minY)
        XCTAssertGreaterThan(geometry.space.minX, geometry.plate.maxX)
        XCTAssertEqual(ChromeGeometry(size: size, folded: true, hasNow: false).buttonOpacity, 1)
        let phone = ChromeGeometry(size: CGSize(width: 402, height: 874), folded: false, hasNow: false)
        XCTAssertEqual(phone.plate.width, 240)
        XCTAssertEqual(phone.back.minY, 798)
    }

    func testFocusingACompanionRestoresChromeInsetsEvenAtTheSameSize() {
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        let tab = Tab(id: "viewport-focus", title: "Page", site: "Page", icon: "globe", url: "about:blank")
        let page = pool.activate(tab)
        let size = CGSize(width: 600, height: 900)
        let active = PageViewport(size: size, hardware: .zero, chrome: .init(folded: false, hasNow: false, visible: true))
        pool.setViewport(active)
        PageViewport(size: size, hardware: .zero, chrome: .init(folded: false, hasNow: false, visible: false)).apply(to: page)
        XCTAssertEqual(page.obscuredContentInsets.bottom, 0)
        pool.setViewport(active, visible: page)
        XCTAssertEqual(page.obscuredContentInsets, active.current)
    }

    func testNativePagesKeepDraftScrollAndHistoryThroughNarrowAndWideLayouts() async throws {
        guard UIDevice.current.userInterfaceIdiom != .pad else {
            throw XCTSkip("Phone and Duo chrome; TabletLayoutTests covers the native iPad document hosts")
        }
        let oldDisabled = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = oldDisabled }
        let app = AppModel(world: try World.load(named: "mira"))
        let first = Tab(id: "native-first", title: "First", site: "First", icon: "globe", page: "workspace")
        let second = Tab(id: "native-second", title: "Second", site: "Second", icon: "globe", page: "workspace")
        app.browser.open(first, deduplicate: false)
        app.workspace.openBeside(current: first.id, other: second.id)
        app.browser.open(second, deduplicate: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let root = RootController(app: app)
        window.rootViewController = root
        root.traitOverrides.horizontalSizeClass = .regular
        window.makeKeyAndVisible()
        // UIKit first fits the key window to the runner's phone screen.
        // Set the test's window bounds after that fit, as for each resize.
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        root.view.frame = window.bounds
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil; previousKey?.makeKey() }
        try await until { app.workspace.expanded && app.pages.painted.contains(second.id) }
        let page = try XCTUnwrap(app.pages.liveView(second.id))
        let otherPage = try XCTUnwrap(app.pages.liveView(first.id))
        _ = app.pages.warm(first)
        let initialScroll = try await runPageScript("""
        document.querySelector('input').value='kept draft';
        history.pushState({},'', '#kept');
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        window.scrollTo(0,200);
        await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
        return scrollY;
        """, in: page)
        let initialY = try XCTUnwrap(initialScroll as? NSNumber, "WebKit must return its measured scroll position").doubleValue
        XCTAssertEqual(initialY, 200, accuracy: 5)
        // Representative Duo bounds also exercise the real root and live pages.
        for (size, regular) in [(CGSize(width: 768, height: 1024), true),
                                (CGSize(width: 626, height: 890), true),
                                (CGSize(width: 890, height: 626), true),
                                (CGSize(width: 500, height: 900), false),
                                (CGSize(width: 1024, height: 768), true)] {
            root.traitOverrides.horizontalSizeClass = regular ? .regular : .compact
            window.frame.size = size
            root.view.frame = window.bounds
            root.view.setNeedsLayout(); root.view.layoutIfNeeded()
            try await until { abs(app.workspace.paneFrame.size.width - (regular ? (size.width > size.height ? (size.width - 1) / 2 : size.width) : size.width)) < 1 }
            XCTAssertEqual(window.bounds.size, size)
            _ = try await runPageScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); return true;", in: page)
            XCTAssertTrue(page === app.pages.liveView(second.id))
            let draft = try await page.evaluateJavaScript("document.querySelector('input').value") as? String
            let hash = try await page.evaluateJavaScript("location.hash") as? String
            let scroll = try await page.evaluateJavaScript("scrollY") as? Double
            XCTAssertEqual(draft, "kept draft")
            XCTAssertEqual(hash, "#kept")
            XCTAssertEqual(scroll ?? -1, 200, accuracy: 5, "after resize to \(size), regular=\(regular), page=\(page.frame)")
            print("workspace resize: window=\(window.bounds), pane=\(app.workspace.paneFrame), page=\(page.frame), scroll=\(scroll ?? -1)")
            XCTAssertEqual(app.browser.tab?.id, second.id)
            if !regular {
                for i in 0..<4 {
                    _ = app.pages.warm(Tab(id: "workspace-neighbor-\(i)", title: "Neighbor", site: "Neighbor", icon: "globe", url: "about:blank"))
                }
                let borrowed = Tab(id: "workspace-borrowed", title: "Card", site: "Card", icon: "globe", url: "about:blank")
                _ = app.pages.borrow(borrowed)
                XCTAssertTrue(otherPage === app.pages.liveView(first.id), "the remembered companion must survive cover cache pressure")
                app.pages.giveBack(borrowed.id)
            }
        }
        app.workspace.fullSpread()
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        try await until { abs(page.frame.width - 1024) < 1 }
        print("workspace full spread: window=\(window.bounds), pane=\(app.workspace.paneFrame), page=\(page.frame)")
        app.field.openSpacesInPlace()
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        try await until(details: { "sidebar shown=\(app.field.shown), revision=\(app.field.revision), expanded=\(app.workspace.expanded), trait=\(root.traitCollection.horizontalSizeClass.rawValue), window=\(window.bounds), pane=\(app.workspace.paneFrame), host=\(String(describing: page.superview?.bounds)), page=\(page.frame)" }) {
            abs(page.frame.width - (1024 - Metrics.Workspace.sidebar)) < 1
        }
        print("workspace sidebar: shown=\(app.field.shown), pane=\(app.workspace.paneFrame), page=\(page.frame)")
        let sidebarDraft = try await page.evaluateJavaScript("document.querySelector('input').value") as? String
        XCTAssertEqual(sidebarDraft, "kept draft")
        app.field.close()
        root.view.setNeedsLayout(); root.view.layoutIfNeeded()
        try await until { abs(page.frame.width - 1024) < 1 }
    }

    private func runPageScript(_ script: String, in view: WKWebView) async throws -> Any {
        // The SDK's async Void overload can discard the returned JS value.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func until(details: () -> String = { "" }, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "native workspace did not finish laying out. " + details(), file: file, line: line)
    }
}
