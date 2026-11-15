import AppKit
import Foundation

/// Only this reveal test's observer: capture on MainActor, archive after the
/// timed sequence. The two resolutions remain separate actual observations.
@MainActor
final class ChatRevealEvidence {
    struct Frame {
        let name: String
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let requested: Double?
        let writing: Bool?
        var image: CGImage?
        var stages: [String: Double]
    }

    let folder: URL?
    private(set) var frames: [Frame] = []
    private var failure: String?

    init(folder: URL?) { self.folder = folder }

    func capture(_ name: String, width: Int, height: Int, started: Date,
                 requested: Double? = nil, writing: Bool? = nil,
                 pixels: () throws -> [UInt8], image: () throws -> CGImage) throws -> [UInt8] {
        let rawStart = Date().timeIntervalSince(started)
        let raw = try pixels()
        let rawEnd = Date().timeIntervalSince(started)
        // Keep the raw frame before a later image capture can throw.
        frames.append(Frame(name: name, width: width, height: height, pixels: raw, requested: requested, writing: writing,
                            stages: ["scenario_started_unix": started.timeIntervalSince1970,
                                     "raw_start": rawStart, "raw_end": rawEnd]))
        let index = frames.count - 1
        frames[index].stages["image_start"] = Date().timeIntervalSince(started)
        frames[index].image = try image()
        frames[index].stages["image_end"] = Date().timeIntervalSince(started)
        return raw
    }

    /// Flush on success AND a thrown sleep/capture/require. A write failure
    /// throws too; it cannot turn a failed or incomplete observation into PASS.
    func retaining<T>(_ body: @MainActor () async throws -> T) async throws -> T {
        let outcome: Result<T, Error>
        do { outcome = .success(try await body()) }
        catch { failure = String(describing: error); outcome = .failure(error) }
        try flush()
        return try outcome.get()
    }

    private func flush() throws {
        guard let folder else { return }
        let archiveStart = Date()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        var firstError: Error?
        for frame in frames {
            var stages = frame.stages
            var errors: [String] = []
            func keepFailure(_ error: Error) {
                if firstError == nil { firstError = error }
                errors.append(String(describing: error))
            }
            stages["raw_write_start"] = Date().timeIntervalSince(archiveStart)
            do { try Data(frame.pixels).write(to: folder.appendingPathComponent(frame.name + ".rgba")) }
            catch { keepFailure(error) }
            stages["raw_write_end"] = Date().timeIntervalSince(archiveStart)
            if let image = frame.image {
                stages["encode_start"] = Date().timeIntervalSince(archiveStart)
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                stages["encode_end"] = Date().timeIntervalSince(archiveStart)
                if let data {
                    stages["png_write_start"] = Date().timeIntervalSince(archiveStart)
                    do { try data.write(to: folder.appendingPathComponent(frame.name + ".png")) }
                    catch { keepFailure(error) }
                    stages["png_write_end"] = Date().timeIntervalSince(archiveStart)
                } else { keepFailure(ArchiveError.pngEncoding(frame.name)) }
            }
            records.append(["name": frame.name, "width": frame.width, "height": frame.height,
                            "raw_format": "RGBA8-premultipliedLast-byteOrder32Big-top-left",
                            "raw_bytes": frame.pixels.count, "image_captured": frame.image != nil,
                            "requested": frame.requested.map { $0 as Any } ?? NSNull(),
                            "writing": frame.writing.map { $0 as Any } ?? NSNull(),
                            "image_width": frame.image?.width ?? 0, "image_height": frame.image?.height ?? 0,
                            "stages": stages, "archive_errors": errors])
        }
        let record: [String: Any] = ["archive_started_unix": archiveStart.timeIntervalSince1970,
                                    "capture_failure": failure ?? "", "frames": records,
                                    "timing_note": "raw/image stages relative to scenario start; encode/write relative to archive start; observed costs only"]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        let name = frames.first?.name ?? "empty-reveal"
        do { try data.write(to: folder.appendingPathComponent(name + "-archive.json")) }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }

    /// CGContext owns the data (Host uses data:nil). makeImage snapshots it;
    /// CoreGraphics preserves that image on subsequent context writes (COW).
    static func snapshot(_ context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else { throw ArchiveError.bitmapSnapshot }
        return image
    }

    enum ArchiveError: Error { case pngEncoding(String), bitmapSnapshot }
}

/// The original reveal mask, energy and pixel predicates, shared with
/// negative controls so an abrupt/early/detached result still fails.
struct ChatRevealPixels {
    let mask: [Int]
    let visibility: [Double]
    let strayIcons: [Int]

    init(frames: [[UInt8]], final: [UInt8], blank: [UInt8], width: Int) {
        var mask: [Int] = []
        for index in stride(from: 0, to: final.count, by: 4) {
            var difference = 0
            for channel in 0..<3 {
                difference = max(difference, abs(Int(final[index + channel]) - Int(blank[index + channel])))
            }
            if difference > 20 { mask.append(index) }
        }
        self.mask = mask
        let minX = mask.map { ($0 / 4) % width }.min() ?? 0
        let maxX = mask.map { ($0 / 4) % width }.max() ?? 0
        let minY = mask.map { ($0 / 4) / width }.min() ?? 0
        let maxY = mask.map { ($0 / 4) / width }.max() ?? 0
        var strayIcons: [Int] = []
        for frame in frames {
            var stray = 0
            for index in stride(from: 0, to: frame.count, by: 4) {
                let x = (index / 4) % width, y = (index / 4) / width
                guard x < minX - 2 || x > maxX + 2 || y < minY - 2 || y > maxY + 2 else { continue }
                let r = Int(frame[index]), g = Int(frame[index + 1]), b = Int(frame[index + 2])
                if r > g + 20 && r > b + 10 { stray += 1 }
            }
            strayIcons.append(stray)
        }
        self.strayIcons = strayIcons
        var energy: [Double] = []
        for frame in frames {
            var difference = 0
            for index in mask {
                for channel in 0..<3 {
                    difference += abs(Int(frame[index + channel]) - Int(blank[index + channel]))
                }
            }
            energy.append(Double(difference))
        }
        let full = max(1, energy.last ?? 1)
        visibility = energy.map { $0 / full }
    }

    var noFirstFlash: Bool { visibility[0] < 0.02 && visibility[1] < 0.02 }
    var fadesIn: Bool { visibility.contains { $0 > 0.05 && $0 < 0.95 } }
    var staysVisible: Bool { visibility.suffix(2).allSatisfy { abs($0 - 1) < 0.02 } }
    var noDetachedIcon: Bool { strayIcons.allSatisfy { $0 == 0 } }
    func hidden(at index: Int) -> Bool { visibility[index] < 0.02 }
}
