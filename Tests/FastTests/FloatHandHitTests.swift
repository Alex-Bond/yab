import AppKit
import Testing
@testable import Fast

struct FloatHandHitTests {
    @MainActor private final class Hand: FloatHand {
        var targets: [NSView] = []
        var extra: NSView?
        override var pressable: [NSView] { targets }
        override func reach(_ point: NSPoint) -> NSView? { extra }
    }

    @MainActor private final class FlippedGroup: NSView {
        override var isFlipped: Bool { true }
    }

    /// Reparenting buttons into glass must preserve their screen targets,
    /// including a flipped group and a hand offset from its parent.
    @MainActor @Test(arguments: [false, true]) func nestedButton(flipped: Bool) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let hand = Hand(frame: NSRect(x: 20, y: 30, width: 300, height: 200))
        host.addSubview(hand)
        let frame = NSRect(x: 31, y: 24, width: 150, height: 100)
        let group = flipped ? FlippedGroup(frame: frame) : NSView(frame: frame)
        hand.addSubview(group)
        let inner = NSView(frame: NSRect(x: 9, y: 7, width: 100, height: 80))
        group.addSubview(inner)
        let button = NSButton(frame: NSRect(x: 11, y: 22, width: 38, height: 38))
        inner.addSubview(button)
        hand.targets = [button]
        hand.fade(to: 1, over: 0)

        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        #expect(hand.hitTest(button.convert(center, to: host)) === button)
        // The button's old frame coordinates are now empty window space.
        #expect(hand.hitTest(hand.convert(center, to: host)) === hand)

        button.isEnabled = false
        #expect(hand.hitTest(button.convert(center, to: host)) === hand)
        button.isEnabled = true
        group.isHidden = true
        #expect(hand.hitTest(button.convert(center, to: host)) === hand)
    }

    /// Hidden controls and controls removed from the group cannot capture
    /// a click merely because their last coordinates still match.
    @MainActor @Test func unavailableButton() {
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let button = NSButton(frame: NSRect(x: 20, y: 40, width: 30, height: 30))
        hand.addSubview(button)
        hand.targets = [button]
        hand.fade(to: 1, over: 0)
        let point = NSPoint(x: 35, y: 55)
        #expect(hand.hitTest(point) === button)
        button.isHidden = true
        #expect(hand.hitTest(point) === hand)
        button.isHidden = false
        button.removeFromSuperview()
        #expect(hand.hitTest(point) === hand)
    }

    /// An expanded seek target supplied by a subclass follows the same
    /// visibility rule, while preserving its larger target rectangle.
    @MainActor @Test func extraTargetAndResizeCorner() {
        let hand = Hand(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let control = NSButton(frame: NSRect(x: 20, y: 40, width: 30, height: 30))
        hand.addSubview(control)
        hand.extra = control
        hand.fade(to: 1, over: 0)
        #expect(hand.hitTest(NSPoint(x: 35, y: 36)) === control)
        control.isEnabled = false
        #expect(hand.hitTest(NSPoint(x: 35, y: 36)) === hand)
        control.isEnabled = true
        #expect(hand.hitTest(NSPoint(x: 295, y: 5)) === hand)
        hand.fade(to: 0, over: 0)
        #expect(hand.hitTest(NSPoint(x: 35, y: 55)) === hand)
    }
}
