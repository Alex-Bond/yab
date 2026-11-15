import AppKit
import AVFoundation
import ImageIO

// What moves, going along with feedback (Feedback.swift). A moving picture,
// a GIF, an APNG, an animated WebP, is never drawn again through NSImage,
// which keeps its first frame only: it goes as it is when it fits what the
// site takes, and as an H.264 MP4 film when it doesn't, every frame for as
// long as the picture holds it, smaller until it fits. A video too big to
// go as it is is exported at the largest size that fits.

enum FeedbackMedia {
    /// More than one frame.
    static func moves(_ source: CGImageSource) -> Bool { CGImageSourceGetCount(source) > 1 }

    static func moves(_ url: URL) -> Bool {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(moves) ?? false
    }

    /// How long frame `index` stays, in seconds, as a browser shows it: the
    /// picture's own delay, a tenth of a second for one too short to mean it.
    static func delay(_ source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let kinds: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
        ]
        for (dictionary, unclamped, clamped) in kinds {
            guard let frame = properties[dictionary] as? [CFString: Any] else { continue }
            let seconds = (frame[unclamped] as? Double) ?? (frame[clamped] as? Double) ?? 0
            return seconds < 0.02 ? 0.1 : seconds
        }
        return 0.1
    }

    /// The moving picture as an H.264 MP4 no bigger than `room`, as large as
    /// that allows; nil when even the smallest doesn't fit.
    static func film(_ source: CGImageSource, room: Int) async -> Data? {
        let count = CGImageSourceGetCount(source)
        guard count > 1, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let delays = (0 ..< count).map { delay(source, at: $0) }
        let seconds = delays.reduce(0, +)
        let side = CGFloat(max(first.width, first.height))
        let largest = min(side, 1920)
        for longest in [largest] + ([1280, 960, 640, 480] as [CGFloat]).filter({ $0 < largest }) {
            let scale = min(1, longest / side)
            // H.264 wants even sides.
            let width = max(2, Int(CGFloat(first.width) * scale) / 2 * 2)
            let height = max(2, Int(CGFloat(first.height) * scale) / 2 * 2)
            // Most of the room, the container and the first frames' overshoot
            // having the rest, never more than such a picture needs.
            let bitrate = min(Int(Double(room) * 8 * 0.8 / max(seconds, 1)), width * height * 6)
            guard bitrate > 50_000 else { return nil }
            if let data = await write(source, delays: delays, width: width, height: height, bitrate: bitrate),
               data.count <= room {
                return data
            }
        }
        return nil
    }

    private static func write(_ source: CGImageSource, delays: [Double], width: Int, height: Int, bitrate: Int) async -> Data? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("yab-feedback-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        guard let writer = try? AVAssetWriter(outputURL: out, fileType: .mp4) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        var time = 0.0
        for (index, delay) in delays.enumerated() {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                  let buffer = frame(image, width: width, height: height, pool: adaptor.pixelBufferPool)
            else { continue }
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { return nil }
                try? await Task.sleep(for: .milliseconds(5))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 1000)) else { break }
            time += delay
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: time, preferredTimescale: 1000))
        await writer.finishWriting()
        guard writer.status == .completed else { return nil }
        return try? Data(contentsOf: out)
    }

    /// One frame drawn over white, as a JPEG of a picture is, to fill the film.
    private static func frame(_ image: CGImage, width: Int, height: Int, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &made)
        }
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return buffer
    }

    /// The video exported at the largest size that fits `room`, as an MP4;
    /// nil when even the smallest doesn't.
    static func smaller(video url: URL, room: Int) async -> Data? {
        let asset = AVURLAsset(url: url)
        let presets = [AVAssetExportPreset1920x1080, AVAssetExportPreset1280x720, AVAssetExportPreset960x540,
                       AVAssetExportPreset640x480, AVAssetExportPresetMediumQuality, AVAssetExportPresetLowQuality]
        for preset in presets {
            guard let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true
            if let estimate = try? await session.estimatedOutputFileLengthInBytes, estimate > Int64(room) { continue }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("yab-feedback-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: out) }
            guard (try? await session.export(to: out, as: .mp4)) != nil,
                  let data = try? Data(contentsOf: out), !data.isEmpty
            else { continue }
            if data.count <= room { return data }
        }
        return nil
    }
}
