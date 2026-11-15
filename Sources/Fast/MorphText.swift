import SwiftUI

// MARK: - morphing words

/// A one-line text that morphs as it changes: the letters
/// the old and the new text share keep their identity and glide sideways to
/// where they now belong, the letters that left fade where they stood, and
/// the new ones come up in place a beat later. "Continue" becomes "Start
/// browsing" without a page going by.
struct MorphText: View {
    let text: String

    @State private var glyphs: [Glyph]
    @State private var nextID: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String) {
        self.text = text
        _glyphs = State(initialValue: Self.fresh(text, from: 0))
        _nextID = State(initialValue: text.count)
    }

    static let duration = 0.28

    var body: some View {
        KernedLine {
            ForEach(glyphs) { glyph in
                Text(String(glyph.character))
                    .transition(reduceMotion ? .opacity : Self.letter)
            }
            // The same words as one run, up to each letter: where a letter
            // ends in the kerned line is where it is put.
            ForEach(prefixes, id: \.self) { prefix in
                Text(prefix).hidden()
                    .layoutValue(key: KernedLine.Measure.self, value: true)
                    .transition(.identity)
            }
        }
        .fixedSize()
        .onChange(of: text) { _, new in
            let (morphed, used) = Self.morph(glyphs, into: new, from: nextID)
            nextID = used
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .timingCurve(0.19, 1, 0.22, 1, duration: Self.duration)) {
                glyphs = morphed
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private struct Glyph: Identifiable, Equatable {
        let id: Int
        let character: Character
    }

    private var prefixes: [String] {
        var line = ""
        return glyphs.map { line.append($0.character); return line }
    }

    /// Leaving is quick, arriving waits for it: the two never sit on top of
    /// each other at full strength.
    private static let letter: AnyTransition = .asymmetric(
        insertion: .scale(scale: 0.95).combined(with: .opacity)
            .animation(.linear(duration: duration * 0.5).delay(duration * 0.35)),
        removal: .scale(scale: 0.95).combined(with: .opacity)
            .animation(.linear(duration: duration * 0.25))
    )

    private static func fresh(_ text: String, from id: Int) -> [Glyph] {
        text.enumerated().map { Glyph(id: id + $0.offset, character: $0.element) }
    }

    /// The new text's letters, each carrying the identity of the old letter
    /// it is, by the longest common subsequence, or a new identity. Only
    /// runs of two or more are kept, and under three letters in all the
    /// whole text hands over on the spot: a lone shared letter is a
    /// coincidence, not a link.
    private static func morph(_ old: [Glyph], into text: String, from id: Int) -> ([Glyph], Int) {
        let new = Array(text)
        let n = old.count, m = new.count
        guard n > 0, m > 0 else { return (fresh(text, from: id), id + m) }
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i].character == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(old: Int, new: Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i].character == new[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var kept: [Int: Int] = [:]
        var run: [(old: Int, new: Int)] = []
        func close() {
            if run.count >= 2 { for pair in run { kept[pair.new] = pair.old } }
            run = []
        }
        for pair in pairs {
            if let last = run.last, last.old + 1 != pair.old || last.new + 1 != pair.new { close() }
            run.append(pair)
        }
        close()
        guard kept.count >= 3 else { return (fresh(text, from: id), id + m) }
        var result: [Glyph] = []
        var next = id
        for (index, character) in new.enumerated() {
            if let source = kept[index] {
                result.append(old[source])
            } else {
                result.append(Glyph(id: next, character: character))
                next += 1
            }
        }
        return (result, next)
    }
}

/// Letters set one by one, standing where one kerned run of the same words
/// puts them, so the line has the run's width and spacing and each letter is
/// still a view of its own that can glide, fade and arrive.
private struct KernedLine: Layout {
    struct Measure: LayoutValueKey {
        static let defaultValue = false
    }

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let runs = subviews.filter { $0[Measure.self] }
        let letters = subviews.filter { !$0[Measure.self] }
        let line = runs.last?.sizeThatFits(.unspecified) ?? .zero
        let height = letters.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: line.width, height: max(line.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        let runs = subviews.filter { $0[Measure.self] }
        let letters = subviews.filter { !$0[Measure.self] }
        for run in runs { run.place(at: bounds.origin, anchor: .topLeading, proposal: .unspecified) }
        for (index, letter) in letters.enumerated() {
            let width = letter.sizeThatFits(.unspecified).width
            let end = index < runs.count ? runs[index].sizeThatFits(.unspecified).width : width
            letter.place(at: CGPoint(x: bounds.minX + max(0, end - width), y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }
}
