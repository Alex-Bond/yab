import AppKit
import QuartzCore
import WebKit

// Who cuts the page card's rounded edge (docs/page-corners.md).
//
// The rule: one layer, the page's stage, cuts the card's outer edge, in
// every state, on one curve (`Reshape.outline`). Anything else cut on the
// same curve, a clip round the stage, a ground under it, a container
// clipping the card, multiplies its soft pixels with the page's, and what
// lies beneath shows through as an arc round each corner, worst in the
// dark. It was mended five times, one layer for one case each time, while
// new features added cuts; this is the check that keeps it mended: the
// `corners` bench verb and PageCornersTests walk every layer from the page
// up to the window and count the cuts that lie on its edge.

@MainActor
enum PageCorners {
    /// A cut found on the card's edge: which layer, and how it cuts.
    struct Cut: Equatable {
        /// "stage" for the stage's own layer, "page" for the page's,
        /// otherwise the layer's class (and name, if it has one).
        let layer: String
        /// "mask" (a shape mask on the outline), "radius" (a corner radius
        /// that clips), or "rect" (a square clip off whole pixels).
        let kind: String
        let isStage: Bool
    }

    /// How close, in points, an outline must be to the card's edge to lie
    /// on it. The hairline's outer edge, a point out, does not.
    static let near: CGFloat = 0.5

    /// The card's edge, in the root layer's coordinates: where the held
    /// page's mask has its outline (the room a preview made, a held page's
    /// new outline), or the stage's bounds.
    static func edge(of stage: StageView) -> CGRect? {
        guard let layer = stage.layer, let root = root(of: layer) else { return nil }
        if stage.isHeld, let mask = stage.cuttingMask, let path = mask.path, !path.boundingBox.isNull {
            return mask.convert(path.boundingBox, to: root)
        }
        return layer.convert(layer.bounds, to: root)
    }

    /// Every cut on the edge of the card `stage` shows, from its page up to
    /// the window's root layer.
    static func cuts(on stage: StageView) -> [Cut] {
        guard let stageLayer = stage.layer, let root = root(of: stageLayer), let edge = edge(of: stage) else { return [] }
        // The page itself, with what it may still carry from a floating
        // window or a peek, then the stage, then everything over it.
        var chain: [CALayer] = stage.subviews.compactMap(\.layer)
        var walk: CALayer? = stageLayer
        while let layer = walk {
            chain.append(layer)
            walk = layer.superlayer
        }
        var found: [Cut] = []
        for layer in chain {
            let isStage = layer === stageLayer
            let who = isStage ? "stage" : stage.subviews.contains(where: { $0.layer === layer }) ? "page" : describe(layer)
            if let kind = cut(by: layer, on: edge, root: root) {
                found.append(Cut(layer: who, kind: kind, isStage: isStage))
            }
        }
        return found
    }

    /// How `layer` cuts what it holds on the edge, if it does.
    private static func cut(by layer: CALayer, on edge: CGRect, root: CALayer) -> String? {
        if let mask = layer.mask {
            if let shape = mask as? CAShapeLayer, let path = shape.path {
                let box = shape.convert(path.boundingBox, to: root)
                if lies(box, on: edge) { return curved(path) ? "mask" : aligned(box, layer) ? nil : "rect" }
            } else if lies(mask.convert(mask.bounds, to: root), on: edge), mask.cornerRadius > 0 {
                return "mask"
            }
        }
        guard layer.masksToBounds else { return nil }
        let box = layer.convert(layer.bounds, to: root)
        guard lies(box, on: edge) else { return nil }
        if layer.cornerRadius > 0 { return "radius" }
        return aligned(box, layer) ? nil : "rect"
    }

    /// Whether a rectangle lies on the card's edge: every side within
    /// `near` of it.
    private static func lies(_ box: CGRect, on edge: CGRect) -> Bool {
        let sides = [abs(box.minX - edge.minX), abs(box.maxX - edge.maxX), abs(box.minY - edge.minY), abs(box.maxY - edge.maxY)]
        return sides.allSatisfy { $0 <= near }
    }

