import AppKit
import Testing
@testable import Fast

@MainActor
struct TopBarDragTests {
    @Test func airIsAHandleAndThePillIsNot() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let strip = DragStrip.Strip(frame: NSRect(x: 80, y: 20, width: 300, height: 40))
        strip.tabAir = true
        root.addSubview(strip)
        // AppKit's unflipped NSView hit test excludes the bottom edge.
        // Exercise the six-point air immediately inside that boundary.
        #expect(strip.hitTest(NSPoint(x: 200, y: 20)) == nil)
        for y: CGFloat in [20.001, 25.9, 54, 59.9] {
            #expect(strip.hitTest(NSPoint(x: 200, y: y)) === strip, "tab air at y=\(y)")
        }
        for y: CGFloat in [26, 40, 53.9] {
            #expect(strip.hitTest(NSPoint(x: 200, y: y)) == nil)
        }
        #expect(strip.hitTest(NSPoint(x: 79, y: 22)) == nil)
        #expect(strip.hitTest(NSPoint(x: 380, y: 22)) == nil)
    }

    @Test func gapsUseTheSameHandleAsEmptyTitleBar() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        let gap = DragStrip.Strip(frame: NSRect(x: 200, y: 6, width: Metrics.tabGap, height: 28))
        root.addSubview(gap)
        #expect(gap.hitTest(NSPoint(x: 200 + Metrics.tabGap / 2, y: 20)) === gap)
        #expect(gap is WindowHandle)
        #expect(gap.hitTest(NSPoint(x: 199, y: 20)) == nil)
    }

    @Test func measuredDoorsLeaveButtonsAlone() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
        let strip = DragStrip.Strip(frame: root.bounds)
        strip.reserved = 350
        root.addSubview(strip)
        for doors: CGFloat in [0, 26, 70, 120] {
            strip.notch = CGRect(x: StripPress.endGap, y: 0, width: doors, height: 40)
            #expect(strip.hitTest(NSPoint(x: 351, y: 20)) === strip)
            if doors > 0 {
                #expect(strip.hitTest(NSPoint(x: 500 - StripPress.endGap - doors / 2, y: 20)) == nil)
            }
            #expect(strip.hitTest(NSPoint(x: 499, y: 20)) === strip)
        }
        #expect(StripPress.endGap >= 12)
    }

    @Test func firstMovementChoosesWindowOrTab() {
        #expect(!StripPress.verticalTab(0, 4.9))
        #expect(StripPress.verticalTab(0, 5))
        #expect(StripPress.verticalTab(2, -5))
        #expect(!StripPress.verticalTab(5, 5))
        #expect(!StripPress.verticalTab(-10, 6))
    }
}
