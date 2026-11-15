import AppKit
import Testing
@testable import Fast

struct LightsPointerProbeTests {
    @Test func outsideTheGroupNeverAsksTheWindowServer() {
        var queries = 0
        let hit = LightsPointerProbe.hit(NSPoint(x: 400, y: 300),
            bounds: NSRect(x: 0, y: 0, width: 60, height: 22), ownWindow: 7,
            topWindow: { queries += 1; return 7 })
        #expect(hit == .outsideBounds)
        #expect(queries == 0)
    }

    @Test func outsideAButtonOrItsVisiblePartNeverAsksTheWindowServer() {
        let bounds = NSRect(x: 0, y: 0, width: 14, height: 14)
        let visible = NSRect(x: 4, y: 0, width: 10, height: 14)
        for (point, expected) in [(NSPoint(x: 20, y: 7), LightsPointerProbe.Hit.outsideBounds),
                                  (NSPoint(x: 2, y: 7), .outsideVisibleRect)] {
            var queries = 0, transparentChecks = 0
            let hit = LightsPointerProbe.hit(point, bounds: bounds, visibleRect: visible, ownWindow: 7,
                topWindow: { queries += 1; return 9 },
                seeThrough: { _ in transparentChecks += 1; return true })
            #expect(hit == expected)
            #expect(queries == 0)
            #expect(transparentChecks == 0)
        }
    }

    @Test func insideStillChecksTheTopWindowExactlyOnce() {
        for top in [7, 9] {
            var queries = 0
            let hit = LightsPointerProbe.hit(NSPoint(x: 7, y: 7),
                bounds: NSRect(x: 0, y: 0, width: 14, height: 14), ownWindow: 7,
                topWindow: { queries += 1; return top })
            #expect(hit == (top == 7 ? .inside : .covered(top)))
            #expect(queries == 1)
        }
    }

    @Test func onlyTheGreenProbeMayAcceptASeeThroughWindow() {
        var queries = 0, transparentChecks = 0
        let hit = LightsPointerProbe.hit(NSPoint(x: 7, y: 7),
            bounds: NSRect(x: 0, y: 0, width: 14, height: 14), ownWindow: 7,
            topWindow: { queries += 1; return 9 },
            seeThrough: { top in transparentChecks += 1; return top == 9 })
        #expect(hit == .inside)
        #expect(queries == 1)
        #expect(transparentChecks == 1)
    }

    @Test func ownWindowDoesNotNeedASeeThroughLookup() {
        var transparentChecks = 0
        let hit = LightsPointerProbe.hit(NSPoint(x: 7, y: 7),
            bounds: NSRect(x: 0, y: 0, width: 14, height: 14), ownWindow: 7,
            topWindow: { 7 }, seeThrough: { _ in transparentChecks += 1; return false })
        #expect(hit == .inside)
        #expect(transparentChecks == 0)
    }
}
