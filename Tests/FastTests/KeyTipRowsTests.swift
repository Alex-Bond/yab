import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Crash #109 (0.38.9): a rows tip with a line that is only a tab split
/// into no parts, and `KeyTipRows.body` trapped on `row[0]`.
struct KeyTipRowsTests {
    @Test func aLineThatIsOnlyATabKeepsAnEmptyRow() {
        let rows = KeyTipView.rows("Done and close 1 tab\t⌘↩\n\t\n\t⌥⌘↩\nNo keys")
        #expect(rows.map(\.name) == ["Done and close 1 tab", "", "", "No keys"])
        #expect(rows.map(\.keys) == ["⌘↩", "", "⌥⌘↩", ""])
    }

    @Test @MainActor func aTipWithABareTabLineDrawsWithoutTrapping() {
        let host = NSHostingView(rootView: KeyTipView(title: "Done\t⌘↩\n\t", keys: nil))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.height > 0)
    }
}
