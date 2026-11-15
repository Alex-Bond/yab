import QuartzCore
import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// An iPad with many tabs missed its launch (#546, #548, #560, #561, #533,
/// scene-create watchdog, 10 s of the main thread): the iPad's search card
/// (TabletOmnibox) made the field's rows and New Tab's content, each a walk
/// of every tab working out its address, again for every row it drew, and
/// New Tab's recent rows walked every tab once per row.
@MainActor
final class ManyTabsFieldTests: XCTestCase {
    private var window: UIWindow?
    private var folder: URL!
    private var previousMotionDisabled = false

    override func setUp() async throws {
        previousMotionDisabled = Motion.disabled
        Motion.disabled = true
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("many-tabs-field-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        Motion.disabled = previousMotionDisabled
        try? FileManager.default.removeItem(at: folder)
    }

    private func record(_ values: [String: Double]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "many-tabs-field.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A profile's app (not a fixture world) with `count` kept tabs in
    /// folders of ten, the last eight of them visited.
    private func app(tabs count: Int) -> AppModel {
        let tabs = (0..<count).map {
            Tab(id: "tab-\($0)", title: "Page \($0)", site: "Example", icon: "globe", url: "https://example.test/\($0)")
        }
        let kept: [KeptItem] = stride(from: 0, to: count, by: 10).map { start in
            .folder(Folder(id: "folder-\(start)", name: "Folder \(start)", open: true, tabs: Array(tabs[start..<min(start + 10, count)])))
        }
        let world = World(name: "many-tabs", space: "s", spaces: [
            Space(id: "s", name: "Tabs", emoji: "", tint: RGB(240, 240, 240), kept: kept),
        ])
        let profile = BrowserProfile(folder: folder.appendingPathComponent("profile-\(count)"))
        let app = AppModel(world: world, fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        for tab in tabs.suffix(8) { profile.recordVisit(tab) }
        return app
    }

    /// The iPad's search card drawn once in a window, with what it cost.
    private func draw(_ app: AppModel) -> (rows: Int, newTab: Int, ms: Double) {
        let host = UIHostingController(rootView: TabletOmnibox(geometry: TabletWorkspaceGeometry(
            size: CGSize(width: 1024, height: 768), statusBar: 0, sidebar: false, framed: false)).environment(app))
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        self.window?.isHidden = true
        self.window = window
        app.fieldRowsMade = 0
        let builtBefore = NewTabContent.builds
        let start = CACurrentMediaTime()
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        let ms = (CACurrentMediaTime() - start) * 1000
        return (app.fieldRowsMade, NewTabContent.builds - builtBefore, ms)
    }

    func testSearchCardMakesTheFieldRowsOnceForAllItsRows() throws {
        let app = app(tabs: 200)
        app.surfaces.openField(.newTab)
        app.field.typed("page 19")
        XCTAssertFalse(app.fieldRows.isEmpty, "the words find rows to draw")
        let drawn = draw(app)
        print("MANY_TABS_FIELD words rows_made=\(drawn.rows) new_tab_made=\(drawn.newTab) ms=\(drawn.ms)")
        // A drawing may run the card's body twice (the field reports its frame).
        XCTAssertLessThanOrEqual(drawn.rows, 2, "the card makes its rows once per drawing, not once per row")
        XCTAssertLessThanOrEqual(drawn.newTab, 2, "the field's rows make only Frequent, not all of New Tab")
    }

    func testSearchCardMakesNewTabOnceForItsRecentRows() throws {
        let app = app(tabs: 200)
        app.surfaces.openField(.newTab)
        XCTAssertTrue(app.field.words.isEmpty)
        let drawn = draw(app)
        print("MANY_TABS_FIELD recent rows_made=\(drawn.rows) new_tab_made=\(drawn.newTab) ms=\(drawn.ms)")
        XCTAssertFalse(NewTabContent.make(for: app).recent.isEmpty, "the visits show as recent rows")
        XCTAssertLessThanOrEqual(drawn.rows, 2)
        XCTAssertLessThanOrEqual(drawn.newTab, 2, "New Tab is made once per drawing, not once per row")
    }

    /// A recent row goes to the tab open at its address, found in one walk.
    func testRecentRowsGoToTheirOpenTabs() throws {
        let app = app(tabs: 60)
        let recent = NewTabContent.make(for: app).recent
        XCTAssertEqual(recent.count, Metrics.SearchSheet.rows)
        for item in recent {
            guard case let .go(id) = item.action else { return XCTFail("\(item.title) opens a copy of a tab already open") }
            XCTAssertEqual(app.browser.tab(id)?.title, item.title)
        }
    }

    /// What the card costs as the tabs grow: the numbers the farm keeps.
    func testSearchCardTimeWithManyTabs() throws {
        var values: [String: Double] = [:]
        for count in [500, 2000] {
            let app = app(tabs: count)
            app.surfaces.openField(.newTab)
            app.field.typed("page 19")
            let words = draw(app)
            app.field.typed("")
            let recent = draw(app)
            print("MANY_TABS_FIELD tabs=\(count) words_ms=\(words.ms) recent_ms=\(recent.ms)")
            values["words_\(count)_ms"] = words.ms
            values["recent_\(count)_ms"] = recent.ms
        }
        try record(values)
    }
}