    /// A square clip on whole pixels cuts nothing soft.
    private static func aligned(_ box: CGRect, _ layer: CALayer) -> Bool {
        let scale = max(layer.contentsScale, 1)
        return [box.minX, box.maxX, box.minY, box.maxY].allSatisfy { abs(($0 * scale).rounded() - $0 * scale) < 0.01 }
    }

    /// Whether a path has a curve in it: a rounded outline, not a square.
    private static func curved(_ path: CGPath) -> Bool {
        var curve = false
        path.applyWithBlock { element in
            switch element.pointee.type {
            case .addCurveToPoint, .addQuadCurveToPoint: curve = true
            default: break
            }
        }
        return curve
    }

    private static func root(of layer: CALayer) -> CALayer? {
        var top = layer
        while let up = top.superlayer { top = up }
        return top
    }

    private static func describe(_ layer: CALayer) -> String {
        let kind = String(describing: type(of: layer))
        if let view = layer.delegate as? NSView { return String(describing: type(of: view)) + "/" + kind }
        return layer.name.map { kind + " " + $0 } ?? kind
    }

    /// Whether the cuts are as the rule has them: the stage alone on a
    /// rounded card or a held page, nothing soft edge to edge, and nothing
    /// of the page's under SwiftUI's own cover, which then owns the edge.
    /// Square cuts off whole pixels ("rect") are reported but not counted:
    /// they soften no corner.
    static func verdict(_ stage: StageView, _ cuts: [Cut]) -> (ok: Bool, why: String) {
        let round = cuts.filter { $0.kind != "rect" }
        let named = round.map { "\($0.layer) (\($0.kind))" }.joined(separator: ", ")
        if stage.isCovered, stage.corner > 0, !stage.isHeld {
            return round.isEmpty ? (true, "covered: the cover owns the edge") : (false, "covered, yet cut on the edge by " + named)
        }
        if stage.corner > 0 || stage.isHeld {
            guard round.count == 1, let only = round.first, only.isStage, only.kind == (stage.isHeld ? "mask" : "radius") else {
                return (false, round.isEmpty ? "nothing cuts the edge" : "\(round.count) cuts: " + named)
            }
            return (true, stage.isHeld ? "one owner: the stage's mask" : "one owner: the stage's corner")
        }
        return round.isEmpty ? (true, "square, edge to edge") : (false, "round cuts edge to edge: " + named)
    }

    /// The paper under the card `stage` shows, found by where it lies: a
    /// point bigger than the card all round.
    static func paper(for stage: StageView) -> PaperView? {
        guard let window = stage.window, let content = window.contentView else { return nil }
        let frame = stage.convert(stage.bounds, to: nil)
        var queue: [NSView] = [content]
        var best: (PaperView, CGFloat)?
        while let view = queue.popLast() {
            if let paper = view as? PaperView {
                let around = paper.convert(paper.bounds, to: nil).insetBy(dx: 1, dy: 1)
                // The card is the page and its address bar: the same sides
                // and foot as the page.
                let off = max(abs(around.minX - frame.minX), abs(around.maxX - frame.maxX), abs(around.minY - frame.minY))
                if off < 2, best.map({ off < $0.1 }) ?? true { best = (paper, off) }
                continue
            }
            if view is WKWebView { continue }
            queue.append(contentsOf: view.subviews)
        }
        return best?.0
    }

