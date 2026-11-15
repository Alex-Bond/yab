import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

// files_read shows a picture the person pasted or attached: a browser-only
// Claude was told to open a pasted screenshot and had nothing to open it
// with (AgentBenchGiven).
@Suite struct AgentBenchGivenTests {
    static func picture(_ width: Int, _ height: Int, as kind: UTType, noisy: Bool = false) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noisy, let bytes = context.data?.assumingMemoryBound(to: UInt32.self) {
            // Noise a PNG can't shrink: a photo saved as a screen's kind.
            var seed: UInt32 = 7
            for i in 0..<(context.bytesPerRow / 4 * height) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                bytes[i] = seed | 0xFF00_0000
            }
        }
        let image = try #require(context.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("given-\(UUID().uuidString)")
            .appendingPathExtension(kind.preferredFilenameExtension ?? "png")
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, kind.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))
        return url
    }

    static func size(_ data: Data) -> [Int] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        return [props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }

    @Test func aScreenshotGoesAsAPNG() throws {
        let url = try Self.picture(640, 400, as: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        let (data, mime) = try #require(ChatAttachment.shown(url))
        #expect(mime == "image/png")
        #expect(Self.size(data) == [640, 400])
    }

    @Test func aLargePictureIsCutTo2048() throws {
        let url = try Self.picture(4000, 3000, as: .jpeg)
        defer { try? FileManager.default.removeItem(at: url) }
        let (data, mime) = try #require(ChatAttachment.shown(url))
        #expect(mime == "image/jpeg")
        #expect(Self.size(data) == [2048, 1536])
    }

    @Test func aPNGTooBigForAModelGoesAsAJPEG() throws {
        let url = try Self.picture(2048, 2048, as: .png, noisy: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let (_, mime) = try #require(ChatAttachment.shown(url))
        #expect(mime == "image/jpeg")
    }

    @Test func anAnswerWithAPicturesPathShowsIt() async throws {
        let url = try Self.picture(320, 200, as: .png)
        defer { try? FileManager.default.removeItem(at: url) }
        let got = await Bench.showing(["text": "File a.png.", "path": url.path])
        #expect(got["mime"] as? String == "image/png")
        let image = try #require(Data(base64Encoded: got["image"] as? String ?? ""))
        #expect(Self.size(image) == [320, 200])
        #expect(got["text"] as? String == "File a.png.")
    }

    @Test func otherAnswersStayAsTheyAre() async {
        let words = await Bench.showing(["text": "notes", "path": "/tmp/notes.txt"])
        #expect(!words.keys.contains("image"))
        let failed = await Bench.showing(["error": "no file", "path": "/tmp/a.png"])
        #expect(!failed.keys.contains("image"))
    }
}
