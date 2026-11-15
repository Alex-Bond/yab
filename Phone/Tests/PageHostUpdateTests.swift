import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Crashes #104 and #105 (0.1.3) are watchdog kills sampled inside
/// PageHost.updateUIView: one copying a WKWebViewConfiguration while it
/// looked up the tab's space, one re-applying the viewport to the page.
/// An update that changes nothing must stay cheap.
@MainActor
final class PageHostUpdateTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?

    override func setUp() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        previousKey?.makeKey()
    }

    /// Counts how often the viewport reads the page's insets.
    private final class CountingWebView: WKWebView {
        var reads = 0
        override var obscuredContentInsets: UIEdgeInsets {
            get { reads += 1; return super.obscuredContentInsets }
            set { super.obscuredContentInsets = newValue }
        }
    }

    func testUnchangedInputsDoNotReapplyTheViewport() throws {
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = CountingWebView(frame: window.bounds, configuration: configuration)
        let host = try XCTUnwrap(window.rootViewController?.view)
        let container = PageContainer(frame: host.bounds)
        container.pool = pool
        container.fixturesEnabled = false
        let chrome = PageViewport.Chrome(folded: false, hasNow: true, visible: true)
        container.chrome = chrome
        host.addSubview(container)
        defer { container.removeFromSuperview() }
        container.show(view)
        window.layoutIfNeeded()
        let applied = view.obscuredContentInsets
        XCTAssertGreaterThan(applied.bottom, 0, "the viewport reached the page")

        // What PageHost.updateUIView assigns on an update that changes nothing.
        view.reads = 0
        for _ in 0 ..< 20 {
            container.pool = pool
            container.chrome = chrome
            container.fixturesEnabled = false
        }
        XCTAssertEqual(view.reads, 0, "unchanged inputs re-applied the viewport")

        // A real change still reaches the page.
        container.chrome = PageViewport.Chrome(folded: true, hasNow: true, visible: true)
        XCTAssertGreaterThan(view.reads, 0)
        XCTAssertNotEqual(view.obscuredContentInsets, applied)
    }

    func testALivePageIsFoundWithoutCopyingConfigurations() throws {
        let url = try XCTUnwrap(URL(string: "about:blank"))
        let plain = PageFixtures.liveTab(for: url, id: "host.plain")
        let own = PageFixtures.liveTab(for: url, id: "host.own")
        let shy = PageFixtures.liveTab(for: url, id: "host.private", isPrivate: true)
        let spaces = [
            Space(id: "s.plain", name: "Plain", emoji: "", tint: RGB(1, 2, 3), today: [plain]),
            Space(id: "s.own", name: "Own", emoji: "", tint: RGB(1, 2, 3), today: [own], ownSignIns: true),
            Space(id: "s.private", name: "Private", emoji: "", tint: RGB(1, 2, 3), today: [shy], isPrivate: true),
        ]
        let pool = WebPool(dataStore: .nonPersistent(), fixturesEnabled: false)
        pool.spaceForTab = { id in spaces.first { $0.tab(id) != nil } }
        let identity = UUID()
        pool.websiteStoreID = { space in space.ownSignIns ? identity : nil }
        defer { for tab in [plain, own, shy] { pool.forget(tab.id) } }
        for tab in [plain, own, shy] {
            let view = pool.activate(tab)
            let store = view.configuration.websiteDataStore
            let copies = pool.configurationCopies
            for _ in 0 ..< 50 {
                XCTAssertTrue(pool.activate(tab) === view, "\(tab.id) kept its page")
            }
            XCTAssertEqual(pool.configurationCopies, copies, "\(tab.id): an update copied a configuration")
            XCTAssertTrue(view.configuration.websiteDataStore === store)
        }
        // Each kind of page still has its own store.
        let stores = [plain, own, shy].map { pool.activate($0).configuration.websiteDataStore }
        XCTAssertFalse(stores[0] === stores[1])
        XCTAssertFalse(stores[0] === stores[2])
        XCTAssertFalse(stores[1] === stores[2])
        XCTAssertFalse(stores[2].isPersistent)
    }

    func testATabIsFoundAtEveryDepthOfItsSpace() {
        func tab(_ id: String) -> Tab { PageFixtures.liveTab(for: URL(string: "https://example.com/\(id)")!, id: id) }
        let inner = Folder(id: "f.inner", name: "Inner", items: [.tab(tab("deep"))])
        let outer = Folder(id: "f.outer", name: "Outer", items: [.tab(tab("shallow")), .folder(inner)])
        let space = Space(id: "s", name: "S", emoji: "", tint: RGB(1, 2, 3), pins: [tab("pin")],
                          kept: [.tab(tab("kept")), .folder(outer)], today: [tab("today")])
        for id in ["pin", "kept", "shallow", "deep", "today"] {
            XCTAssertEqual(space.tab(id)?.id, id)
            XCTAssertEqual(space.tab(id)?.id, space.allTabs.first { $0.id == id }?.id)
        }
        XCTAssertEqual(space.tab("deep")?.place, .kept)
        XCTAssertEqual(space.tab("pin")?.place, .pinned)
        XCTAssertNil(space.tab("missing"))
        XCTAssertNil(KeptTree.tab("today", in: space.kept))
    }
}
