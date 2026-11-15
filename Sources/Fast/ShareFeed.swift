import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import VideoToolbox

/// A picture yab shows a page itself, instead of WebKit: a tab (a part of
/// yab's own window), another app's window or a screen, taken by
/// ScreenCaptureKit, made H.264 by the Mac's encoder, and handed out a
/// frame at a time for the page's decoder (ShareScript). WebKit's own
/// getDisplayMedia only knows the system's picker; this is what lets yab
/// have its own, with its tabs in it.
final class ShareFeed: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Encoding { case h264, jpeg }
    /// CEF distributions without proprietary video codecs still decode images.
    /// This is chosen by the native consumer, before its capture is prepared.
    var encoding: Encoding = .h264
    private let images = CIContext(options: [.cacheIntermediates: false])
    private var imageSize: (width: Int, height: Int)?
    struct Format {
        /// WebCodecs' name for it: avc1.PPCCLL.
        let codec: String
        /// The avcC box, the decoder's description.
        let description: Data
        let width: Int
        let height: Int
    }

    struct Chunk {
        let data: Data
        let key: Bool
        /// Microseconds from the first frame.
        let time: Int64
    }

    /// On the main thread: a new format comes before the first frame of it.
    var onFormat: ((Format) -> Void)?
    var onChunk: ((Chunk) -> Void)?
    /// The capture ended by itself: the window closed, the display went.
    var onEnd: ((Error?) -> Void)?

    /// Frames go out only while this is true (a tab out of sight shows
    /// the last one it sent). Set on the main thread, read on the queue.
    var open: Bool {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue } }
    }

    private let lock = NSLock()
    private var _open = true
    private let queue = DispatchQueue(label: "yab.share.feed", qos: .userInteractive)
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var size = (width: 0, height: 0)
    private var fps = 30
    /// The page's largest size, if it named one (Self.pixels).
    var most: CGSize?
    private var cursor = false
    private var wantKey = true
    private var lastFormat: CMFormatDescription?
    private var first: CMTime?
    private var stopped = false
    /// The last picture taken, and when a frame last went out: a still
    /// page gives ScreenCaptureKit nothing new to send, so the last one is
    /// sent again each second, and at once when a whole one is asked for.
    /// A decoder that lost its place, or a call that joined late, would
    /// otherwise wait for the page to change.
    private var last: CVPixelBuffer?
    private var lastTime = CMTime.invalid
    private var sentAt: CFAbsoluteTime = 0
    private var refresh: DispatchSourceTimer?

    /// `rect`, a part of the window in its points from the top left, for a
    /// tab; nil for all of it. `scale`, the screen's pixels to a point.
    func start(_ filter: SCContentFilter, rect: CGRect?, points: CGSize, scale: CGFloat, cursor: Bool, fps: Int = 30,
               done: @escaping (Error?) -> Void) {
        self.fps = fps
        self.cursor = cursor
        let config = SCStreamConfiguration()
        let pixels = Self.pixels(rect?.size ?? points, scale: scale, most: most)
        config.width = pixels.width
        config.height = pixels.height
        if let rect { config.sourceRect = rect }
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = cursor
        config.queueDepth = 5
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            done(error)
            return
        }
        self.stream = stream
        queue.sync { self.size = pixels }
        let refresh = DispatchSource.makeTimerSource(queue: queue)
        refresh.schedule(deadline: .now() + 0.5, repeating: 0.5)
        refresh.setEventHandler { [weak self] in
            guard let self, self.wantKey || CFAbsoluteTimeGetCurrent() - self.sentAt > 1 else { return }
            self.again()
        }
        refresh.resume()
        self.refresh = refresh
        stream.startCapture { error in DispatchQueue.main.async { done(error) } }
    }

    /// The tab's place in its window changed: the window was sized, the
    /// side column came or went.
    func move(_ rect: CGRect, scale: CGFloat) {
        guard let stream else { return }
        let config = SCStreamConfiguration()
        let pixels = Self.pixels(rect.size, scale: scale, most: most)
        config.width = pixels.width
        config.height = pixels.height
        config.sourceRect = rect
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = cursor
        config.queueDepth = 5
        // The last picture is the old size: not to be sent again.
        queue.async { self.last = nil }
        stream.updateConfiguration(config) { _ in }
    }

    /// The next frame out whole, for a decoder that fell behind: now, from
    /// the last picture, if the page is still.
    func key() {
        queue.async {
            self.wantKey = true
            // Every JPEG is independent. Re-encoding immediately when a
            // receiver drops one would feed the same backpressure again.
            // The next captured frame or bounded refresh supplies it.
            if self.encoding == .h264 { self.again() }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
        queue.async {
            self.stopped = true
            self.refresh?.cancel()
            self.refresh = nil
            self.last = nil
            if let session = self.session {
                VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(session)
            }
            self.session = nil
        }
    }

    /// Whole, even pixels, at most what the page asked for (`most`, from
    /// its getDisplayMedia constraints) and never more than 1080p's worth:
    /// a call keeps a screen's size and drops frames to fit its bandwidth,
    /// so a Retina tab sent whole, 2490 by 1866, reached Meet at 5 frames
    /// a second.
    static func pixels(_ points: CGSize, scale: CGFloat, most: CGSize? = nil) -> (width: Int, height: Int) {
        var w = points.width * scale, h = points.height * scale
        var fit: CGFloat = 1
        let area: CGFloat = 1920 * 1080
        if w * h > area { fit = (area / (w * h)).squareRoot() }
        if let most {
            if most.width > 0 { fit = min(fit, most.width / w) }
            if most.height > 0 { fit = min(fit, most.height / h) }
        }
        w *= fit; h *= fit
        func even(_ v: CGFloat) -> Int { max(2, Int(v.rounded()) & ~1) }
        return (even(w), even(h))
    }

    // MARK: the stream

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopped, open,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = CMSampleBufferGetImageBuffer(sample)
        else { return }
        last = pixels
        encode(pixels, CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// The last picture once more, stamped now.
    private func again() {
        guard !stopped, open, let last else { return }
        var now = CMClockGetTime(CMClockGetHostTimeClock())
        if lastTime.isValid, CMTimeCompare(now, lastTime) <= 0 { now = CMTimeAdd(lastTime, CMTime(value: 1, timescale: 1000)) }
        encode(last, now)
    }

    private func encode(_ pixels: CVPixelBuffer, _ time: CMTime) {
        if encoding == .jpeg { encodeImage(pixels, time); return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if session == nil || width != size.width || height != size.height { make(width, height) }
        guard let session else { return }
        if first == nil { first = time }
        lastTime = time
        sentAt = CFAbsoluteTimeGetCurrent()
        var properties: CFDictionary?
        if wantKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            wantKey = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixels, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: properties, infoFlagsOut: nil) { [weak self] status, _, encoded in
            guard status == noErr, let encoded, let self else { return }
            self.encoded(encoded)
        }
    }

    private func encodeImage(_ pixels: CVPixelBuffer, _ time: CMTime) {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let data = images.jpegRepresentation(of: CIImage(cvPixelBuffer: pixels), colorSpace: space,
                                                    options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]),
              data.count <= 2_000_000 else { return }
        if first == nil { first = time }
        lastTime = time
        sentAt = CFAbsoluteTimeGetCurrent()
        let changed = imageSize?.width != width || imageSize?.height != height
        imageSize = (width, height)
        wantKey = false
        let chunk = Chunk(data: data, key: true,
                          time: Int64(CMTimeGetSeconds(CMTimeSubtract(time, first ?? time)) * 1_000_000))
        DispatchQueue.main.async {
            if changed { self.onFormat?(Format(codec: "image/jpeg", description: Data(), width: width, height: height)) }
            self.onChunk?(chunk)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onEnd?(error) }
    }

    private func make(_ width: Int, _ height: Int) {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        size = (width, height)
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr, let made
        else { return }
        // Screens are text and edges: about a bit and a half a pixel a
        // second at 30, 8 Mbit/s for 1080p. The call's own encoder takes
        // it down to what it sends.
        let rate = min(16_000_000, max(1_500_000, Int(Double(width * height) * 4)))
        let set: [(CFString, Any)] = [
            (kVTCompressionPropertyKey_RealTime, true),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel),
            (kVTCompressionPropertyKey_AllowFrameReordering, false),
            (kVTCompressionPropertyKey_ExpectedFrameRate, fps),
            (kVTCompressionPropertyKey_AverageBitRate, rate),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 10),
        ]
        for (key, value) in set { VTSessionSetProperty(made, key: key, value: value as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(made)
        session = made
        wantKey = true
    }

    private func encoded(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var described: Format?
        if key, lastFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
            described = Self.format(format)
            lastFormat = format
        }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        let data = Data(bytes: pointer, count: length)
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let micro = Int64(CMTimeGetSeconds(CMTimeSubtract(time, first ?? time)) * 1_000_000)
        let chunk = Chunk(data: data, key: key, time: micro)
        DispatchQueue.main.async {
            if let described { self.onFormat?(described) }
            self.onChunk?(chunk)
        }
    }

    static func format(_ format: CMFormatDescription) -> Format? {
        guard let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let avcC = atoms["avcC"] as? Data, avcC.count > 4
        else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let codec = String(format: "avc1.%02x%02x%02x", avcC[1], avcC[2], avcC[3])
        return Format(codec: codec, description: avcC, width: Int(dims.width), height: Int(dims.height))
    }
}
