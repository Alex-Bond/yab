import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

@Suite(.serialized)
@MainActor
struct CapturePromiseOwnershipTests {
    private func image(_ red: Bool, width: Int = 2) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        return try solid(#require(CGColor(colorSpace: space, components: red ? [1, 0, 0, 1] : [0, 0, 1, 1])), width: width)
    }

    private func solid(_ color: CGColor, width: Int) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: width))
        return try #require(context.makeImage())
    }

    private func shot(_ name: String, red: Bool, width: Int = 2) throws -> Shot {
        Shot(image: try image(red, width: width), size: CGSize(width: 1, height: 1), name: name,
             url: URL(string: "https://\(name.lowercased()).example.test/picture"), title: "Title \(name)", source: .zero)
    }

    private func style(hidePrivate: Bool = false) -> CaptureStyle {
        var style = CaptureStyle()
        style.backdrop = .none
        style.hidePrivate = hidePrivate
        return style
    }

    private func provider(_ shot: Shot, cached: CGImage? = nil, style: CaptureStyle? = nil) -> NSFilePromiseProvider {
        CapturePromise.provider(name: "\(shot.name).png", image: cached, shot: shot,
                                style: style ?? self.style(), colors: [], wallpaper: nil)
    }

    private func withOutput(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-promise-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    /// Invoke the real delegate boundary, never a second encoder in the test.
    private func write(_ provider: NSFilePromiseProvider, to file: URL) -> Error? {
        var calls = 0
        var error: Error?
        CapturePromise.shared.filePromiseProvider(provider, writePromiseTo: file) {
            calls += 1
            error = $0
        }
        #expect(calls == 1)
        return error
    }

    private func check(_ file: URL, red: Bool, width: Int, shot: Shot) throws {
        let data = try Data(contentsOf: file)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == width && image.height == width)
        let pixel = try rgba(image)
        #expect(pixel[0] == (red ? 255 : 0))
        #expect(pixel[1] == 0)
        #expect(pixel[2] == (red ? 0 : 255))
        #expect(pixel[3] == 255)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let png = try #require(properties[kCGImagePropertyPNGDictionary] as? [CFString: Any])
        #expect(png[kCGImagePropertyPNGDescription] as? String == shot.url?.absoluteString)
        #expect(png[kCGImagePropertyPNGTitle] as? String == shot.title)
        #expect(png[kCGImagePropertyPNGSoftware] as? String == "yab")
        let dpi = try #require(properties[kCGImagePropertyDPIWidth] as? Double)
        #expect(abs(dpi - 72 * Double(shot.scale)) < 0.1)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    @Test func providersKeepTheirNamesWhenRequestedInReverse() throws {
        let a = try shot("A", red: true), b = try shot("B", red: false, width: 4)
        let first = provider(a, cached: a.image), second = provider(b, cached: b.image)
        #expect(first !== second)
        #expect(first.delegate === CapturePromise.shared && second.delegate === CapturePromise.shared)
        #expect(first.fileType == UTType.png.identifier && second.fileType == UTType.png.identifier)
        #expect(CapturePromise.shared.filePromiseProvider(second, fileNameForType: UTType.png.identifier) == "B.png")
        #expect(CapturePromise.shared.filePromiseProvider(first, fileNameForType: UTType.png.identifier) == "A.png")
    }

    @Test func delayedAndRepeatedWritesKeepEachProvidersPixelsAndProvenance() throws {
        let a = try shot("A", red: true), b = try shot("B", red: false, width: 4)
        let first = provider(a, cached: a.image), second = provider(b, cached: b.image)
        try withOutput { directory in
            for (name, owner, expected, red, width) in [("first", first, a, true, 2), ("second", second, b, false, 4), ("first-again", first, a, true, 2)] {
                let file = directory.appendingPathComponent(name + ".png")
                #expect(write(owner, to: file) == nil)
                try check(file, red: red, width: width, shot: expected)
            }
        }
    }

    @Test func cachedImageStillTakesPrecedenceOverTheShot() throws {
        let original = try shot("Cached", red: false)
        let promise = provider(original, cached: try image(true))
        try withOutput { directory in
            let file = directory.appendingPathComponent("cached.png")
            #expect(write(promise, to: file) == nil)
            try check(file, red: true, width: 2, shot: original)
        }
    }

    @Test func uncachedPromiseComposesItsOwnShotAfterAnotherProviderIsMade() throws {
        let a = try shot("A", red: true), b = try shot("B", red: false, width: 4)
        let first = provider(a)
        let second = provider(b)
        try withOutput { directory in
            let file = directory.appendingPathComponent("composed.png")
            #expect(write(first, to: file) == nil)
            try check(file, red: true, width: 2, shot: a)
            #expect(CapturePromise.shared.filePromiseProvider(second, fileNameForType: UTType.png.identifier) == "B.png")
        }
    }

    @Test func uncachedPromiseRetainsItsPrivacyMask() throws {
        var original = try shot("Masked", red: true)
        original.secrets = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        let promise = provider(original, style: style(hidePrivate: true))
        try withOutput { directory in
            let file = directory.appendingPathComponent("masked.png")
            #expect(write(promise, to: file) == nil)
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let pixel = try rgba(rendered)
            let expected = try rgba(solid(CaptureArt.hush, width: 1))
            #expect(pixel == expected)
            #expect(pixel[0] != 255 && pixel[3] == 255)
        }
    }

    @Test func foreignProviderFailsOnceWithoutCreatingAFile() throws {
        let foreign = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: CapturePromise.shared)
        #expect(CapturePromise.shared.filePromiseProvider(foreign, fileNameForType: UTType.png.identifier) == "Capture.png")
        try withOutput { directory in
            let file = directory.appendingPathComponent("foreign.png")
            let error = try #require(write(foreign, to: file)) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteUnknown.rawValue)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func unavailableCompositionFailsOnceWithoutReportingSuccess() throws {
        let pixels = try image(true)
        let empty = Shot(image: pixels, size: .zero, name: "Empty", url: nil, title: "", source: .zero)
        let promise = provider(empty)
        try withOutput { directory in
            let file = directory.appendingPathComponent("empty.png")
            let error = try #require(write(promise, to: file)) as NSError
            #expect(error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteUnknown.rawValue)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func filesystemFailureCompletesOnceWithAnError() throws {
        let original = try shot("Missing", red: true)
        let promise = provider(original, cached: original.image)
        try withOutput { directory in
            let file = directory.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("picture.png")
            #expect(write(promise, to: file) != nil)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }
}
