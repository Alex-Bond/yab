import AppKit
import Testing
@testable import Fast

struct FloatEdgeTabTests {
    @Test func tabFacesInwardOnEitherSide() {
        let bounds = NSRect(x: 0, y: 0, width: 440, height: 247)
        let right = FloatEdgeTab.tabFrame(in: bounds, side: .right)
        let left = FloatEdgeTab.tabFrame(in: bounds, side: .left)

        #expect(right == NSRect(x: 0, y: 75.5, width: 34, height: 96))
        #expect(left == NSRect(x: 406, y: 75.5, width: 34, height: 96))
        #expect(left.midY == right.midY)
        #expect(left.maxX == bounds.maxX)
        #expect(right.minX == bounds.minX)
    }

    @Test func tabUsesActualBoundsOrigin() {
        let bounds = NSRect(x: 40, y: 20, width: 400, height: 240)
        #expect(FloatEdgeTab.tabFrame(in: bounds, side: .right)
            == NSRect(x: 40, y: 92, width: 34, height: 96))
        #expect(FloatEdgeTab.tabFrame(in: bounds, side: .left)
            == NSRect(x: 406, y: 92, width: 34, height: 96))
    }

    @Test func smallWindowStillContainsTheEntireTab() {
        let bounds = NSRect(x: 10, y: 20, width: 18, height: 40)
        for side in [FloatPark.Side.left, .right] {
            #expect(FloatEdgeTab.tabFrame(in: bounds, side: side) == bounds)
        }
    }

    @Test func requestedWidthIsClampedBeforePlacingTheTab() {
        let bounds = NSRect(x: 10, y: 20, width: 440, height: 247)
        let hidden = FloatEdgeTab.tabFrame(in: bounds, side: .left, width: -8)
        #expect(hidden.width == 0)
        #expect(hidden.minX == bounds.maxX)

        let full = FloatEdgeTab.tabFrame(in: bounds, side: .right, width: 800)
        #expect(full.width == bounds.width)
        #expect(full.minX == bounds.minX)
    }

    @Test func stripAndTabAreOneShape() {
        let bounds = NSRect(x: 0, y: 0, width: 529, height: 301)
        for side in [FloatPark.Side.right, .left] {
            let tab = FloatEdgeTab.tabFrame(in: bounds, side: side)
            var body = bounds
            body.size.width -= FloatEdgeTab.visible
            if side == .right { body.origin.x += FloatEdgeTab.visible }
            let shape = FloatEdgeTab.outline(body: body, tab: tab, side: side, in: bounds, corner: Floater.corner)
            // One outline round both, no seam: its box is theirs together.
            let box = shape.boundingBoxOfPath, both = body.union(tab)
            #expect(abs(box.minX - both.minX) < 0.01 && abs(box.maxX - both.maxX) < 0.01)
            #expect(abs(box.minY - both.minY) < 0.01 && abs(box.maxY - both.maxY) < 0.01)
            let out = side == .right ? tab.minX + 3 : tab.maxX - 3
            #expect(shape.contains(CGPoint(x: out, y: tab.midY)))
            // Above the tab, outside the strip, is outside.
            #expect(!shape.contains(CGPoint(x: out, y: tab.maxY + 6)))
            // The inward curve where they meet fills the corner's root.
            let root = side == .right ? body.minX - 0.3 : body.maxX + 0.3
            #expect(shape.contains(CGPoint(x: root, y: tab.maxY + 0.3)))
        }
    }

    /// A floating video or call has the browser window's corners (#239).
    @Test func floatingWindowHasTheBrowserWindowsCorners() {
        #expect(Floater.corner == Radius.window)
    }

    @MainActor @Test func accessibilityDescribesARestoreButton() {
        let tab = FloatEdgeTab(frame: NSRect(x: 0, y: 0, width: 28, height: 82))
        #expect(tab.isAccessibilityElement())
        #expect(tab.accessibilityRole() == .button)
        #expect(tab.accessibilityLabel() == "Restore video")
    }

    @MainActor @Test func accessiblePressRestoresWithoutTakingMouseGestures() {
        let tab = FloatEdgeTab(frame: NSRect(x: 0, y: 0, width: 28, height: 82))
        var restored = 0
        tab.onRestore = { restored += 1 }

        #expect(tab.hitTest(NSPoint(x: 8, y: 39)) == nil)
        #expect(tab.accessibilityPerformPress())
        #expect(restored == 1)
    }

    @MainActor @Test func invisibleTabCannotRestore() {
        let tab = FloatEdgeTab(frame: NSRect(x: 0, y: 0, width: 28, height: 82))
        var restored = 0
        tab.onRestore = { restored += 1 }

        tab.isHidden = true
        #expect(!tab.accessibilityPerformPress())
        tab.isHidden = false
        tab.alphaValue = 0
        #expect(!tab.accessibilityPerformPress())
        #expect(restored == 0)

        tab.alphaValue = 1
        #expect(tab.accessibilityPerformPress())
        #expect(restored == 1)
    }

    @MainActor @Test func hiddenParentAlsoDisablesAccessibleRestore() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 247))
        let tab = FloatEdgeTab(frame: NSRect(x: 0, y: 0, width: 28, height: 82))
        var restored = 0
        tab.onRestore = { restored += 1 }
        parent.addSubview(tab)
        parent.isHidden = true

        #expect(!tab.accessibilityPerformPress())
        #expect(restored == 0)
    }

    @MainActor @Test func accessiblePressRequiresARestoreAction() {
        let tab = FloatEdgeTab(frame: NSRect(x: 0, y: 0, width: 28, height: 82))
        #expect(!tab.accessibilityPerformPress())
    }
}
