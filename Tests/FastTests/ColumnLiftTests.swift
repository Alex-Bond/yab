import AppKit
import SwiftUI
import Testing
@testable import Fast

/// The held row's lift in the AppKit column: SwiftUI's `.shadow` on every
/// row hung a clear shadow on each of a resting row's layers (about 130 in
/// the column, worked out by the render server on every frame the rows
/// moved); the held cell's own layer casts it now, and only while held.
@MainActor
struct ColumnLiftTests {
    private func cell(_ tab: Fast.Tab, _ browser: Browser, held: Bool, animated: Bool = false) -> ColumnCell {
        let item = ColumnItem(id: tab.id.uuidString, kind: .tab(tab), indent: 0, y: 0, height: 34)
        let cell = ColumnCell(kind: .tab)
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        let context = ColumnCell.Context(browser: browser, look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0),
                                         liveID: nil)
        cell.bind(item, context, hold: ColumnCell.Hold(lifted: held), force: true)
        cell.layoutSubtreeIfNeeded()
        cell.displayIfNeeded()
        return cell
    }

    private func shadowed(_ layer: CALayer) -> Int {
        (layer.shadowOpacity > 0 ? 1 : 0) + (layer.sublayers ?? []).reduce(0) { $0 + shadowed($1) }
    }

    @Test func aRestingRowCastsNoShadowAnywhere() throws {
        let browser = Browser()
        let tab = Fast.Tab()
        let cell = cell(tab, browser, held: false)
        let layer = try #require(cell.layer)
        #expect(!cell.casting)
        #expect(shadowed(layer) == 0)
    }

    @Test func theHeldRowsOwnLayerCastsTheLift() throws {
        let browser = Browser()
        let tab = Fast.Tab()
        let cell = cell(tab, browser, held: true)
        let layer = try #require(cell.layer)
        #expect(cell.casting)
        #expect(layer.shadowOpacity == 1)
        #expect(layer.shadowRadius == 12)
        #expect(abs(layer.shadowOffset.height) == 4)
        #expect(abs((layer.shadowColor?.alpha ?? 0) - 0.14) < 0.001)
        // Only the cell's own layer: none of SwiftUI's inside it.
        #expect(shadowed(layer) == 1)
        // Let go and settled: gone again.
        let item = ColumnItem(id: tab.id.uuidString, kind: .tab(tab), indent: 0, y: 0, height: 34)
        cell.bind(item, ColumnCell.Context(browser: browser, look: ColumnPages.Look(tone: nil, scheme: .light, titleSize: 13, grain: 0), liveID: nil),
                  hold: ColumnCell.Hold(), force: false)
        #expect(!cell.casting)
        #expect(layer.shadowOpacity == 0)
    }
}
