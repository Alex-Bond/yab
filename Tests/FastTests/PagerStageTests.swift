import Foundation
import SwiftUI
import Testing
@testable import Fast

/// The pins every space shares standing still over the column's row of
/// spaces as it slides (SpacePager.hold, docs/shared-pins.md): when they
/// do, and the window onto the row starting under them.
struct PagerStageTests {
    @Test func thePinsStandStillOnlyOverPagesThatShowTheSameOnes() {
        let gmail = UUID(), calendar = UUID(), own = UUID()
        let pins: [Int: [UUID]] = [0: [gmail, calendar], 1: [gmail, calendar], 2: [gmail, calendar], 3: [own], 4: []]
        #expect(SpacePager.stands(pins, home: 0, over: 0...2))
        #expect(SpacePager.stands(pins, home: 1, over: 0...2))
        // Past a space with pins of its own, or Mail's with none.
        #expect(!SpacePager.stands(pins, home: 0, over: 0...3))
        #expect(!SpacePager.stands(pins, home: 2, over: 2...3))
        #expect(!SpacePager.stands(pins, home: 3, over: 3...4))
        // A page not drawn yet: they go with the pages, as before.
        #expect(!SpacePager.stands(pins, home: 0, over: 0...5))
        // No pins on screen: nothing to stand still.
        #expect(!SpacePager.stands([0: [], 1: []], home: 0, over: 0...1))
        // Another order is another grid.
        #expect(!SpacePager.stands([0: [gmail, calendar], 1: [calendar, gmail]], home: 0, over: 0...1))
    }

    @MainActor @Test func theRowsWindowStartsUnderThePinsWhileTheyStandStill() throws {
        let band = CGRect(x: 0, y: 90, width: 228, height: 500)
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let picture = try #require(context.makeImage())
        let stage = PagerStage(band: band, picture: picture, beside: picture, scale: 2, top: 0, height: 700, rim: 1)
        stage.add(page: Color.clear, at: 1, index: 1)
        let page = try #require(stage.pages[1]?.frame)
        #expect(stage.rowWindow == band.insetBy(dx: 1, dy: 0))
        stage.hold(60)
        #expect(stage.cut == 60)
        #expect(stage.rowWindow == CGRect(x: 1, y: 150, width: 226, height: 440))
        // The pages where they were: only the window onto them moved.
        #expect(stage.pages[1]?.frame == page)
        stage.hold(0)
        #expect(stage.rowWindow == band.insetBy(dx: 1, dy: 0))
    }
}
