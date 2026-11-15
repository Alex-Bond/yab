import AppKit
import ImageIO
import SwiftUI

// The divider under the hand, moved by Core Animation alone.
//
// Moved by SwiftUI, every move of the mouse laid the halves' room out
// again, both bands, both pages' stages, everything hung over them: some
// 2 ms of the main thread a move (./bench pace split-drag). Here SwiftUI
// is left where it was when the divider was taken, and what the hand
// changes is drawn over it on layers of its own: each band as a picture
// taken once, cut in three, its doors at its two ends and its site in the
// middle of it, laid out on every move as BandLayout lays them; the ground
// between and around them; the outline of the half in front; the grip.
// The pages are held and cut to their halves by their stages, and the
// cards' paper by theirs (StageView.preview, PaperView.preview). Let go, the share is set once, SwiftUI
// lays the room out where the layers already are, and they are taken away
// a frame after that is drawn.

@MainActor
final class SplitRule {
    static let shared = SplitRule()

    /// Off only to measure what it saves (`split.rule` = off, a test world).
    static var enabled = !(Store.testing && Store.settings.string(forKey: "split.rule") == "off")

    /// Each half's page and paper, found once when the divider is taken:
    /// the stage cuts the held page to the half and carries it there, the
    /// paper draws the card there (StageView.preview, PaperView.preview),
    /// each set on every move with nothing animated.
    private struct Page {
        let stage: StageView
        let paper: PaperView?
        /// The page's own top and height in the window, from its bottom,
        /// and the card's: the divider moves neither.
        let page: (y: CGFloat, height: CGFloat)
        let card: (y: CGFloat, height: CGFloat)
    }
    private var pages: [Tab.ID: Page] = [:]

    private struct Band {
        let id: Tab.ID
        let layer = CALayer()
        let lead = CALayer()
        let site = CALayer()
        let trail = CALayer()
        var parts: BandLayout.Parts
        /// Where the site ends in the picture, as a share of its width.
        var siteEnd: CGFloat = 0
        var siteStart: CGFloat = 0
    }

    /// Up while the divider is in the hand.
    private var sky: Sky?
    /// The view the layers are drawn in, kept over the window once made:
    /// a view put into the window's frame is a change for the window
    /// server, and made anew on each take it held that first frame up to
    /// 180 ms on a busy Mac. Put away, it is only hidden.
    private var kept: Sky?
    private var bands: [Band] = []
    private let ground = CALayer()
    private let ring = CAShapeLayer()
    private let grip = CALayer()
    private var room: CGRect = .zero
    private var bar: CGFloat = 0
    private var corner: CGFloat = 0
    private var front: Tab.ID?
    private var pair: Pair?

    var active: Bool { sky != nil }

    /// Where the bands' parts are, for the bench.
    var report: [String] {
        ["moves \(moves) began \(began)"] + pages.map { id, page in
            let st = page.stage
            let t = st.layer?.sublayerTransform
            return "page \(id.uuidString.prefix(4)) frame \(st.convert(st.bounds, to: nil)) shift \(t?.m41 ?? 0),\(t?.m42 ?? 0) mask \((st.layer?.mask as? CAShapeLayer)?.path?.boundingBox ?? .zero) webframe \(st.subviews.first?.frame ?? .zero) paper \(page.paper != nil)"
        } + bands.map { band in
            "\(band.parts) site \(band.site.frame) rect \(band.site.contentsRect) lead \(band.lead.frame) \(band.lead.contentsRect)"
        }
    }

    /// The divider taken: the bands pictured and the layers put over them.
    /// False when it can't be done this way, and SwiftUI moves it.
    /// How long the last begin took, its picture and its walk, in ms, for the bench.
    var began: (picture: Double, total: Double) = (0, 0)

