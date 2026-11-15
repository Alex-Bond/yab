import AppKit
import Testing
@testable import Fast

// How light a page is, from a small picture of it: what picks ⌘L's field
// and the veil for a light page or a dark one.
@MainActor
struct LightnessTests {
    static func picture(_ fill: (Int, Int) -> (CGFloat, CGFloat, CGFloat), width: Int = 32, height: Int = 21) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = fill(x, y)
                context.setFillColor(red: r, green: g, blue: b, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return context.makeImage()!
    }

    @Test func whiteBlackAndGray() throws {
        #expect(try #require(Tab.lightness(of: Self.picture { _, _ in (1, 1, 1) })) > 0.99)
        #expect(try #require(Tab.lightness(of: Self.picture { _, _ in (0, 0, 0) })) < 0.01)
        let gray = try #require(Tab.lightness(of: Self.picture { _, _ in (0.5, 0.5, 0.5) }))
        #expect(abs(gray - 0.5) < 0.02)
    }

    @Test func theAverageOfAMixedPicture() throws {
        // Red x % 7 / 6 averages 0.46875 over 32 columns, green y % 5 / 4
        // 0.47619 over 21 rows, blue 0.375: 0.4625 as the eye weighs them.
        let busy = Self.picture { x, y in (CGFloat(x % 7) / 6, CGFloat(y % 5) / 4, x > 20 ? 0.9 : 0.1) }
        let light = try #require(Tab.lightness(of: busy))
        #expect(abs(light - 0.4625) < 0.005)
    }

    /// A page not drawn yet over no ground (a tab just opened to a slow
    /// site) is see-through: no lightness, not black (#408).
    static func clear(width: Int = 32, height: Int = 21, opaqueRows: Int = 0) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: opaqueRows))
        return context.makeImage()!
    }

    @Test func aSeeThroughPictureSaysNothing() throws {
        #expect(Tab.lightness(of: Self.clear()) == nil)
        // Mostly see-through: still nothing.
        #expect(Tab.lightness(of: Self.clear(opaqueRows: 6)) == nil)
        // Mostly drawn, white: white, the clear part not counted as black.
        #expect(try #require(Tab.lightness(of: Self.clear(opaqueRows: 15))) > 0.99)
    }

    @Test func aSeeThroughRowHasNoColor() throws {
        let row = NSBitmapImageRep(cgImage: Self.clear(width: 200, height: 1))
        #expect(Tone.settle(row) == nil)
        let drawn = NSBitmapImageRep(cgImage: Self.picture({ _, _ in (0.2, 0.4, 0.8) }, width: 200, height: 1))
        let color = try #require(Tone.settle(drawn))
        // The row's color, through its color space's round trip.
        #expect(abs(color.blueComponent - 0.8) < 0.06)
        #expect(color.blueComponent > color.greenComponent && color.greenComponent > color.redComponent)
    }
}
