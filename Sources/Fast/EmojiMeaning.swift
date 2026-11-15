import Accelerate
import Foundation
import NaturalLanguage

// How Emoji finds by meaning, not only by name. Each emoji has its words
// from Unicode CLDR (Resources/emoji.dat, packed by Resources/emoji-pack.py),
// its English name and keywords: 🎉 is "party", "celebration", "hooray". A
// word typed that none of them starts still finds what it means: its vector
// (NLEmbedding, on this Mac) against every word of every emoji, "exhausted"
// 😴 🥱, "joyful" 😊, "vehicle" 🚗.

extension Emoji {
    /// CLDR's words for an emoji, by its glyph without the variation selector.
    static let cldr: [String: [String]] = Dictionary(cldrInOrder.map { (bare($0.glyph), $0.words) }, uniquingKeysWith: { first, _ in first })

    /// The same, in CLDR's order, which is the pickers'.
    static let cldrInOrder: [(glyph: String, words: [String])] = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let places = [Bundle.main.resourceURL?.appendingPathComponent("emoji.dat"), repo.appendingPathComponent("Resources/emoji.dat")]
        guard let file = places.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let packed = try? Data(contentsOf: file),
              let raw = try? (packed as NSData).decompressed(using: .zlib) as Data,
              let text = String(data: raw, encoding: .utf8)
        else { return [] }
        var out: [(glyph: String, words: [String])] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            out.append((String(parts[0]), parts[1].split(separator: "|").map(String.init)))
        }
        return out
    }()

    static func bare(_ glyph: String) -> String { glyph.replacingOccurrences(of: "\u{FE0F}", with: "") }

    // MARK: finding

    /// How well one typed word finds each emoji: its whole word 3, a word it
    /// starts 2.5, by meaning under 1, not at all 0.
    @MainActor
    static func scores(for needle: String) -> [Float] {
        let all = self.all
        var out = [Float](repeating: 0, count: all.count)
        for (index, one) in all.enumerated() {
            var best: Float = 0
            for word in one.words {
                if word == needle { best = 3; break }
                if word.hasPrefix(needle) { best = 2.5 }
            }
            out[index] = best
        }
        guard let meaning, let vector = meaning.vector(for: needle) else { return out }
        for (index, score) in meaning.near(word: vector).enumerated() where out[index] == 0 && score >= meaning.floor {
            out[index] = score
        }
        return out
    }

    /// The emoji the words find, best first: each word has to find it, by
    /// name or meaning; the recent ones a little ahead of their like.
    @MainActor
    static func rank(_ needles: [String], recent: [String]) -> [One] {
        let all = self.all
        var total = [Float](repeating: 0, count: all.count)
        var byName = [Bool](repeating: true, count: all.count)
        for (turn, needle) in needles.enumerated() {
            let scores = self.scores(for: needle)
            for index in all.indices {
                total[index] = scores[index] > 0 && (turn == 0 || total[index] > 0) ? total[index] + scores[index] : 0
                if scores[index] < 2 { byName[index] = false }
            }
        }
        let recency = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var hits: [(index: Int, score: Float)] = []
        for index in all.indices where total[index] > 0 {
            let bonus: Float = byName[index] && recency[all[index].glyph] != nil ? 0.25 : 0
            hits.append((index, total[index] / Float(needles.count) + bonus))
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        // Found by meaning, the list stops where the meaning thins: four
        // rows of them past what the names found.
        var shown = 0
        return hits.compactMap { hit in
            if !byName[hit.index] { shown += 1; if shown > 4 * Omnibox.emojiColumns { return nil } }
            return all[hit.index]
        }
    }

    // MARK: the vectors

    @MainActor static var meaning: Meaning?
    @MainActor private static var warming = false
    /// The vectors are made, or this Mac has none: nothing more is coming.
    @MainActor static var settled = false

    /// Makes the vectors, away from the main thread, the first time the
    /// grid shows; till then the names alone find.
    @MainActor
    static func warm(then done: @escaping @MainActor () -> Void) {
        guard !settled, !warming else { return }
        warming = true
        let all = self.all
        DispatchQueue.global(qos: .userInitiated).async {
            let made = Meaning(all)
            DispatchQueue.main.async {
                meaning = made
                warming = false
                settled = true
                found = nil
                done()
            }
        }
    }

    /// The same, waited for (tests).
    @MainActor
    static func warmNow() {
        guard meaning == nil else { return }
        meaning = Meaning(all)
        settled = true
        found = nil
    }

    /// Every word of every emoji as a unit vector, and each emoji's
    /// words' mean, for what an emoji is near.
    final class Meaning {
        let embedding: NLEmbedding
        let dimension: Int
        let count: Int
        /// The words, a row each.
        let vectors: [Float]
        /// Each emoji's rows in vectors.
        let rows: [[Int32]]
        /// Each emoji's words together, a row each, zero where it has none.
        let means: [Float]
        /// Below this, nearness is noise.
        let floor: Float = 0.5

        init?(_ all: [One]) {
            guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return nil }
            self.embedding = embedding
            let dimension = embedding.dimension
            self.dimension = dimension
            var vectors: [Float] = []
            var row: [String: Int32] = [:]
            var rows: [[Int32]] = []
            var means = [Float](repeating: 0, count: all.count * dimension)
            for (index, one) in all.enumerated() {
                var mine: [Int32] = []
                for word in one.words {
                    if let known = row[word] { if !mine.contains(known) { mine.append(known) }; continue }
                    guard let vector = embedding.vector(for: word) else { continue }
                    row[word] = Int32(row.count)
                    mine.append(Int32(row.count - 1))
                    vectors += Meaning.unit(vector.map(Float.init))
                }
                rows.append(mine)
            }
            // A mean weighs each word by how few emoji have it: "face" and
            // "hand" are on hundreds and say little of any one.
            var many = [Int](repeating: 0, count: row.count)
            for mine in rows { for known in mine { many[Int(known)] += 1 } }
            for (index, mine) in rows.enumerated() where !mine.isEmpty {
                var mean = [Float](repeating: 0, count: dimension)
                for known in mine {
                    let weight = Float(log(Double(all.count) / Double(many[Int(known)])))
                    let start = Int(known) * dimension
                    for axis in 0..<dimension { mean[axis] += weight * vectors[start + axis] }
                }
                means.replaceSubrange(index * dimension..<(index + 1) * dimension, with: Meaning.unit(mean))
            }
            self.vectors = vectors
            self.rows = rows
            self.means = means
            self.count = all.count
        }

        func vector(for word: String) -> [Float]? {
            guard word.count >= 3, let vector = embedding.vector(for: word) else { return nil }
            return Meaning.unit(vector.map(Float.init))
        }

        /// How near each emoji is to this word: its nearest word, and all
        /// its words together, so 🍺's "summer" stays far from "winter".
        func near(word: [Float]) -> [Float] {
            let near = Meaning.times(vectors, rows: vectors.count / dimension, word, dimension)
            let whole = Meaning.times(means, rows: count, word, dimension)
            return rows.enumerated().map { index, mine in
                0.6 * mine.reduce(0) { max($0, near[Int($1)]) } + 0.4 * whole[index]
            }
        }

        static func times(_ matrix: [Float], rows: Int, _ vector: [Float], _ dimension: Int) -> [Float] {
            var out = [Float](repeating: 0, count: rows)
            vDSP_mmul(matrix, 1, vector, 1, &out, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
            return out
        }

        static func unit(_ vector: [Float]) -> [Float] {
            var length: Float = 0
            vDSP_svesq(vector, 1, &length, vDSP_Length(vector.count))
            guard length > 0 else { return vector }
            return vector.map { $0 / length.squareRoot() }
        }
    }
}
