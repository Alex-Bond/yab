import QuartzCore
import XCTest
@testable import YabPhone

@MainActor
final class ManyTabsCloseTests: XCTestCase {
    private func record(_ values: [String: Double]) throws {
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "many-tabs-timings.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func app(_ count: Int) -> AppModel {
        let tabs = (0..<count).map {
            Tab(id: "tab-\($0)", title: "Page \($0)", site: "Example", icon: "globe", url: "https://example.test/\($0)")
        }
        return AppModel(world: World(name: "many-tabs", space: "s", spaces: [
            Space(id: "s", name: "Tabs", emoji: "", tint: RGB(240, 240, 240), today: tabs, current: tabs.last?.id)
        ]), privateLockEnabled: { false })
    }

    // The same card lookup runs repeatedly while every close animates. Four
    // times the tabs should not require sixteen times the main-thread work.
    func testGalleryLookupScalesLinearlyWhileTabsClose() throws {
        func sample(_ count: Int) -> Double {
            let app = app(count)
            let stack = TabStack(app: app, warmsUp: false)
            let gallery = TabStack.Gallery(space: "s", order: app.browser.space.today.reversed().map(\.id))
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = CACurrentMediaTime()
                for _ in 0..<20 { XCTAssertEqual(stack.cards(of: gallery).count, count) }
                samples.append((CACurrentMediaTime() - start) * 1000 / 20)
            }
            return samples.sorted()[1]
        }
        let small = sample(128), large = sample(512)
        print("MANY_TABS lookup_ms 128=\(small) 512=\(large) ratio=\(large / max(small, 0.001))")
        try record(["lookup_128_ms": small, "lookup_512_ms": large, "scaling_ratio": large / max(small, 0.001)])
        XCTAssertLessThan(large / max(small, 0.001), 9, "gallery lookup must not rescan every tab for every card")
    }

    func testRepeatedGalleryClosesKeepOrderAndUndo() throws {
        let disabled = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = disabled }
        let app = app(512)
        let stack = TabStack.of(app)
        stack.openGallery()
        let order = stack.cards(of: try XCTUnwrap(stack.gallery)).map(\.id)
        let start = CACurrentMediaTime()
        for n in 0..<30 { stack.closeCard("tab-\(n)") }
        let milliseconds = (CACurrentMediaTime() - start) * 1000
        print("MANY_TABS close_30_of_512_ms=\(milliseconds)")
        try record(["close_30_of_512_ms": milliseconds])
        XCTAssertEqual(app.browser.space.today.count, 482)
        let removed = Set((0..<30).map { "tab-\($0)" })
        XCTAssertEqual(stack.cards(of: try XCTUnwrap(stack.gallery)).map(\.id), order.filter { !removed.contains($0) })
        let closed = try XCTUnwrap(app.backStack.closed)
        XCTAssertTrue(app.backStack.undo(closed.id))
        XCTAssertEqual(app.browser.space.today.first?.id, "tab-29")
        XCTAssertEqual(app.browser.space.today.count, 483)
    }
}
