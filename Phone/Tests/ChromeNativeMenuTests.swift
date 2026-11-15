import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

@MainActor
final class ChromeNativeMenuTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false

    override func setUp() { oldDisabled = Motion.disabled; Motion.disabled = true }
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil; Motion.disabled = oldDisabled
    }

    private func makeApp() throws -> AppModel {
        AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
    }

    private func host(_ app: AppModel) throws -> ChromePlusControl {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(origin: .zero, size: Metrics.screen)
        owned.rootViewController = UIViewController(); window = owned; owned.makeKeyAndVisible()
        let button = ChromePlusControl(type: .custom)
        button.frame = ChromeGeometry(size: owned.bounds.size, folded: false, hasNow: false).space
        owned.rootViewController!.view.addSubview(button)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        owned.layoutIfNeeded(); button.layoutIfNeeded()
        return button
    }

    /// A space with one tab: the right button is + as before the stack.
    private func makeLoneApp() -> AppModel {
        let tab = Tab(id: "lone", title: "Lone page", site: "Lone", icon: "globe", url: "http://127.0.0.1/lone")
        let space = Space(id: "lone", name: "Lone", emoji: "", tint: RGB(238, 233, 226), today: [tab], current: tab.id)
        return AppModel(world: World(name: "lone", space: space.id, spaces: [space], mac: World.Mac(joined: false)),
                        privateLockEnabled: { false })
    }

    /// The stack's menu holds its rows in inline groups (the separators).
    private func actions(_ menu: UIMenu?) -> [UIAction] {
        (menu?.children ?? []).flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            return actions(element as? UIMenu)
        }
    }

    private func action(_ id: String, on button: ChromePlusControl) throws -> UIAction {
        try XCTUnwrap(actions(button.menu).first(where: { $0.accessibilityIdentifier == id }))
    }

    func testTheLoneTabStandsInTheStackWithItsRealNamedActionsAndGlass() throws {
        let app = makeLoneApp(), button = try host(app)
        // One open tab stands in the stack; its hold has All Tabs with the card to close.
        let actions = self.actions(button.menu)
        XCTAssertEqual(actions.map(\.title), ["New Tab", "New Private Tab", "New Chat", "New Folder", "All Tabs · 1"])
        XCTAssertEqual(actions.map(\.accessibilityIdentifier), ["chrome.menu.newtab", "chrome.menu.newprivate", "chrome.menu.newchat", "chrome.menu.newfolder", "chrome.menu.alltabs"])
        XCTAssertTrue(actions.allSatisfy { $0.image != nil })
        XCTAssertFalse(button.showsMenuAsPrimaryAction)
        XCTAssertTrue(button.isContextMenuInteractionEnabled)
        XCTAssertNotNil(button.contextMenuInteraction)
        XCTAssertEqual(button.accessibilityIdentifier, "chrome.plus")
        XCTAssertEqual(button.accessibilityLabel, "All Tabs")
        XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), ["Show All Tabs"])
        XCTAssertEqual(button.stackView.alpha, 1)
        XCTAssertEqual(button.imageView?.alpha, 0)
        XCTAssertEqual(button.bounds.size, CGSize(width: Metrics.Chrome.round, height: Metrics.Chrome.round))
        let glass = try XCTUnwrap(button.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        let effect = try XCTUnwrap(glass.effect as? UIGlassEffect)
        XCTAssertTrue(effect.isInteractive); XCTAssertNil(effect.tintColor)
        XCTAssertEqual(glass.bounds, button.bounds)
        XCTAssertEqual(glass.layer.cornerRadius, Metrics.Chrome.round / 2)
    }

    private func waitUntil(_ ready: () -> Bool, timeout: TimeInterval = 5) async throws -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !ready(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        return ready()
    }

    /// #724: the last private page has no previous card, but its existing
    /// All Tabs action must still reach the card's Close action.
    func testLastPrivateTabsNativeHoldOffersAllTabsAndClosesItsOnlyCard() async throws {
        let app = makeLoneApp()
        app.openPrivately(PageFixtures.search("owned last private page", id: "private-724-hold"))
        let tab = try XCTUnwrap(app.browser.tab), button = try host(app)
        let stack = TabStack.of(app)
        XCTAssertTrue(tab.isPrivate)
        XCTAssertEqual(stack.contents().count, 1)
        XCTAssertTrue(stack.contents().showsStack)
        let all = try XCTUnwrap(actions(button.menu).first { $0.accessibilityIdentifier == "chrome.menu.alltabs" },
                               "the last private tab needs its existing All Tabs action")
        XCTAssertEqual(all.title, "All Tabs · 1")
        XCTAssertEqual(button.accessibilityLabel, "All Tabs")
        XCTAssertEqual(button.stackView.alpha, 1)
        XCTAssertEqual(button.imageView?.alpha, 0)
        defer { app.pages.forget(tab.id) }
        let view = app.pages.activate(tab)
        let content = try XCTUnwrap(window?.rootViewController?.view)
        view.frame = content.bounds
        content.insertSubview(view, belowSubview: button)
        content.layoutIfNeeded()
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(10))
        let painted = try await waitUntil { app.pages.painted.contains(tab.id) && !view.isLoading }
        XCTAssertTrue(painted, app.pages.describe(tab.id))
        XCTAssertTrue(app.pages.isLive(tab.id))
        XCTAssertTrue(view.window === window)
        let store = app.pages.privateStore
        XCTAssertTrue(view.configuration.websiteDataStore === store)
        XCTAssertFalse(store.isPersistent)
        var pictured = false
        app.pages.picture(tab.id) { image in pictured = image != nil }
        let captured = try await waitUntil { pictured && app.pages.snapshots[tab.id] != nil }
        XCTAssertTrue(captured, "a real private snapshot must exist before closing it")
        _ = try XCTUnwrap(app.pages.snapshots[tab.id])
        button.sendAction(all)
        let opened = try await waitUntil { stack.gallery?.phase == .open }
        XCTAssertTrue(opened, "the native All Tabs action must open the gallery")
        XCTAssertEqual(stack.gallery?.order, [tab.id])
        XCTAssertEqual(stack.gallery.map { stack.cards(of: $0).map(\.id) }, [tab.id])
        stack.closeCard(tab.id)
        let closed = try await waitUntil {
            app.browser.tab(tab.id) == nil && !(app.pages.privateStore === store)
        }
        XCTAssertTrue(closed, "closing the last private card must rotate its private store")
        XCTAssertNil(app.browser.tab(tab.id))
        XCTAssertFalse(app.pages.isLive(tab.id))
        XCTAssertNil(app.pages.snapshots[tab.id])
        XCTAssertFalse(app.pages.privateStore === store)
        XCTAssertNil(stack.gallery)
        XCTAssertTrue(app.browser.spaces.filter(\.isPrivate).allSatisfy { $0.allTabs.isEmpty })
        XCTAssertEqual(app.browser.spaceID, "lone")
        XCTAssertEqual(app.browser.tab?.id, "lone")
    }

    func testLastPrivateTabsVoiceOverOffersAllTabsAndClosesItsOnlyCard() async throws {
        let app = makeLoneApp()
        app.openPrivately(PageFixtures.search("owned spoken private page", id: "private-724-spoken"))
        let tab = try XCTUnwrap(app.browser.tab), button = try host(app)
        let stack = TabStack.of(app), store = app.pages.privateStore
        let spoken = try XCTUnwrap(button.accessibilityCustomActions?.first { $0.name == "Show All Tabs" },
                                  "the last private tab needs its existing Show All Tabs action")
        XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), ["Show All Tabs"])
        let perform = try XCTUnwrap(spoken.actionHandler)
        XCTAssertTrue(perform(spoken))
        let opened = try await waitUntil { stack.gallery?.phase == .open }
        XCTAssertTrue(opened, "the spoken All Tabs action must open the gallery")
        XCTAssertEqual(stack.gallery?.order, [tab.id])
        XCTAssertEqual(stack.gallery.map { stack.cards(of: $0).map(\.id) }, [tab.id])
        stack.closeCard(tab.id)
        let closed = try await waitUntil {
            app.browser.tab(tab.id) == nil && !(app.pages.privateStore === store)
        }
        XCTAssertTrue(closed)
        XCTAssertNil(app.browser.tab(tab.id))
        XCTAssertFalse(app.pages.privateStore === store)
        XCTAssertNil(stack.gallery)
    }

    /// Other tabs open: the stack's own menu (prototype scene 8), its spoken
    /// name and actions, and a tap that shows All Tabs instead of New Tab.
    func testTheStackOffersNewTabsTheRecentTabsAndAllTabsAndItsTapShowsAllTabs() throws {
        let app = try makeApp(), button = try host(app)
        let groups = try XCTUnwrap(button.menu?.children.compactMap { $0 as? UIMenu })
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.options.contains(.displayInline) })
        // New Chat stays under the stack too (15b7c3a0): no other page control offers it.
        XCTAssertEqual(groups.map { actions($0).map(\.accessibilityIdentifier) }, [
            ["chrome.menu.newtab", "chrome.menu.newprivate", "chrome.menu.newchat", "chrome.menu.newfolder"],
            ["chrome.menu.tab.work-hn", "chrome.menu.tab.work-gh-pr"],
            ["chrome.menu.alltabs"],
        ])
        XCTAssertEqual(try action("chrome.menu.alltabs", on: button).title, "All Tabs · 6")
        let hn = try action("chrome.menu.tab.work-hn", on: button)
        XCTAssertEqual(hn.title, "Hacker News")
        XCTAssertEqual(hn.subtitle, "news.ycombinator.com")
        XCTAssertNotNil(hn.image)
        XCTAssertEqual(button.accessibilityIdentifier, "chrome.plus")
        XCTAssertEqual(button.accessibilityLabel, "Previous tab, Hacker News")
        XCTAssertEqual(button.accessibilityHint, "Shows all tabs")
        XCTAssertEqual(button.accessibilityCustomActions?.map(\.name), ["Switch to Previous Tab", "Show All Tabs", "New Tab"])
        XCTAssertEqual(button.stackView.alpha, 1)
        XCTAssertEqual(button.imageView?.alpha, 0)
        button.sendActions(for: .touchUpInside)
        XCTAssertNil(app.surfaces.field, "the stack's tap is All Tabs, not New Tab")
        XCTAssertEqual(TabStack.of(app).gallery?.order.last, "work-figma-onb")
        TabStack.of(app).dismissGallery()
        button.sendAction(hn)
        XCTAssertEqual(app.browser.tab?.id, "work-hn", "the menu's recent tab comes in front")
    }

    /// Voice Search and Scan QR Code follow New Chat in both forms of the
    /// menu, each only where this iPhone has it (stand-ins here: the
    /// simulator can neither listen nor scan, and test runs offer neither).
    /// Crash #49 (0.0.15): the watchdog killed Yab on its way out with the
    /// main thread rendering the menu's tab icons in ChromeNativePlus's
    /// update. A menu made again (here by a moved origin, as the chrome's
    /// fold moves +) keeps its rows' pictures instead of rendering them anew.
    func testAMenuMadeAgainReusesItsTabIconsUntilTheSiteIconChanges() throws {
        let app = try makeApp(), button = try host(app)
        let first = try XCTUnwrap(action("chrome.menu.tab.work-hn", on: button).image)
        let renders = TabIcons.renders
        var origin = button.frame
        let begun = CACurrentMediaTime()
        for step in 1...60 {
            origin.origin.x = button.frame.minX + CGFloat(step % 7)
            ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: origin,
                                  isAccessible: true, scheme: .light)
        }
        let cached = (CACurrentMediaTime() - begun) * 1000 / 60
        XCTAssertEqual(TabIcons.renders, renders, "a made-again menu renders no icon")
        XCTAssertNotNil(try action("chrome.menu.tab.work-hn", on: button).image)
        // What each remake cost before: a fresh render of both rows' icons.
        let tabs = [TabStack.of(app).contents().front, TabStack.of(app).contents().back].compactMap { $0 }
        let fresh = CACurrentMediaTime()
        for _ in 0..<10 {
            for tab in tabs {
                let renderer = ImageRenderer(content: Favicon(icon: tab.icon, host: tab.host, size: UIImage.menuGlyphSide * 20 / 24,
                                                              url: tab.navigationURL, isPrivate: tab.isPrivate))
                renderer.scale = 3
                _ = renderer.uiImage
            }
        }
        let uncached = (CACurrentMediaTime() - fresh) * 1000 / 10
        NSLog("TabIcons remake: cached %.2f ms a menu, icons rendered anew %.2f ms", cached, uncached)
        let note = XCTAttachment(string: String(format: "remake with cache %.2f ms, fresh icons %.2f ms", cached, uncached))
        note.lifetime = .keepAlways; add(note)
        _ = first
    }

    func testVoiceSearchAndScanFollowNewChatInBothMenus() async throws {
        let lone = makeLoneApp()
        lone.voice.useStandIn("lisbon weather october")
        lone.scanner.useStandIn("https://example.com/menu", waits: true)
        let plus = try host(lone)
        let rows = actions(plus.menu).filter { $0.accessibilityIdentifier != "chrome.menu.alltabs" }
        XCTAssertEqual(rows.map(\.accessibilityIdentifier), ["chrome.menu.newtab", "chrome.menu.newprivate", "chrome.menu.newchat", "chrome.menu.newfolder",
                                                            "chrome.menu.voice", "chrome.menu.scan"])
        XCTAssertEqual(rows.suffix(2).map(\.title), ["Voice Search", "Scan QR Code"])
        XCTAssertTrue(rows.allSatisfy { $0.image != nil })
        plus.sendAction(try action("chrome.menu.scan", on: plus))
        XCTAssertEqual(lone.surfaces.field, .newTab)
        XCTAssertTrue(lone.scanner.shown, "New Tab's field under the camera")
        tearDownWindow()

        let app = try makeApp()
        app.voice.useStandIn("lisbon weather october")
        app.scanner.useStandIn("https://example.com/menu", waits: true)
        let stack = try host(app)
        let groups = try XCTUnwrap(stack.menu?.children.compactMap { $0 as? UIMenu })
        XCTAssertEqual(groups.first.map { actions($0).map(\.accessibilityIdentifier) },
                       ["chrome.menu.newtab", "chrome.menu.newprivate", "chrome.menu.newchat", "chrome.menu.newfolder", "chrome.menu.voice", "chrome.menu.scan"])
        stack.sendAction(try action("chrome.menu.voice", on: stack))
        XCTAssertEqual(app.surfaces.field, .newTab)
        let end = Date().addingTimeInterval(5)
        while app.voice.phase != .listening, Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(app.voice.phase, .listening, "New Tab's field, listening")
        app.voice.cancel()
    }

    func testNeitherIsOfferedWhereThisIPhoneHasNeither() throws {
        let app = try makeApp(), button = try host(app)
        let ids = actions(button.menu).map(\.accessibilityIdentifier)
        XCTAssertFalse(ids.contains("chrome.menu.voice"))
        XCTAssertFalse(ids.contains("chrome.menu.scan"))
    }

    private func tearDownWindow() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
    }

    func testTheStacksVoiceOverActionsSwitchShowAllAndOpenNewTab() throws {
        let app = try makeApp(), button = try host(app)
        func perform(_ name: String) throws -> Bool {
            let action = try XCTUnwrap(button.accessibilityCustomActions?.first { $0.name == name })
            return try XCTUnwrap(action.actionHandler)(action)
        }
        XCTAssertTrue(try perform("Show All Tabs"))
        XCTAssertNotNil(TabStack.of(app).gallery)
        TabStack.of(app).dismissGallery()
        XCTAssertTrue(try perform("New Tab"))
        XCTAssertEqual(app.surfaces.field, .newTab)
        app.surfaces.closeField()
        XCTAssertTrue(try perform("Switch to Previous Tab"))
        XCTAssertEqual(app.browser.tab?.id, "work-hn")
    }

    func testNativePrivateActionDoesNotBorrowPublicDraftOrChangeTheSelectedHistory() throws {
        let app = try makeApp()
        app.openNewTab(); app.field.typed("owned ordinary draft"); app.surfaces.closeField()
        let owner = ChromePlusOwner(app: app), before = app.browser.tab?.url
        let button = try host(app)
        button.sendAction(try action("chrome.menu.newprivate", on: button))
        XCTAssertEqual(app.field.place, .privateTab)
        XCTAssertTrue(app.field.text.isEmpty)
        XCTAssertEqual(ChromePlusOwner(app: app), owner)
        XCTAssertEqual(app.browser.tab?.url, before)
        app.surfaces.closeField(); app.openNewTab()
        XCTAssertEqual(app.field.text, "owned ordinary draft")
    }

    func testRetainedNativeActionRejectsChangedSameTabDocumentAndRetiredControl() throws {
        let app = try makeApp(), button = try host(app)
        let old = try action("chrome.menu.newprivate", on: button)
        let id = try XCTUnwrap(app.browser.tab?.id)
        var page = try XCTUnwrap(app.browser.tab)
        page.url = "http://127.0.0.1/owned-changed-source"
        app.browser.replace(id, with: page)
        button.sendAction(old)
        XCTAssertNil(app.surfaces.field)
        XCTAssertFalse(ChromeNativePlus.isCurrent(try XCTUnwrap(button.owner), app: app))
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        let fresh = try action("chrome.menu.newprivate", on: button)
        button.retire(); button.sendAction(fresh); button.sendActions(for: .touchUpInside)
        XCTAssertNil(app.surfaces.field)
        XCTAssertNil(button.menu)
        XCTAssertFalse(button.isUserInteractionEnabled)
    }

    func testFoldOrCoveredSourceReleasesTheActualNativeHitRegionAndItsMenu() throws {
        let app = try makeApp(), button = try host(app)
        let captured = try action("chrome.menu.newprivate", on: button)
        app.chrome.setFolded(true)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: false, scheme: .light)
        XCTAssertNil(button.menu)
        XCTAssertNil(button.accessibilityIdentifier)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertFalse(button.isUserInteractionEnabled)
        let point = button.convert(CGPoint(x: 25, y: 25), to: try XCTUnwrap(window))
        XCTAssertFalse(window?.hitTest(point, with: nil) === button)
        button.sendAction(captured)
        XCTAssertNil(app.surfaces.field)
        app.chrome.setFolded(false); app.surfaces.settings = true
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        XCTAssertNil(button.menu); button.sendAction(captured)
        XCTAssertNil(app.surfaces.field)
    }
    func testAnOldMenuActionCannotReviveAfterTheSameSourceLeavesAndReturns() throws {
        let app = try makeApp(), button = try host(app)
        let original = try XCTUnwrap(app.browser.tab)
        let stale = try action("chrome.menu.newprivate", on: button)
        let firstEpoch = try XCTUnwrap(button.menuEpoch)
        var changed = original; changed.url = "http://127.0.0.1/owned-next-document"
        app.browser.replace(original.id, with: changed)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        app.browser.replace(original.id, with: original)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        XCTAssertNotEqual(button.menuEpoch, firstEpoch)
        button.sendAction(stale)
        XCTAssertNil(app.surfaces.field, "returning to the exact old URL must not revive its retained menu action")
        let current = try action("chrome.menu.newprivate", on: button)
        let currentEpoch = try XCTUnwrap(button.menuEpoch)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        XCTAssertEqual(button.menuEpoch, currentEpoch)
        XCTAssertTrue(try action("chrome.menu.newprivate", on: button) === current, "unchanged updates must keep the native menu's actual action")
        button.sendAction(current)
        XCTAssertEqual(app.field.place, .privateTab)
    }

    func testCoverReenableAndMovedOriginRevokeOldActionsButKeepTheNextIntendedTap() throws {
        let app = try makeApp(), button = try host(app)
        let old = try action("chrome.menu.newprivate", on: button)
        app.surfaces.settings = true
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: false, scheme: .light)
        XCTAssertNil(button.menuEpoch); XCTAssertNil(button.menu)
        app.surfaces.settings = false
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: button.frame,
                              isAccessible: true, scheme: .light)
        button.sendAction(old)
        XCTAssertNil(app.surfaces.field)
        let oldOrigin = try action("chrome.menu.newprivate", on: button)
        let moved = button.frame.offsetBy(dx: 0, dy: -10)
        ChromeNativePlus.bind(button, app: app, owner: ChromePlusOwner(app: app), origin: moved,
                              isAccessible: true, scheme: .light)
        button.sendAction(oldOrigin)
        XCTAssertNil(app.surfaces.field, "a retained native action cannot use a displaced captured source origin")
        button.sendActions(for: .touchUpInside)
        // Other tabs are open: the stack's own action, All Tabs.
        XCTAssertNotNil(TabStack.of(app).gallery, "revocation must not swallow the next real control action")
    }

}