    /// Every stage in `window`, with its cuts and its paper, for the bench.
    static func report(in window: NSWindow?) -> [String: Any] {
        guard let content = window?.contentView else { return ["ok": false, "why": "no window"] }
        var stages: [StageView] = []
        var queue: [NSView] = [content]
        while let view = queue.popLast() {
            if let stage = view as? StageView { stages.append(stage); continue }
            if view is WKWebView { continue }
            queue.append(contentsOf: view.subviews)
        }
        var rows: [[String: Any]] = []
        var ok = true
        for stage in stages where stage.window != nil && !stage.isHiddenOrHasHiddenAncestor {
            let cuts = cuts(on: stage)
            var (fine, why) = verdict(stage, cuts)
            var row: [String: Any] = [
                "tab": stage.shows.map { String($0.uuidString.prefix(8)).lowercased() } ?? "",
                "corner": Double(stage.corner), "held": stage.isHeld, "previewing": stage.previewing != nil,
                "covered": stage.isCovered, "frame": rect(stage.convert(stage.bounds, to: nil)),
                "cuts": cuts.map { ["layer": $0.layer, "kind": $0.kind, "stage": $0.isStage] },
            ]
            // The page in it, in the window: a size off the stage's shows
            // through as a strip of whatever lies under it (#215).
            if let page = stage.subviews.first(where: { $0 is WKWebView }) {
                row["page"] = rect(page.convert(page.bounds, to: nil))
                row["pageLayer"] = page.layer.map { [Double($0.bounds.width), Double($0.bounds.height)] } ?? []
            }
            if let paper = paper(for: stage) {
                let audit = paper.audit
                row["paper"] = audit
                if audit["groundClear"] as? Bool != true || audit["shadowCut"] as? Bool != true || audit["hairlineOutside"] as? Bool != true {
                    fine = false
                    why += "; the paper lies on the edge"
                }
            }
            row["ok"] = fine
            row["why"] = why
            ok = ok && fine
            rows.append(row)
        }
        return ["ok": ok && !rows.isEmpty, "stages": rows, "cards": cards(in: window),
                "window": window?.windowNumber ?? 0, "size": [Double(window?.frame.width ?? 0), Double(window?.frame.height ?? 0)]]
    }

    private static func rect(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }

    /// Every card's outline as drawn in `window`, band and page, from the
    /// top left of the window in points, for the pixel check: each paper's
    /// card (a page's, the page under ⌘T's field, the developer tools').
    static func cards(in window: NSWindow?) -> [[String: Any]] {
        guard let window, let content = window.contentView else { return [] }
        var found: [[String: Any]] = []
        var queue: [NSView] = [content]
        while let view = queue.popLast() {
            if let paper = view as? PaperView {
                if paper.window != nil, !paper.isHiddenOrHasHiddenAncestor, let card = paper.cardOutline {
                    let points = flatten(card.path, from: card.layer, in: window)
                    if !points.isEmpty { found.append(["outline": points, "paper": paper.audit]) }
                }
                continue
            }
            if view is WKWebView { continue }
            queue.append(contentsOf: view.subviews)
        }
        return found
    }

    /// A path in `layer`'s coordinates as points along it, its curves cut
    /// into short lines, in the window from its top left, through every
    /// transform on the way (a card receding under a Peek).
    static func flatten(_ path: CGPath, from layer: CALayer, in window: NSWindow) -> [[Double]] {
        guard let content = window.contentView, let contentLayer = content.layer else { return [] }
        let height = window.frame.height
        func place(_ p: CGPoint) -> [Double] {
            let there = content.convert(content.convertFromLayer(layer.convert(p, to: contentLayer)), to: nil)
            return [Double(there.x), Double(height - there.y)]
        }
        var points: [[Double]] = []
        var last = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                last = e.points[0]; start = last
                points.append(place(last))
            case .addLineToPoint:
                let to = e.points[0]
                for i in 1...8 { let t = CGFloat(i) / 8; points.append(place(CGPoint(x: last.x + (to.x - last.x) * t, y: last.y + (to.y - last.y) * t))) }
                last = to
            case .addQuadCurveToPoint:
                let c = e.points[0], to = e.points[1]
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    points.append(place(CGPoint(x: u * u * last.x + 2 * u * t * c.x + t * t * to.x,
                                                y: u * u * last.y + 2 * u * t * c.y + t * t * to.y)))
                }
                last = to
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], to = e.points[2]
                for i in 1...16 {
                    let t = CGFloat(i) / 16, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    points.append(place(CGPoint(x: a * last.x + b * c1.x + c * c2.x + d * to.x,
                                                y: a * last.y + b * c1.y + c * c2.y + d * to.y)))
                }
                last = to
            case .closeSubpath:
                points.append(place(start))
                last = start
            @unknown default:
                break
            }
        }
        return points
    }
}
