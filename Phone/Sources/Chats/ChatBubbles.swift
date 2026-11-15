import SwiftUI

/// A message's ground as Messages (iOS 26) draws it: round, its tail a hook
/// hanging under the foot corner of the side it is said from, yours at the
/// right, the agent's at the left. The tail stays inside the bubble's width
/// and drops `tailDrop` under it, so a bubble's edge is on the screen's
/// 16 line with or without one; only the last of a run has it.
struct MessageBubble: Shape {
    var mine: Bool
    var tail = true
    /// How far the tail has grown, its room with it: the flying words'
    /// bubble grows its tail as its ink comes in (FlyingWords).
    var grown: CGFloat = 1

    private typealias C = Metrics.Chat

    func path(in rect: CGRect) -> Path {
        let width = rect.width, height = rect.height
        let edge = width
        var path = Path(roundedRect: CGRect(x: 0, y: 0, width: edge, height: height),
                        cornerRadius: min(C.bubbleRadius, height / 2), style: .continuous)
        if tail, grown > 0 {
            // The hook from the body's foot corner, curling down to a point
            // `tailDrop` under it and just inside its edge, grown out of it.
            let drop = C.tailDrop
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: edge + x * grown, y: height + y * grown) }
            var hook = Path()
            hook.move(to: at(-22, -2))
            hook.addCurve(to: at(-1, drop), control1: at(-13, 1.5), control2: at(-6, drop))
            hook.addCurve(to: at(-2.5, -12), control1: at(-1.5, drop - 6), control2: at(-2.5, -5))
            hook.closeSubpath()
            path = path.union(hook)
        }
        let turned = mine ? CGAffineTransform.identity : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        return path.applying(turned.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// Words still being written come in as ink soaking in (the Mac's
/// FreshText): each new stretch at a third, a step darker when the next
/// comes, then in full, so the newest words are always the lightest. The
/// steps ride the answer's own updates, so the fade costs no frame of its
/// own; when the words stop coming, one more draw sets them in full. The
/// ink is the words' own color per run, no renderer of its own.
struct FreshWords: View {
    let rich: AttributedString
    @State private var seen = Seen()
    @State private var rested = 0

    /// What was drawn: how many characters, and where the two newest
    /// stretches begin.
    final class Seen {
        var count = 0
        var newer = 0
        var newest = 0
        var rest: Task<Void, Never>?

        /// The words now `count` long: the newest stretch a step darker,
        /// the rest behind it in full. False when nothing came.
        @discardableResult func advance(to count: Int) -> Bool {
            guard count != self.count else { return false }
            if count < self.count {
                // Words held back (a mark not closed yet): nothing fresh past them.
                newer = min(newer, count)
                newest = min(newest, count)
            } else {
                newer = newest
                newest = self.count
            }
            self.count = count
            return true
        }

        /// The words stopped coming: all in full.
        func settle() {
            newer = count
            newest = count
        }
    }

    var body: some View {
        let count = rich.characters.count
        let seen = seen
        if seen.advance(to: count) {
            seen.rest?.cancel()
            let rested = rested
            seen.rest = Task { @MainActor in
                try? await Task.sleep(for: .seconds(Motion.freshSettle))
                guard !Task.isCancelled else { return }
                seen.settle()
                self.rested = rested + 1
            }
        }
        guard !Motion.disabled, !Motion.reduced, seen.newer < count else { return Text(rich) }
        var inked = rich
        let newer = inked.characters.index(inked.startIndex, offsetBy: seen.newer)
        let newest = inked.characters.index(inked.startIndex, offsetBy: max(seen.newer, seen.newest))
        FreshWords.ink(&inked, newer..<newest, ChatInk.fresher)
        FreshWords.ink(&inked, newest..<inked.endIndex, ChatInk.freshest)
        return Text(inked)
    }

    /// Words at part of their ink; a link keeps its own.
    private static func ink(_ text: inout AttributedString, _ range: Range<AttributedString.Index>, _ ink: Color) {
        guard !range.isEmpty else { return }
        for run in text[range].runs where run.link == nil {
            text[run.range].foregroundColor = ink
        }
    }
}

/// Words written out as they would have streamed (the Mac's WriteOut). An
/// answer often comes in one lump: from the Mac, a sync record holds a
/// stretch of it at once, and this iPhone's own model hands it over whole.
/// A lump is written out a few words at a time, twelve times a second, as
/// fast as it takes to be done in a second or so (never slower than 240
/// characters a second); words that come a few at a time show as they come.
struct WriteOut: Equatable {
    /// Characters shown as this stretch began, and once it is written.
    var from: Int
    var to: Int
    var start: Date
    /// Characters a second.
    var pace: Double

    /// More than this at once is a lump.
    static let lump = 40
    /// How often it writes more.
    static let tick: TimeInterval = 1.0 / 12

    init(from: Int, to: Int, start: Date) {
        self.from = from
        self.to = to
        self.start = start
        let length = Double(max(0, to - from))
        pace = max(240, length / min(1.4, max(0.5, length / 500)))
    }

    var end: Date { start.addingTimeInterval(Double(max(0, to - from)) / pace) }

    /// How many characters are written by `now`.
    func count(at now: Date) -> Int {
        min(to, from + Int(pace * max(0, now.timeIntervalSince(start))))
    }

    /// Where the words written stop: `count` characters in, carried on to
    /// the end of the word, so a word comes whole.
    static func stop(_ text: String, at count: Int) -> String.Index {
        guard let at = text.index(text.startIndex, offsetBy: max(0, count), limitedBy: text.endIndex) else { return text.endIndex }
        return text[at...].firstIndex(where: \.isWhitespace) ?? text.endIndex
    }
}

/// How an answer's words and the typing bubble come and go (the Mac's
/// ChatArrival). Each animates on its own as it is put in or taken out:
/// synced words change with no animation of their own.
@MainActor
enum ChatArrival {
    private typealias C = Metrics.Chat

    /// The first words grow out of the typing bubble's corner, 8 lower and
    /// a little smaller. Gone, they go at once.
    static var message: AnyTransition {
        guard !Motion.disabled else { return .identity }
        let grow: AnyTransition = Motion.reduced ? .opacity
            : .opacity.combined(with: .offset(y: C.arrivalRise)).combined(with: .scale(scale: C.arrivalScale, anchor: .bottomLeading))
        return .asymmetric(insertion: grow.animation(Motion.chatMessageIn.current), removal: .identity)
    }

    /// The typing bubble out of its corner, and back into it, quicker.
    static var typing: AnyTransition {
        guard !Motion.disabled else { return .identity }
        let grow: AnyTransition = Motion.reduced ? .opacity
            : .opacity.combined(with: .scale(scale: C.typingScale, anchor: .bottomLeading))
        return .asymmetric(insertion: grow.animation(Motion.typingIn.current), removal: grow.animation(Motion.typingOut.current))
    }
}
