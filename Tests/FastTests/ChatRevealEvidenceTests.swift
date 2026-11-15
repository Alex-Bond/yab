import AppKit
import Foundation
import Testing

@MainActor @Suite(.serialized)
struct ChatRevealEvidenceTests {
    private let width = 32
    private let height = 32

    private func pixels(_ level: UInt8, detached: Bool = false) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        for y in 4..<24 {
            for x in 4..<24 {
                let i = (y * width + x) * 4
                bytes[i] = level; bytes[i + 1] = level; bytes[i + 2] = level
            }
        }
        if detached { bytes[0] = 230; bytes[1] = 30; bytes[2] = 40 }
        return bytes
    }

    private func observed(_ frames: [[UInt8]]) -> ChatRevealPixels {
        ChatRevealPixels(frames: frames, final: pixels(255), blank: pixels(0), width: width)
    }

    @Test func anAbruptResultStillFailsTheFadePredicate() {
        let abrupt = observed([pixels(0), pixels(0), pixels(255), pixels(255)])
        #expect(abrupt.mask.count > 100)
        #expect(abrupt.noFirstFlash && abrupt.staysVisible && abrupt.noDetachedIcon)
        #expect(!abrupt.fadesIn)
        let fade = observed([pixels(0), pixels(0), pixels(128), pixels(255), pixels(255)])
        #expect(fade.noFirstFlash && fade.fadesIn && fade.staysVisible && fade.noDetachedIcon)
    }

    @Test func prematureAndDetachedResultsStillFailTheirOwnPredicates() {
        let early = observed([pixels(128), pixels(0), pixels(128), pixels(255), pixels(255)])
        #expect(!early.noFirstFlash && early.fadesIn && early.staysVisible)
        #expect(!early.hidden(at: 2), "a writing sample with visible result must still fail")
        let detached = observed([pixels(0), pixels(0), pixels(128, detached: true), pixels(255), pixels(255)])
        #expect(detached.noFirstFlash && detached.fadesIn && detached.staysVisible)
        #expect(!detached.noDetachedIcon && detached.strayIcons[2] == 1)
    }

    private func image(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func rendered(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    @Test func archiveDefersWritesAndPreservesEveryRawAndImagePixel() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-reveal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let evidence = ChatRevealEvidence(folder: folder)
        let started = Date()
        let raw = [pixels(0), pixels(128), pixels(255)]
        var imageBytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        for y in 0..<64 {
            for x in 0..<64 {
                let i = (y * 64 + x) * 4
                imageBytes[i] = UInt8(x * 3); imageBytes[i + 1] = UInt8(y * 3)
                imageBytes[i + 2] = UInt8((x + y) % 256); imageBytes[i + 3] = 255
            }
        }
        let inputImage = try image(imageBytes, width: 64, height: 64)
        let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
            bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(inputImage, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let expectedPixels = try rendered(ChatRevealEvidence.snapshot(context))
        try await evidence.retaining {
            for (i, bytes) in raw.enumerated() {
                var reusedRaw = bytes
                let captured = try evidence.capture("frame-\(i)", width: width, height: height, started: started,
                    pixels: { reusedRaw }, image: { try ChatRevealEvidence.snapshot(context) })
                reusedRaw[0] = 255
                #expect(captured == bytes, "captured raw value survives reuse of the caller's array")
                #expect(!FileManager.default.fileExists(atPath: folder.path), "no directory/PNG/raw write in capture interval")
            }
            // Reuse the original render surface before deferred serialization:
            // a retained mutable buffer would archive this red frame instead.
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let changed = try rendered(ChatRevealEvidence.snapshot(context))
            #expect(changed != expectedPixels)
        }
        for (i, bytes) in raw.enumerated() {
            #expect(try Data(contentsOf: folder.appendingPathComponent("frame-\(i).rgba")) == Data(bytes))
            let png = try Data(contentsOf: folder.appendingPathComponent("frame-\(i).png"))
            let decoded = try #require(NSBitmapImageRep(data: png)?.cgImage)
            #expect(decoded.width == 64 && decoded.height == 64)
            #expect(try rendered(decoded) == expectedPixels)
        }
        let archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            folder.appendingPathComponent("frame-0-archive.json"))) as? [String: Any])
        let records = try #require(archive["frames"] as? [[String: Any]])
        #expect(records.count == raw.count)
        for record in records {
            #expect(record["width"] as? Int == width && record["height"] as? Int == height)
            let stages = try #require(record["stages"] as? [String: Double])
            let rawStart = try #require(stages["raw_start"]), rawEnd = try #require(stages["raw_end"])
            let imageStart = try #require(stages["image_start"]), imageEnd = try #require(stages["image_end"])
            let encodeStart = try #require(stages["encode_start"]), encodeEnd = try #require(stages["encode_end"])
            let writeStart = try #require(stages["png_write_start"]), writeEnd = try #require(stages["png_write_end"])
            #expect(rawStart <= rawEnd && rawEnd <= imageStart && imageStart <= imageEnd)
            #expect(encodeStart <= encodeEnd && encodeEnd <= writeStart && writeStart <= writeEnd)
        }
    }

    @Test func aThrownCaptureStillArchivesTheCollectedRawFrame() async throws {
        enum Probe: Error { case stopped }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-reveal-partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let evidence = ChatRevealEvidence(folder: folder), raw = pixels(128)
        var failed = false
        do {
            try await evidence.retaining {
                _ = try evidence.capture("partial", width: width, height: height, started: Date(),
                    pixels: { raw }, image: { throw Probe.stopped })
            }
        } catch Probe.stopped { failed = true }
        #expect(failed)
        #expect(try Data(contentsOf: folder.appendingPathComponent("partial.rgba")) == Data(raw))
        let archive = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            folder.appendingPathComponent("partial-archive.json"))) as? [String: Any])
        #expect(!(archive["capture_failure"] as? String ?? "").isEmpty)
        let records = try #require(archive["frames"] as? [[String: Any]])
        #expect(records.count == 1 && (records[0]["image_captured"] as? Bool) == false)
    }

    @Test func anArchiveWriteErrorCannotBecomeAPass() async throws {
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent("chat-reveal-blocked-" + UUID().uuidString)
        try Data([1]).write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let evidence = ChatRevealEvidence(folder: blocked.appendingPathComponent("not-a-directory"))
        var failed = false
        do { try await evidence.retaining {} }
        catch { failed = true }
        #expect(failed)
    }
}
