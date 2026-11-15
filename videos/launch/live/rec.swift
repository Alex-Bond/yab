// rec: a region of the main display to an .mov, 60 fps, no cursor, with the
// system's sound. ScreenCaptureKit.
//
//   rec OUT.mov X Y W H SECONDS [--no-audio]
//
// X Y W H in points, top-left origin. Stops after SECONDS, or on SIGINT/SIGTERM.
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    var started = false
    var stream: SCStream?
    let queue = DispatchQueue(label: "rec")

    init(out: URL, width: Int, height: Int, audio wantAudio: Bool) throws {
        try? FileManager.default.removeItem(at: out)
        writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 40_000_000, AVVideoExpectedSourceFrameRateKey: 60,
                                              AVVideoMaxKeyFrameIntervalKey: 60],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if wantAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            audio = a
        } else { audio = nil }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        if type == .screen {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete || status == .idle
            else { return }
            if status == .idle { return }
            if !started {
                writer.startWriting()
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
                started = true
            }
            if video.isReadyForMoreMediaData { video.append(buffer) }
        } else if type == .audio, started, let audio, audio.isReadyForMoreMediaData {
            audio.append(buffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write("stream stopped: \(error)\n".data(using: .utf8)!)
    }

    func finish() async {
        try? await stream?.stopCapture()
        guard started else { print("no frames"); exit(1) }
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        print("saved \(writer.outputURL.path)")
    }
}

let args = CommandLine.arguments
guard args.count >= 7 else { print("rec OUT X Y W H SECONDS [--no-audio]"); exit(2) }
let out = URL(fileURLWithPath: args[1])
let x = Double(args[2])!, y = Double(args[3])!, w = Double(args[4])!, h = Double(args[5])!
let seconds = Double(args[6])!
let wantAudio = !args.contains("--no-audio")

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { CGDisplayIsMain($0.displayID) != 0 }) ?? content.displays.first else { print("no display"); exit(1) }
        let scale = CGFloat(display.width) > 0 ? (NSScreenScale.of(display.displayID)) : 1
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: x, y: y, width: w, height: h)
        config.width = Int(w * scale) / 2 * 2
        config.height = Int(h * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.queueDepth = 8
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = wantAudio
        config.sampleRate = 48000
        config.channelCount = 2
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let recorder = try Recorder(out: out, width: config.width, height: config.height, audio: wantAudio)
        let stream = SCStream(filter: filter, configuration: config, delegate: recorder)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        if wantAudio { try stream.addStreamOutput(recorder, type: .audio, sampleHandlerQueue: recorder.queue) }
        recorder.stream = stream
        try await stream.startCapture()
        print("recording \(config.width)x\(config.height)")
        let stop = { Task { await recorder.finish(); exit(0) } }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main); s1.setEventHandler { _ = stop() }; s1.resume()
        let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main); s2.setEventHandler { _ = stop() }; s2.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = stop() }
        withExtendedLifetime([s1, s2]) {}
        _keep = [s1, s2]
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
nonisolated(unsafe) var _keep: [Any] = []

enum NSScreenScale {
    static func of(_ id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }
}

dispatchMain()