    func begin(_ browser: Browser) -> Bool {
        let t0 = CACurrentMediaTime()
        guard Self.enabled, sky == nil, let pair = browser.stagePair, browser.splitShown,
              let window = Links.window, let content = window.contentView, let root = content.layer,
              browser.splitBook.bar > 0 else { return false }
        let room = browser.splitBook.place
        let halves = [pair.first, pair.second]
        guard room.width > 0, let (leftHalf, rightHalf) = browser.halves(),
              let leftParts = BandLayout.parts(of: pair.first, width: leftHalf.width),
              let rightParts = BandLayout.parts(of: pair.second, width: rightHalf.width) else { return false }
        self.room = room
        self.pair = pair
        bar = browser.splitBook.bar
        corner = browser.splitBook.corner
        front = browser.activeID
        let scale = window.backingScaleFactor
        // One picture of the band row, both bands and the gap between, from
        // the window's own layers: the web pages aren't in it, the bands
        // are drawn by SwiftUI in this process.
        let strip = CGRect(x: room.minX, y: room.minY, width: room.width, height: bar)
        guard let picture = Self.picture(of: root, in: content, rect: strip, scale: scale) else { return false }
        let t1 = CACurrentMediaTime()
        if Store.testing, let path = ProcessInfo.processInfo.environment["YAB_RULE_PICTURE"],
           let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, picture, nil)
            CGImageDestinationFinalize(dest)
        }

        guard let found = Self.pages(for: [pair.first, pair.second], in: content) else { return false }
        pages = found

        var top: NSView = content
        while let up = top.superview { top = up }
        let sky: Sky
        if let kept, kept.superview === top {
            sky = kept
            // Still the topmost, over anything put in the frame since.
            if top.subviews.last !== sky { top.addSubview(sky, positioned: .above, relativeTo: nil) }
        } else {
            kept?.removeFromSuperview()
            sky = Sky(frame: top.convert(content.bounds, from: content))
            sky.autoresizingMask = [.width, .height]
            top.addSubview(sky, positioned: .above, relativeTo: nil)
            kept = sky
        }
        self.sky = sky
        guard let layer = sky.layer else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.isHidden = false
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The ground the band row stands on, the color between the two
        // cards, so a band made narrower uncovers what lies beside it.
        ground.frame = strip
        ground.backgroundColor = Self.color(in: picture, at: CGPoint(x: (browser.halves()?.left.maxX ?? room.midX) + Pair.gap / 2 - room.minX, y: bar / 2), scale: scale)
        layer.addSublayer(ground)
        let left = browser.halves()?.left ?? room
        bands = []
        for (index, id) in halves.enumerated() {
            let parts = index == 0 ? leftParts : rightParts
            var band = Band(id: id, parts: parts)
            let x0 = (index == 0 ? left.minX : left.maxX + Pair.gap) - room.minX
            let width = index == 0 ? left.width : room.width - left.width - Pair.gap
            let at = { (x: CGFloat, w: CGFloat) in
                CGRect(x: (x0 + x) / room.width, y: 0, width: w / room.width, height: 1)
            }
            // Where the site stood when the picture was taken.
            let placed = BandLayout.site(parts, in: 0, width)
            band.layer.masksToBounds = true
            band.layer.cornerRadius = corner
            band.layer.cornerCurve = .continuous
            band.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            band.layer.backgroundColor = Self.color(in: picture, at: CGPoint(x: x0 + parts.rim + parts.lead + 4, y: 3), scale: scale)
            for (part, rect) in [(band.lead, at(0, parts.rim + parts.lead)),
                                 (band.trail, at(width - parts.rim - parts.trail, parts.rim + parts.trail)),
                                 (band.site, at(placed.mid - placed.width / 2, placed.width))] {
                part.contents = picture
                part.contentsRect = rect
                part.contentsScale = scale
                band.layer.addSublayer(part)
            }
            band.siteEnd = (x0 + placed.mid + placed.width / 2) / room.width
            band.siteStart = (x0 + placed.mid - placed.width / 2) / room.width
            band.lead.bounds.size = CGSize(width: parts.rim + parts.lead, height: bar)
            band.trail.bounds.size = CGSize(width: parts.rim + parts.trail, height: bar)
            band.site.bounds.size = CGSize(width: parts.site, height: bar)
            layer.addSublayer(band.layer)
            bands.append(band)
        }
        ring.fillColor = nil
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = Pair.ring.cgColor
        }
        ring.lineWidth = 1
        layer.addSublayer(ring)
        grip.backgroundColor = Palette.NS.ink.withAlphaComponent(0.5).cgColor
        grip.cornerRadius = 1.5
        grip.bounds = CGRect(x: 0, y: 0, width: 3, height: 28)
        layer.addSublayer(grip)
        CATransaction.commit()
        move(to: pair.share)
        began = ((t1 - t0) * 1000, (CACurrentMediaTime() - t0) * 1000)
        return true
    }

    var moves = 0

    /// The hand moved: everything laid out for this share, without actions.
    func move(to share: CGFloat) {
        guard sky != nil, let pair else { return }
        moves += 1
        let lw = ((room.width - Pair.gap) * share).rounded()
        let left = CGRect(x: room.minX, y: room.minY, width: lw, height: room.height)
        let right = CGRect(x: room.minX + lw + Pair.gap, y: room.minY, width: room.width - lw - Pair.gap, height: room.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for band in bands {
            let half = band.id == pair.first ? left : right
            band.layer.frame = CGRect(x: half.minX, y: half.minY, width: half.width, height: bar)
            let p = band.parts
            band.lead.frame = CGRect(x: 0, y: 0, width: p.rim + p.lead, height: bar)
            band.trail.frame = CGRect(x: half.width - p.rim - p.trail, y: 0, width: p.rim + p.trail, height: bar)
            // As BandLayout places the site.
            let placed = BandLayout.site(p, in: 0, half.width)
            let site = placed.width
            band.site.frame = CGRect(x: placed.mid - site / 2, y: 0, width: site, height: bar)
            // Cut from its front, as the band cuts a long host: the end of
            // it says whose it is. A dev address keeps its server and is
            // cut from its end.
            band.site.contentsRect.origin.x = p.leads ? band.siteStart : band.siteEnd - site / room.width
            band.site.contentsRect.size.width = site / room.width
        }
        if let front {
            let half = front == pair.first ? left : right
            ring.path = Reshape.outline(half.insetBy(dx: -1, dy: -1), corner: corner + 1)
        }
        grip.position = CGPoint(x: left.maxX + Pair.gap / 2, y: room.midY)
        CATransaction.commit()
        // The pages and their cards, in the window's own coordinates, which
        // run up from its bottom; across, the content view's and the
        // window's are the same.
        let linear = CAMediaTimingFunction(name: .linear)
        for (id, half) in [(pair.first, left), (pair.second, right)] {
            guard let page = pages[id] else { continue }
            page.stage.preview(CGRect(x: half.minX, y: page.page.y, width: half.width, height: page.page.height), duration: 0, timing: linear)
            page.paper?.preview(CGRect(x: half.minX, y: page.card.y, width: half.width, height: page.card.height), duration: 0, timing: linear)
        }
    }

    /// The stages showing these tabs and the paper under each, found by
    /// walking the window's views once; nil if one is missing.
    private static func pages(for ids: [Tab.ID], in content: NSView) -> [Tab.ID: Page]? {
        var stages: [Tab.ID: StageView] = [:]
        var papers: [PaperView] = []
        var queue = [content]
        while let view = queue.popLast() {
            if let stage = view as? StageView, let id = stage.shows, ids.contains(id), stage.window != nil { stages[id] = stage }
            if let paper = view as? PaperView, paper.window != nil { papers.append(paper) }
            queue.append(contentsOf: view.subviews)
        }
        var found: [Tab.ID: Page] = [:]
        for id in ids {
            guard let stage = stages[id] else { return nil }
            let frame = stage.convert(stage.bounds, to: nil)
            // The paper round this page: laid out a point bigger than its
            // card all round, and the card as wide as the page.
            let paper = papers.first { paper in
                let around = paper.convert(paper.bounds, to: nil)
                return abs(around.midX - frame.midX) < 2 && abs(around.width - frame.width - 2) < 3
            }
            let card = paper.map { $0.convert($0.bounds, to: nil).insetBy(dx: 1, dy: 1) }
            found[id] = Page(stage: stage, paper: paper, page: (frame.minY, frame.height),
                             card: card.map { ($0.minY, $0.height) } ?? (frame.minY, frame.height))
        }
        return found
    }

    /// Let go, and the room laid out at the share by SwiftUI: the layers
    /// come away a frame after that is on screen, so there is no frame of
    /// the old bands.
    func end() {
        guard let sky else { return }
        self.sky = nil
        bands = []
        pair = nil
        // The pages and cards stay where the last move put them: SwiftUI
        // lays them out there once the share is set, and each lands where
        // it already is (StageView.landPreview).
        pages = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0 / 60) { [weak self] in
            // Taken again meanwhile: it is that take's now.
            guard self?.sky !== sky else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sky.layer?.isHidden = true
            sky.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }
    }

    /// The window's own layers drawn over `rect`, in the content view's
    /// space from its top left, at the screen's scale.
    private static func picture(of root: CALayer, in content: NSView, rect: CGRect, scale: CGFloat) -> CGImage? {
        let width = Int(rect.width * scale), height = Int(rect.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        // A context runs up; the content view runs down.
        if content.isFlipped != root.isGeometryFlipped || content.isFlipped {
            context.translateBy(x: 0, y: rect.height)
            context.scaleBy(x: 1, y: -1)
        }
        context.translateBy(x: -rect.minX, y: -rect.minY)
        root.render(in: context)
        return context.makeImage()
    }

    /// The color of the picture at a point, in points from its top left.
    private static func color(in picture: CGImage, at point: CGPoint, scale: CGFloat) -> CGColor {
        let x = min(max(0, Int(point.x * scale)), picture.width - 1)
        let y = min(max(0, Int(point.y * scale)), picture.height - 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let one = picture.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return NSColor.clear.cgColor }
        context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(srgbRed: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    }

    /// Over the whole window, in SwiftUI's space from the top left; the
    /// hand passes through it to the divider under it.
    private final class Sky: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
