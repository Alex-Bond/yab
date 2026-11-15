import AppKit
import Vision
import VisionKit
import WebKit

// The words in a picture on a page, read on this Mac: the picture's menu
// copies them (Copy Text), and ⌘F counts and marks them among the page's
// own (Find.swift). WebKit's Live Text lets a person select them by hand;
// this is the same reading for what Yab does itself.
//
// Two readings. VisionKit's (ImageAnalyzer), the one WebKit uses: done by
// the Mac's media analysis service, a tenth of a second, the text alone,
// for Copy Text. Vision's (RecognizeTextRequest), in this process, with
// every word's box, for ⌘F to mark: first its fast level, at once, then its
// accurate one, which reads more writing systems than Latin and photographs
// better, but whose model is readied for the Neural Engine on first use, a
// wait a busy Mac has made thirty seconds.
//
// A picture is read when someone reaches for it: the pointer resting on it
// (what shows of it, from WebKit's own picture of the page, so nothing is
// fetched), a right-click, or ⌘F looking through the page (the picture's
// bytes, as Copy Image fetches them). What was read is kept by the
// picture's address, a few hundred of them, for the next menu or search.

/// One picture's words, line by line, each word with its box in the
/// picture, from 0 to 1 and from the top left.
struct PictureWords: Sendable {
    struct Word: Sendable {
        let text: String
        let box: CGRect
    }

    let lines: [[Word]]
    /// Read from all of the picture, not just what showed of it.
    let whole: Bool
    /// Read as well as this Mac reads: VisionKit, or Vision's accurate
    /// level, not its fast one.
    var fine = true

    var text: String {
        lines.map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    var isEmpty: Bool { lines.isEmpty }

    /// For the find script: each line a list of words with their boxes.
    var script: [[[String: Any]]] {
        lines.map { line in
            line.map { ["t": $0.text, "x": $0.box.minX, "y": $0.box.minY, "w": $0.box.width, "h": $0.box.height] }
        }
    }

    /// Vision's pieces of one line put back together: a gap wider than
    /// it likes, "(user scope)" or two columns of a table, comes as two.
    /// Pieces whose middles stand within each other's height are one row,
    /// read left to right; rows top to bottom.
    static func rows(_ pieces: [[Word]]) -> [[Word]] {
        func span(_ piece: [Word]) -> (top: CGFloat, bottom: CGFloat) {
            (piece.map(\.box.minY).min() ?? 0, piece.map(\.box.maxY).max() ?? 0)
        }
        var rows: [[[Word]]] = []
        for piece in pieces.sorted(by: { span($0).top < span($1).top }) {
            let (top, bottom) = span(piece)
            let middle = (top + bottom) / 2
            if let at = rows.lastIndex(where: { row in
                let (rowTop, rowBottom) = span(row.flatMap { $0 })
                return middle > rowTop && middle < rowBottom && (rowTop + rowBottom) / 2 > top && (rowTop + rowBottom) / 2 < bottom
            }) {
                rows[at].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in row.sorted { ($0.first?.box.minX ?? 0) < ($1.first?.box.minX ?? 0) }.flatMap { $0 } }
    }

    /// VisionKit's reading: the lines, with no boxes.
    static func transcript(_ image: CGImage, whole: Bool) async -> PictureWords? {
        guard ImageAnalyzer.isSupported else { return nil }
        let analysis = try? await ImageAnalyzer().analyze(image, orientation: .up, configuration: ImageAnalyzer.Configuration(.text))
        guard let analysis else { return nil }
        let lines = analysis.transcript.split(whereSeparator: \.isNewline).map { line in
            line.split(whereSeparator: \.isWhitespace).map { Word(text: String($0), box: .zero) }
        }.filter { !$0.isEmpty }
        return PictureWords(lines: lines, whole: whole)
    }

    /// Vision's lines, cut into words, each word's box from Vision's
    /// for that stretch of the line. Vision's own Swift requests, which
    /// read off the calling thread: the older VNImageRequestHandler never
    /// came back inside the app on macOS 27, while WebKit's reading of the
    /// same picture did.
    /// The languages this Mac reads in, as Vision can read them, English
    /// always among them.
    static let languages: [Locale.Language] = {
        var out: [Locale.Language] = []
        for id in Locale.preferredLanguages + ["en-US"] {
            let language = Locale.Language(identifier: id)
            if !out.contains(where: { $0.languageCode == language.languageCode }) { out.append(language) }
        }
        return out
    }()

    static func read(_ image: CGImage, whole: Bool, fine: Bool = true) async -> PictureWords {
        var request = RecognizeTextRequest()
        request.recognitionLevel = fine ? .accurate : .fast
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = Self.languages
        // Writing a few pixels high on a big picture is a smudge, not words.
        request.minimumTextHeightFraction = 0.012
        let observations = (try? await request.perform(on: image)) ?? []
        var lines: [[Word]] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { continue }
            let string = candidate.string
            var words: [Word] = []
            var index = string.startIndex
            while index < string.endIndex {
                guard let start = string[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
                let end = string[start...].firstIndex(where: \.isWhitespace) ?? string.endIndex
                if let box = candidate.boundingBox(for: start..<end)?.boundingBox.cgRect {
                    // Vision's boxes rise from the bottom left.
                    words.append(Word(text: String(string[start..<end]),
                                      box: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)))
                }
                index = end
            }
            if !words.isEmpty { lines.append(words) }
        }
        return PictureWords(lines: rows(lines), whole: whole, fine: fine)
    }
}

@MainActor
final class PictureReader {
    static let shared = PictureReader()

