import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

@Suite struct PictureFileTests {
    /// One pixel of lossy WebP.
    static let webp = Data(base64Encoded: "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA")!
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private func kind(_ data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType) as String?
    }

    @Test func aStillWebPBecomesAPNG() throws {
        let made = try #require(PictureFile.portable(Self.webp))
        #expect(kind(made) == UTType.png.identifier)
    }

    @Test func anythingElseStaysAsItIs() {
        #expect(PictureFile.portable(Self.png) == nil)
        #expect(PictureFile.portable(Data("not a picture".utf8)) == nil)
    }

    @Test func aDownloadedWebPIsReplacedBesideItself() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cabin.webp")
        try Self.webp.write(to: file)
        try Self.png.write(to: folder.appendingPathComponent("cabin.png"))
        let made = PictureFile.portable(file: file)
        #expect(made.lastPathComponent == "cabin 2.png")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try kind(Data(contentsOf: made)) == UTType.png.identifier)
    }

    @Test func aPNGDownloadIsLeftAlone() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Self.png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(PictureFile.portable(file: file) == file)
    }

    @Test func aCapturedPictureKeepsItsOwnPixels() throws {
        let image = try #require(Capture.pixels(of: Self.webp))
        #expect(image.width == 1 && image.height == 1)
        #expect(Capture.pixels(of: Data()) == nil)
    }
}
