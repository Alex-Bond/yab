import AppKit
import Testing
@testable import Fast

/// The column's rows' asks for SwiftUI's update stop at their page and each
/// row answers its own in its layout (ColumnQuiet.keepsAsks), so the column's
/// host and the window's are not laid out for a row on every frame of a
/// scroll, and no row is left asking.
@MainActor
@Suite(.serialized)
struct ColumnQuietTests {
    /// Counts the asks that reach it from below.
    private final class Above: NSView {
        var heard = 0
        @objc(_informContainerThatSubviewsNeedUpdateConstraints)
        func subviewsAsked() {
            heard += 1
            ColumnQuiet.climb(self)
        }
    }

    private static let inform = NSSelectorFromString("_informContainerThatSubviewsNeedUpdateConstraints")

    private func world() -> (ColumnPage, Above, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: true)
        let above = Above(frame: CGRect(x: 0, y: 0, width: 300, height: 400))
        window.contentView = above
        let page = ColumnPage(browser: Browser(), space: UUID())
        page.frame = above.bounds
        above.addSubview(page)
        return (page, above, window)
    }

    @Test func anAskStopsAtThePage() {
        let was = ColumnQuiet.keepsAsks
        ColumnQuiet.keepsAsks = true
        defer { ColumnQuiet.keepsAsks = was }
        let (page, above, window) = world()
        let heard = above.heard, kept = ColumnQuiet.asksKept
        page.perform(Self.inform)
        #expect(ColumnQuiet.asksKept == kept + 1)
        #expect(above.heard == heard)
        _ = window
    }

    @Test func aRowAnswersItsOwnAsk() {
        let was = ColumnQuiet.keepsAsks
        ColumnQuiet.keepsAsks = true
        defer { ColumnQuiet.keepsAsks = was }
        let (page, _, window) = world()
        let cell = ColumnCell(kind: .tab)
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        page.addSubview(cell)
        page.layoutSubtreeIfNeeded()
        let answered = ColumnQuiet.asksAnswered
        cell.needsUpdateConstraints = true
        #expect(cell.needsLayout)
        // Its own layout, as the window's layout pass calls it.
        cell.layout()
        #expect(ColumnQuiet.asksAnswered == answered + 1)
        #expect(!cell.needsUpdateConstraints)
        _ = window
    }

    @Test func aStillHandDrawsNothing() {
        let page = ColumnPage(browser: Browser(), space: UUID())
        #expect(page.handIsStill)
    }
}