    /// What Copy Text gives, and what ⌘F marks, by the picture's address.
    private var texts: [String: PictureWords] = [:]
    private var marks: [String: PictureWords] = [:]
    private var order: [String] = []
    private var reading: [String: Task<PictureWords?, Never>] = [:]
    private var marking: [String: Task<PictureWords?, Never>] = [:]
    private static let keep = 300
    /// ⌘F's readings: the fast ones, then the accurate ones, one at a time each.
    private let quick = ReadingLane()
    private let careful = ReadingLane()
    /// Past this many pixels a picture is read smaller: words big enough
    /// to read stay big enough.
    private static let side = 2400

    func words(_ src: String) -> PictureWords? { texts[src] }

    /// For the bench (pointer op=pictures): pictures looked at under the
    /// pointer, and pages WebKit was asked to read whole.
    private(set) var looks = 0
    var pageReads = 0
    var counts: [String: Any] { ["looks": looks, "pageReads": pageReads, "kept": order.count, "reading": reading.count] }

    /// What shows of a picture the pointer rests on: WebKit's own picture
    /// of that part of the page, at the screen's scale, read by VisionKit.
    func look(_ src: String, at rect: CGRect, whole: Bool, in web: PageView) {
        guard texts[src] == nil, reading[src] == nil, rect.width >= 40, rect.height >= 16 else { return }
        looks += 1
        let configuration = WKSnapshotConfiguration()
        let zoom = web.pageZoom * web.magnification
        configuration.rect = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        configuration.afterScreenUpdates = false
        reading(src) {
            guard let shot = try? await web.takeSnapshot(configuration: configuration),
                  let image = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return await PictureWords.transcript(image, whole: whole)
        }
    }

    /// All of a picture's words, as soon as they can be had: VisionKit's
    /// reading of its bytes. For Copy Text.
    func text(_ url: URL, from tab: Tab) async -> PictureWords? {
        let src = url.absoluteString
        if let words = texts[src], words.whole { return words }
        if let task = reading[src], let words = await task.value, words.whole { return words }
        return await reading(src) {
            guard let image = await Self.image(url, from: tab) else { return nil }
            return await PictureWords.transcript(image, whole: true)
        }.value
    }

    /// The words of a picture still being read, once they are.
    func pending(_ src: String) async -> PictureWords? {
        guard let task = reading[src] else { return texts[src] }
        return await task.value ?? texts[src]
    }

    /// All of a picture's words with their boxes, for ⌘F: Vision's fast
    /// reading at once, and its accurate one handed to `finer` when it
    /// reads something else.
    func marks(_ url: URL, from tab: Tab, finer: @escaping @MainActor (PictureWords) -> Void) async -> PictureWords? {
        let src = url.absoluteString
        if let words = marks[src] { return words }
        // A picture VisionKit read all of and found nothing in is empty.
        if let words = texts[src], words.whole, words.isEmpty { return words }
        if let task = marking[src] { return await task.value }
        let task = Task<PictureWords?, Never> {
            // One picture at a time, each reading in its own lane (#1991):
            // ⌘F asks for thirty, and thirty of Vision's readings at once,
            // each with its accurate one after, starved the rest of the Mac:
            // Chromium's pages stopped scrolling and answering for 40 s.
            guard let read = await self.quick.run({ () async -> (CGImage, PictureWords)? in
                guard let image = await Self.image(url, from: tab) else { return nil }
                return (image, await PictureWords.read(image, whole: true, fine: false))
            }) else { return nil }
            let (image, fast) = read
            self.keep(src, mark: fast)
            Task {
                let fine = await self.careful.run { await PictureWords.read(image, whole: true) }
                self.keep(src, mark: fine)
                self.keep(src, text: fine)
                if fine.text != fast.text { finer(fine) }
            }
            return fast
        }
        marking[src] = task
        let words = await task.value
        marking[src] = nil
        return words
    }

    @discardableResult
    private func reading(_ src: String, _ work: @escaping @MainActor () async -> PictureWords?) -> Task<PictureWords?, Never> {
        let task = Task<PictureWords?, Never> { await work() }
        reading[src] = task
        Task {
            let words = await task.value
            if reading[src] == task { reading[src] = nil }
            if let words { keep(src, text: words) }
        }
        return task
    }

    /// All of a picture over a part, and a fine reading over a fast one.
    private func keep(_ src: String, text words: PictureWords) {
        if let had = texts[src], (had.whole && !words.whole) || (had.whole == words.whole && had.fine && !words.fine) { return }
        texts[src] = words
        note(src)
    }

    private func keep(_ src: String, mark words: PictureWords) {
        if let had = marks[src], had.fine, !words.fine { return }
        marks[src] = words
        note(src)
    }

    private func note(_ src: String) {
        if !order.contains(src) { order.append(src) }
        while order.count > Self.keep {
            let gone = order.removeFirst()
            texts[gone] = nil
            marks[gone] = nil
        }
    }

    private static func image(_ url: URL, from tab: Tab) async -> CGImage? {
        guard let data = await Browser.imageData(url, from: tab, largest: side) else { return nil }
        return await aside { decode(data) }
    }

    /// Decoding a picture blocks its thread: on a queue of its own, never on
    /// Swift's shared threads, which a busy Mac can leave none of.
    private static let queue = DispatchQueue(label: "yab.picture-words", qos: .utility)

    nonisolated private static func aside<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { done in
            queue.async { done.resume(returning: work()) }
        }
    }

    nonisolated private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// One at a time, in the order asked: a reading waits for the one before.
@MainActor
final class ReadingLane {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ work: () async -> T) async -> T {
        if busy { await withCheckedContinuation { waiting.append($0) } } else { busy = true }
        defer { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
        return await work()
    }
}
