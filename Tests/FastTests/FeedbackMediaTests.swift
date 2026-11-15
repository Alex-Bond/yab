import AVFoundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

// What goes along with feedback keeps moving: a GIF is never one JPEG
// frame, and a still picture is still made smaller as before.

@Suite(.serialized)
struct FeedbackMediaTests {
    /// Noise, which no encoder can make small, `width` by `height`.
    private static func noise(width: Int, height: Int, seed: UInt64) -> CGImage? {
        var state = seed
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
            bytes[index + 1] = UInt8(truncatingIfNeeded: state >> 32)
            bytes[index + 2] = UInt8(truncatingIfNeeded: state >> 40)
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A GIF of `frames` frames of noise, a tenth of a second each.
    private static func gif(frames: Int, width: Int, height: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("moving.gif")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0 ..< frames {
            let image = try #require(noise(width: width, height: height, seed: UInt64(frame + 1)))
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private static func frames(_ data: Data) -> Int {
        CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
    }

    @Test func aGIFThatFitsGoesAsItIsEveryFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.gif(frames: 10, width: 560, height: 360, in: folder)
        let bytes = try Data(contentsOf: url)
        // Over the size a still picture is made a JPEG at, under the site's.
        #expect(bytes.count > 1_000_000 && bytes.count < FeedbackFile.room)

        let file = try #require(FeedbackFile(url: url))
        #expect(file.type == .gif)
        #expect(file.name == "moving.gif")
        #expect(file.data == bytes)
        #expect(Self.frames(try #require(file.data)) == 10)

        let fitted = try #require(await FeedbackFile.fitting(url))
        #expect(fitted.data == bytes)
    }

    @Test func aGIFTooBigBecomesAFilmOfEveryFrame() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try Self.gif(frames: 10, width: 560, height: 360, in: folder)
        let room = 600_000
        #expect(try Data(contentsOf: url).count > room)

        let waiting = try #require(FeedbackFile(url: url, room: room))
        #expect(waiting.data == nil)
        #expect(FeedbackFile.fits(url))

        let file = try #require(await FeedbackFile.fitting(url, room: room))
        let data = try #require(file.data)
        #expect(file.type == .mpeg4Movie)
        #expect(file.name == "moving.mp4")
        #expect(data.count <= room)
        let film = folder.appendingPathComponent("film.mp4")
        try data.write(to: film)
        let asset = AVURLAsset(url: film)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1.0) < 0.05)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let frames = Double(try await track.load(.nominalFrameRate)) * duration
        #expect(frames >= 9)
    }

    @Test func aBigStillPictureIsStillAJPEG() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("still.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(Self.noise(width: 1200, height: 800, seed: 7)), nil)
        #expect(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url).count
        #expect(original > 1_000_000)
        #expect(!FeedbackMedia.moves(url))

        let file = try #require(FeedbackFile(url: url))
        #expect(file.type == .jpeg)
        #expect(file.name == "still.jpg")
        #expect(file.size < original)
        #expect(Self.frames(try #require(file.data)) == 1)
    }
}
