import AppKit
import Testing
import ImageIO
import YabCoreClient
@testable import Fast

@Suite @MainActor
struct NowPlayingArtworkTests {
    @Test func rendererChoosesLargestArtwork() {
        let rows: [JSONValue] = [96, 512, 1280, 256].map { side in
            .object(["src": .string("https://example.test/\(side).png"), "sizes": .string("\(side)x\(side)")])
        }
        let report = ChromiumMediaReport(["session": .object(["artwork": .array(rows)])])
        #expect(report.session?.artwork.first?.lastPathComponent == "1280.png")
    }
}

extension NowPlayingArtworkTests {
    @Test func nativeAndRendererSizeFormatsAgree() {
        let rows: [JSONValue] = [
            .object(["src": .string("small"), "sizes": .array([.object(["width": .number(96), "height": .number(96)])])]),
            .object(["src": .string("large"), "sizes": .array([.object(["width": .number(1280), "height": .number(720)])])]),
            .object(["src": .string("medium"), "sizes": .string("96x96 512x512")]),
        ]
        #expect(NowPlayingArtwork.ranked(rows).map { $0["src"].string } == ["large", "medium", "small"])
    }

    @Test func unknownAndInvalidSizesKeepStableOrder() {
        let rows: [JSONValue] = ["", "any", "-3x500", "NaNx100", "garbage"].enumerated().map {
            .object(["src": .string("\($0.offset)"), "sizes": .string($0.element)])
        }
        #expect(NowPlayingArtwork.ranked(rows) == rows)
    }

    @Test func systemArtworkRetainsSourcePixelsAndAspectRatio() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let original = try #require(NowPlayingArtwork.decode(data))
        let artwork = NowPlayingArtwork.item(original)
        #expect(artwork.bounds.size == NSSize(width: 1280, height: 720))
        let delivered = try #require(artwork.image(at: NSSize(width: 224, height: 224)))
        let rep = try #require(delivered.representations.first)
        #expect(rep.pixelsWide == 1280 && rep.pixelsHigh == 720)
        #expect(Accent.read(data)?.image.width == 112)
        #expect(NowPlayingArtwork.decode(Data("not an image".utf8)) == nil)
    }
}


extension NowPlayingArtworkTests {
    @Test func fullSizeDecodePreservesEXIFOrientation() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try #require(bitmap.bitmapData)
        pixels.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = try #require(bitmap.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try #require(NowPlayingArtwork.decode(data as Data))
        #expect(decoded.width == 720 && decoded.height == 1280)
    }
}
