import AppKit
import Testing
@testable import Fast

@MainActor
struct PageToneTests {
    @Test func aThirdOfARowCannotChooseTheBar() {
        let row = NSBitmapImageRep(cgImage: LightnessTests.picture({ x, _ in
            x < 16 ? (0.9, 0.1, 0.1) : x < 32 ? (0.1, 0.7, 0.1) : (0.1, 0.1, 0.9)
        }, width: 48, height: 3))
        #expect(Tone.settle(row) == nil)
    }

    @Test func nearbyColorsAcrossBucketBoundariesAgree() throws {
        let row = NSBitmapImageRep(cgImage: LightnessTests.picture({ x, _ in
            let v: CGFloat = x % 2 == 0 ? 0.254 : 0.260
            return (v, v, v)
        }, width: 48, height: 3))
        let color = try #require(Tone.settle(row)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0.257) < 0.015)
    }

    @Test func noMajorityAcrossRowsKeepsTheLastGoodColor() {
        let row = NSBitmapImageRep(cgImage: LightnessTests.picture({ _, y in
            y == 0 ? (0.1, 0.1, 0.1) : (0.9, 0.9, 0.9)
        }, width: 48, height: 3))
        #expect(Tone.settle(row) == nil)
    }

    @Test func oldDocumentAndOvertakenReadsCannotWrite() {
        var gate = PageToneGate()
        let first = gate.begin()
        let offered1 = gate.offer(.black, ticket: first, now: 1)
        #expect(!offered1)
        let second = gate.begin()
        let offered2 = gate.offer(.black, ticket: first, now: 2)
        #expect(!offered2)
        let offered3 = gate.offer(.black, ticket: second, now: 2)
        #expect(offered3)
        gate.invalidate()
        let offered4 = gate.offer(.black, ticket: second, now: 3)
        #expect(!offered4)
        let nextDocument = gate.begin()
        let offered5 = gate.offer(.white, ticket: nextDocument, now: 3)
        #expect(!offered5)
    }

    @Test func movingColorsMustSettleAgain() {
        var gate = PageToneGate()
        let first = gate.begin()
        let offered6 = gate.offer(.black, ticket: first, now: 1)
        #expect(!offered6)
        let white = gate.begin()
        let offered7 = gate.offer(.white, ticket: white, now: 1.2)
        #expect(!offered7)
        let still = gate.begin()
        let offered8 = gate.offer(.white, ticket: still, now: 1.25)
        #expect(!offered8)
        let offered9 = gate.offer(.white, ticket: still, now: 1.4)
        #expect(offered9)
    }

    @Test func viewportRowsAreScaledAndClamped() throws {
        let row: [String: Any] = ["href": "https://example.com/", "width": 1000.0, "height": 800.0,
            "color": [44.0, 44.0, 44.0], "regions": [["x": 0.0, "y": 2.0, "width": 1200.0, "height": 18.0]]]
        let read = try #require(PageToneReading(row, size: CGSize(width: 500, height: 400)))
        #expect(read.rect == CGRect(x: 0, y: 1, width: 500, height: 9))
        #expect(read.color != nil)
        var invalid = row
        invalid["width"] = Double.infinity
        #expect(PageToneReading(invalid, size: CGSize(width: 500, height: 400)) == nil)
    }
}
