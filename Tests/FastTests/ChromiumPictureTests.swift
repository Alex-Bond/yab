import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

/// A Chromium page's picture arrives as a whole window's JPEG. The tone's
/// look wants 16 points of it: decoded small, it reads as light as the
/// whole picture does (R1436).
@MainActor
struct ChromiumPictureTests {
    /// A 1440 × 900 point page at 2x: the top three quarters white, the rest black.
    private static func encodedPage() throws -> String {
        let width = 2880, height = 1800
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: height / 4, width: width, height: height * 3 / 4))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return (data as Data).base64EncodedString()
    }

    @Test func aFewPixelsOfAWholePageReadAsLightAsTheWholeOfIt() throws {
        let encoded = try Self.encodedPage()
        let page = CGSize(width: 1440, height: 900), all = CGRect(origin: .zero, size: page)
        let small = try #require(ChromiumPage.picture(encoded, page: page, rect: all, width: 16, backing: 2)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(small.width == 32 && small.height == 20)
        let whole = try #require(ChromiumPage.picture(encoded, page: page, rect: all, width: 1440, backing: 2)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(whole.width == 2880 && whole.height == 1800)
        let a = try #require(Tab.lightness(of: small)), b = try #require(Tab.lightness(of: whole))
        #expect(abs(a - b) < 0.02)
        #expect(abs(a - 0.75) < 0.03)
    }

    @Test func aPartOfThePageIsStillCutFromTheWholePicture() throws {
        let encoded = try Self.encodedPage()
        let page = CGSize(width: 1440, height: 900)
        // The bottom quarter only: black, however small it is asked for.
        let part = try #require(ChromiumPage.picture(encoded, page: page, rect: CGRect(x: 0, y: 700, width: 1440, height: 200), width: 16, backing: 2)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(try #require(Tab.lightness(of: part)) < 0.05)
    }
}
