import SwiftUI

/// Every shape the one chat sheet takes, as numbers that animate together
/// (the prototype's aiT, aiP, aiO, aiR, aiK, aiE and the answer's height).
/// Each moves under its own Motion; SwiftUI adds the springs up.
struct SheetPose: Equatable, Sendable {
    /// 0 an answer at its own height, 1 a chat at full height.
    var t: Double = 0
    /// 0 out, 1 folded into the Now line.
    var p: Double = 0
    /// 1 still the shape it grows from (the field, a button, the Now line).
    var o: Double = 0
    /// The keyboard's height under it, in points.
    var k: Double = 0
    /// 1 below the screen.
    var e: Double = 0
    /// The answer's height, before it is a chat.
    var h: Double = 343
    /// A finger pulling it down, in points.
    var drag: Double = 0

    static let gone = SheetPose(e: 1)
}

extension SheetPose: VectorArithmetic {
    static var zero: SheetPose { SheetPose(t: 0, p: 0, o: 0, k: 0, e: 0, h: 0, drag: 0) }

    static func + (a: SheetPose, b: SheetPose) -> SheetPose {
        SheetPose(t: a.t + b.t, p: a.p + b.p, o: a.o + b.o, k: a.k + b.k, e: a.e + b.e, h: a.h + b.h, drag: a.drag + b.drag)
    }

    static func - (a: SheetPose, b: SheetPose) -> SheetPose {
        SheetPose(t: a.t - b.t, p: a.p - b.p, o: a.o - b.o, k: a.k - b.k, e: a.e - b.e, h: a.h - b.h, drag: a.drag - b.drag)
    }

    mutating func scale(by rhs: Double) {
        t *= rhs; p *= rhs; o *= rhs; k *= rhs; e *= rhs; h *= rhs; drag *= rhs
    }

    var magnitudeSquared: Double {
        t * t + p * p + o * o + (k / 300) * (k / 300) + e * e + (h / 300) * (h / 300) + (drag / 300) * (drag / 300)
    }
}

/// A rounded rect on screen: top corners and bottom corners may differ.
struct SheetShape: Equatable {
    var rect: CGRect
    var top: CGFloat
    var bottom: CGFloat

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom, bottomTrailingRadius: bottom,
                               topTrailingRadius: top, style: .continuous)
    }
}

/// Where the sheet stands for a pose, the prototype's layoutAI() on a
/// screen of any size: an answer 8 from the edges at its own height, a chat
/// from 60 to the bottom edge to edge, its bottom riding on the keyboard;
/// folding into the Now line, growing out of what summoned it.
struct SheetGeometry {
    let screen: CGSize
    var pose: SheetPose
    /// What it grows out of (o), and the Now line it folds into (p).
    var origin: SheetShape?
    var now: SheetShape
    /// Reduce Motion: nothing morphs; the sheet cross-fades where it rests.
    var still = false
    /// Ordinary chats use the final content-sized tray. Answers and task
    /// panels keep their existing geometry.
    var tray = false
    /// The chat as a page in its own full-screen cover (ChatPageCover): no
    /// pose of its own; UIKit's zoom moves the whole page.
    var cover = false
    /// A full chat is a plain page, including its keyboard extension.
    var isPage: Bool { tray && pose.t >= 0.999 }

    /// A chat standing as a page in its cover: full height, edge to edge, its
    /// foot on the keyboard, nothing else of the pose.
    static func page(screen: CGSize, keyboard: Double) -> SheetGeometry {
        SheetGeometry(screen: screen, pose: SheetPose(t: 1, k: keyboard), origin: nil,
                      now: nowShape(screen: screen), tray: true, cover: true)
    }
    /// A conversation: one opaque surface from the first frame (glass is
    /// left to answers).
    var opaque: Bool { tray || column }
    var info = false
    /// A wide workspace gives the same answer a full-height bounded column.
    var column = false

