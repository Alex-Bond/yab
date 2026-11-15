import AppKit
import Testing
@testable import Fast

struct LookHarmonyTests {
    @Test func smallHandleMovesAloneAndKeepsItsNewLinkToMain() {
        let primary = LookColor(lightness: 0.72, reach: 0.6, hue: 0.4)
        var harmony = LookHarmony.suggested(extras: 2)
        let before = harmony.colors(from: primary)
        let point = CGPoint(x: 0.35, y: 0.2)
        harmony.move(0, to: point, from: primary)
        let after = harmony.colors(from: primary)
        #expect(after[0].point != before[0].point)
        #expect(after[1] == before[1])
        #expect(abs(after[0].point.x - point.x) < 0.0001)
        #expect(abs(after[0].point.y - point.y) < 0.0001)
        let changedMain = LookColor(lightness: primary.lightness, reach: primary.reach, hue: primary.hue + 0.3)
        let linked = harmony.colors(from: changedMain)
        #expect(abs(LookColor.turn(linked[0].hue - after[0].hue) - 0.3) < 0.0001)
    }

    @Test func pressingSmallHandleKeepsThatHandleThroughoutDrag() {
        let primary = CGPoint(x: 180, y: 80)
        let small = CGPoint(x: 70, y: 50)
        let grab = LookGrab(at: CGPoint(x: 73, y: 52), primary: primary, following: [small])
        #expect(grab.handle == .following(0))
        #expect(grab.offset == CGSize(width: 3, height: 2))
        let point = grab.point(at: CGPoint(x: 183, y: 82), travel: CGSize(width: 224, height: 97))
        #expect(grab.handle == .following(0))
        #expect(abs(point.x - (180 - 18) / 224.0) < 0.0001)
        #expect(LookGrab.hit(primary, primary: primary, following: [primary]) == .primary)
        #expect(LookGrab.hit(CGPoint(x: 0, y: 0), primary: primary, following: [small]) == nil)
    }

    @Test func addedColorsFollowComplementaryAndTriadicRelationships() {
        let primary = LookColor(lightness: 0.72, reach: 0.6, hue: 0.4)
        let pair = LookHarmony.suggested(extras: 1).colors(from: primary)
        #expect(pair.count == 1)
        #expect(abs(LookColor.turn(pair[0].hue - primary.hue) - .pi) < 0.0001)
        let triad = LookHarmony.suggested(extras: 2).colors(from: primary)
        #expect(triad.count == 2)
        #expect(abs(LookColor.turn(triad[0].hue - primary.hue) - 2 * .pi / 3) < 0.0001)
        #expect(abs(LookColor.turn(triad[1].hue - primary.hue) - 4 * .pi / 3) < 0.0001)
        #expect(triad.allSatisfy { $0.lightness == primary.lightness && $0.reach == primary.reach })
    }

    @Test func movingMainHandleMovesFollowersAndPreservesHarmony() {
        var primary = LookColor(lightness: 0.7, reach: 0.45, hue: 0.3)
        let harmony = LookHarmony.suggested(extras: 2)
        let before = harmony.colors(from: primary)
        primary.move(to: CGPoint(x: 0.2, y: 0.3))
        let after = harmony.colors(from: primary)
        #expect(before[0].point != after[0].point && before[1].point != after[1].point)
        #expect(abs(LookColor.turn(after[0].hue - primary.hue) - 2 * .pi / 3) < 0.0001)
        #expect(after.allSatisfy { $0.reach == primary.reach })
        var returned = LookColor(lightness: primary.lightness, reach: 0, hue: 0)
        returned.move(to: primary.point)
        #expect(abs(returned.reach - primary.reach) < 0.0001)
        #expect(abs(returned.hue - primary.hue) < 0.0001)
    }

    @Test func importedPalettesKeepTheirRelativeLightnessAndChroma() throws {
        let base = LookColor(try #require(NSColor(hex: "8DB6E6")))
        let colors = ["B6A6E6", "EEA2C4", "A9D6B8"]
        let harmony = LookHarmony(primary: base, colors: colors)
        #expect(harmony.links.count == 3)
        let imported = harmony.colors(from: base)
        for (stop, hex) in zip(imported, colors) {
            let original = LookColor(try #require(NSColor(hex: hex)))
            #expect(abs(stop.hue - original.hue) < 0.0001)
            #expect(abs(stop.lightness - original.lightness) < 0.0001)
            #expect(abs(stop.reach - original.reach) < 0.0001)
        }
        let moved = LookColor(lightness: base.lightness - 0.1, reach: base.reach - 0.1, hue: base.hue + 0.5)
        let following = harmony.colors(from: moved)
        for (before, after) in zip(imported, following) {
            #expect(abs(LookColor.turn(after.hue - before.hue) - 0.5) < 0.0001)
            #expect(abs(after.lightness - before.lightness + 0.1) < 0.0001)
            #expect(abs(after.reach - before.reach + 0.1) < 0.0001)
        }
    }

    @Test func neutralAndOutOfBoundsHandlesStayFinite() {
        var primary = LookColor(lightness: 0.95, reach: 0, hue: 2)
        primary.move(to: CGPoint(x: 0.5, y: 0.5))
        #expect(primary.hue == 2 && primary.reach == 0)
        primary.move(to: CGPoint(x: 3, y: -2))
        #expect(primary.reach == 1 && primary.hue.isFinite)
        #expect(LookHarmony.suggested(extras: 2).colors(from: primary).allSatisfy {
            $0.color.hex.count == 6
        })
    }

    /// Request #464: − on a space brought from Arc took every color but
    /// the main one. Taking dot 2 of 3 leaves dots 1 and 3 as they were.
    @Test func removingTheMiddleDotLeavesTheOthersAsTheyWere() {
        let main = NSColor(hex: "E84D8A")!
        let colors = ["3D7BE0", "F5C542"]
        let harmony = LookHarmony(primary: LookColor(main), colors: colors)
        #expect(!harmony.isEven)
        let fewer = harmony.removing(0)
        let after = harmony.closingUp(after: fewer)
        #expect(after.links == fewer.links)
        let shown = harmony.colors(from: LookColor(main)).map(\.color.hex)
        #expect(after.colors(from: LookColor(main)).map(\.color.hex) == [shown[1]])
        // Nil takes the last, the first stays.
        #expect(harmony.removing(nil).colors(from: LookColor(main)).map(\.color.hex) == [shown[0]])
    }

    @Test func anEvenSetClosesUpEvenlyAsArcs() {
        let triad = LookHarmony.suggested(extras: 2)
        #expect(triad.isEven)
        let fewer = triad.removing(0)
        #expect(fewer.links.count == 1)
        #expect(triad.closingUp(after: fewer) == .suggested(extras: 1))
        #expect(LookHarmony.suggested(extras: 1).closingUp(after: LookHarmony.suggested(extras: 1).removing(nil)).links.isEmpty)
    }
}
