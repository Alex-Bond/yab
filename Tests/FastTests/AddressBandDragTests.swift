import AppKit
import Testing
@testable import Fast

@MainActor
struct AddressBandDragTests {
    @Test func controlsRefuseOnlyTheirOwnBoundsAtEveryBandHeight() {
        let root = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 100))
        let handle = DragStrip.Strip(frame: CGRect(x: 30, y: 20, width: 700, height: 40))
        handle.exclusions = [CGRect(x: 6, y: 6, width: 28, height: 28),
                             CGRect(x: 640, y: 6, width: 28, height: 28)]
        root.addSubview(handle)
        for x: CGFloat in [20, 650] {
            // Top-left control coordinates are translated to AppKit's y-up.
            #expect(handle.hitTest(CGPoint(x: 30+x, y: 40)) == nil)
            #expect(handle.hitTest(CGPoint(x: 30+x, y: 22)) === handle)
            #expect(handle.hitTest(CGPoint(x: 30+x, y: 58)) === handle)
        }
        for x: CGFloat in [35, 300, 635, 680] {
            #expect(handle.hitTest(CGPoint(x: 30+x, y: 40)) === handle)
        }
    }

    @Test func movedControlsDoNotLeaveOldDeadZones() {
        let handle = DragStrip.Strip(frame: CGRect(x: 0, y: 0, width: 800, height: 40))
        handle.exclusions = [CGRect(x: 600, y: 6, width: 28, height: 28)]
        #expect(handle.hitTest(CGPoint(x: 610, y: 20)) == nil)
        handle.exclusions = [CGRect(x: 700, y: 6, width: 28, height: 28)]
        #expect(handle.hitTest(CGPoint(x: 610, y: 20)) === handle)
        #expect(handle.hitTest(CGPoint(x: 710, y: 20)) == nil)
    }
}