    private typealias S = Metrics.Sheet

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    static func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }

    /// The Now line's place, where a hidden sheet waits (NOW_RECT).
    static func nowShape(screen: CGSize, folded: Bool = false) -> SheetShape {
        let rect = ChromeGeometry(size: screen, folded: folded, hasNow: true).now
        return SheetShape(rect: rect, top: rect.height / 2, bottom: rect.height / 2)
    }

    /// At rest: the answer or the chat, as t, the keyboard and the answer's
    /// height say.
    var rest: SheetShape {
        if column {
            let top = Metrics.statusBar
            return SheetShape(rect: CGRect(x: 0, y: top, width: screen.width,
                                          height: max(0, screen.height - top - CGFloat(pose.k))), top: 0, bottom: 0)
        }
        let t = pose.t
        if tray {
            let side = Self.lerp(Metrics.Edge.sheet, 0, t)
            let keyboard = max(0, CGFloat(pose.k))
            let height = min(CGFloat(pose.h), max(0, screen.height - S.fullTop - Metrics.Edge.sheet - keyboard))
            let top = Self.lerp(screen.height - Metrics.Edge.sheet - height - keyboard, 0, t)
            let bottom = keyboard + Self.lerp(Metrics.Edge.sheet, 0, t)
            let rect = CGRect(x: side, y: top, width: screen.width - side * 2,
                              height: max(0, screen.height - top - bottom))
            let radius = Self.lerp(S.radius, 0, t)
            return SheetShape(rect: rect, top: radius, bottom: radius)
        }
        let side = Self.lerp(Metrics.Edge.sheet, 0, t)
        let top = Self.lerp(screen.height - Metrics.Edge.sheet - CGFloat(pose.h), S.fullTop, t)
        let bottom = max(Self.lerp(Metrics.Edge.sheet, 0, t), CGFloat(pose.k))
        let rect = CGRect(x: side, y: top, width: screen.width - side * 2, height: max(0, screen.height - top - bottom))
        return SheetShape(rect: rect, top: S.radius, bottom: Self.lerp(S.radius, 0, t))
    }

    /// Where it is now: at rest, then pulled toward the Now line (p) and the
    /// shape it grows from (o), then down by a finger and off the screen (e).
    /// The sheet's words are laid out in this frame, as the prototype's card
    /// fills its sheet: the head rides its top, the foot its bottom.
    var current: SheetShape {
        var s = rest
        func toward(_ to: SheetShape, _ k: Double) {
            guard k > 0 else { return }
            let a = s.rect, b = to.rect
            s.rect = CGRect(x: Self.lerp(a.minX, b.minX, k), y: Self.lerp(a.minY, b.minY, k),
                            width: Self.lerp(a.width, b.width, k), height: Self.lerp(a.height, b.height, k))
            s.top = Self.lerp(s.top, to.top, k)
            s.bottom = Self.lerp(s.bottom, to.bottom, k)
        }
        if !still {
            toward(now, pose.p)
            if let origin { toward(origin, pose.o) }
        }
        s.rect.origin.y += shift(from: s.rect.minY)
        return s
    }

    /// How far a finger and the way off screen move it down from `top`.
    private func shift(from top: CGFloat) -> CGFloat {
        CGFloat(pose.e) * (screen.height - top + 24) + CGFloat(max(0, pose.drag))
    }

    /// The sheet's words: gone before the shape is narrow, back once it has
    /// grown enough to hold them.
    var words: Double {
        if still { return 1 }
        var w = 1.0
        if pose.p > 0 { w = min(w, Self.clamp(1 - pose.p * 2.4)) }
        if pose.o > 0 {
            w = min(w, Self.clamp((0.62 - pose.o) / 0.5))
        }
        return w
    }

    /// The last stretch into the Now line is a cross-fade: the sheet goes as
    /// the line comes, no empty frame.
    var sheetOpacity: Double {
        if still { return Self.clamp(1 - max(pose.p, pose.o)) }
        return pose.p > 0.55 ? Self.clamp(1 - (pose.p - 0.55) / 0.45) : 1
    }
    var nowOpacity: Double { still ? Self.clamp(pose.p) : Self.clamp((pose.p - 0.4) / 0.45) }
    /// Its white thins as it becomes the line.
    var background: Double { pose.p > 0.6 ? Double(Self.lerp(0.97, 0.78, (pose.p - 0.6) / 0.4)) : 0.97 }

    /// The head: 50 for an answer, 92 for a chat; one fades out, the other in.
    var headHeight: CGFloat {
        tray ? (info ? Metrics.Chats.infoHeader : Metrics.Chats.conversationHeader)
                + Metrics.Chats.trayFullHeaderTop * CGFloat(pose.t)
             : Self.lerp(Metrics.Chat.answerHead, Metrics.Chat.chatHead, pose.t)
    }
    var answerHeadOpacity: Double { Self.clamp(1 - pose.t * 2.2) }

    /// The inner gutter keeps words 20 from the screen at any inset: the
    /// prototype's --gx, from where the sheet is now. A conversation keeps
    /// Messages' 16 instead: its bubbles' outer edge on the line of the
    /// head's buttons.
    var gutter: CGFloat { tray ? Self.trayGutter(current.rect, screen: screen) : Self.gutter(current.rect, screen: screen) }
    /// The same where it rests: an answer's height is measured there.
    var restGutter: CGFloat { tray ? Self.trayGutter(rest.rect, screen: screen) : Self.gutter(rest.rect, screen: screen) }

    static func gutter(_ rect: CGRect, screen: CGSize) -> CGFloat {
        max(Metrics.Edge.gutter, Metrics.Edge.content - min(rect.minX, screen.width - rect.maxX))
    }

    static func trayGutter(_ rect: CGRect, screen: CGSize) -> CGFloat {
        max(Metrics.Edge.sheet, Metrics.Chats.trayEdge - min(rect.minX, screen.width - rect.maxX))
    }

    /// The turns' width where the sheet rests.
    var restTurnsWidth: CGFloat { max(0, rest.rect.width - restGutter * 2) }

    /// The sheet goes on behind the keyboard, as tall as it is: iOS's
    /// keyboard is translucent, and nothing of the page or its chrome may
    /// show through it under a chat. Gone as the sheet leaves its rest.
    var underKeyboard: CGFloat {
        still ? CGFloat(pose.k) : CGFloat(pose.k * (1 - pose.p) * (1 - pose.o))
    }

    /// The page behind steps back as the chat stands up.
    var recede: Double { pose.t * (1 - pose.p) * (1 - pose.e) }
    /// The page behind is dimmed 18 %, more as the sheet stands up.
    var scrim: Double {
        Double(Self.lerp(0.18, 0.32, pose.t)) * (1 - pose.p) * (1 - pose.e)
    }
}
