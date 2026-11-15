import AppKit
import Testing
@testable import Fast

struct FloatCompactParkTests {
    static let area = NSRect(x: -1440, y: 70, width: 1440, height: 800)
    static let window = NSRect(x: -600, y: 200, width: 440, height: 247)

    @Test func defaultCallLipKeepsItsSixteenPointWidth() {
        #expect(FloatPark.parked(Self.window, .right, in: Self.area)
            == NSPoint(x: -16, y: 200))
        #expect(FloatPark.parked(Self.window, .left, in: Self.area)
            == NSPoint(x: -1864, y: 200))
    }

    @Test func onlyTheTabStaysOut() {
        let bounds = NSRect(origin: .zero, size: Self.window.size)
        // 20 of the tab's 24 past the edge.
        let out = FloatEdgeTab.shown
        #expect(out == 20 && FloatEdgeTab.visible - out == 4)
        for side in [FloatPark.Side.left, .right] {
            let spot = FloatPark.parked(Self.window, side, in: Self.area, lipWidth: out)
            let shown = NSRect(origin: spot, size: Self.window.size).intersection(Self.area)
            #expect(shown.width == out)
            // The tab's outer side is the outermost thing out.
            let tab = FloatEdgeTab.tabFrame(in: bounds, side: side).offsetBy(dx: spot.x, dy: spot.y)
            if side == .right { #expect(tab.minX == Self.area.maxX - out) }
            else { #expect(tab.maxX == Self.area.minX + out) }
        }
    }

    @Test func compactParkingRetainsVerticalScreenClamping() {
        var window = Self.window
        window.origin.y = -100
        for side in [FloatPark.Side.left, .right] {
            #expect(FloatPark.parked(window, side, in: Self.area, lipWidth: 28).y
                == Self.area.minY)
        }
        window.origin.y = 900
        for side in [FloatPark.Side.left, .right] {
            #expect(FloatPark.parked(window, side, in: Self.area, lipWidth: 28).y
                == Self.area.maxY - window.height)
        }
    }
}
