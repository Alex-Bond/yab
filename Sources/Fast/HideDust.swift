import AppKit
import WebKit

// What Hide Elements leaves behind for a second: Safari's dust.
//
// Matched to Safari 26.4's Hide Distracting Items, filmed at 60 fps on the
// same page (evals/safari-hide): the page lets go of the thing at once and
// closes up under it; a grainy, paled picture of it stays over the place,
// crumbles where it stood for about a third of a second, then drifts off to
// the right and a little up, faster and faster, and is gone about a second
// after it came. The picker's outline lingers where it was, drawn here,
// since the page's own has to be gone from the picture.
//
// The grains are drawn off the main thread, each frame one picture on one
// layer over the web view, paced by the view's display link. A layer per
// grain animated by Core Animation held the render server to 30 frames a
// second on adhd (3000 grains, crops or plain colors alike), where a scroll
// ran at 51 and Safari's dust at 50.
@MainActor
enum HideDust {
    /// Takes a picture of what is at `box` (the page's CSS pixels in the
    /// viewport), runs `hide`, and blows the picture away over the page.
    /// Without a box, a window or motion, it only hides.
    static func play(on web: WKWebView?, css box: CGRect?, then hide: @escaping () -> Void) {
        guard let web, let box, web.window != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return hide() }
        let zoom = web.pageZoom * web.magnification
        var spot = CGRect(x: box.minX * zoom, y: box.minY * zoom, width: box.width * zoom, height: box.height * zoom)
        if !web.isFlipped { spot.origin.y = web.bounds.height - spot.maxY }
        spot = spot.intersection(web.bounds).integral
        guard spot.width >= 4, spot.height >= 4 else { return hide() }

        // The outline stays put while the picture is taken and the page
        // closes up, and fades as the dust takes over.
        let cover = Cover(frame: web.bounds)
        cover.autoresizingMask = [.width, .height]
        web.addSubview(cover)
        outline(spot, on: cover)

        // After the page has drawn without the picker's own outline.
        let shot = WKSnapshotConfiguration()
        shot.rect = spot
        shot.afterScreenUpdates = true
        // A picture that takes too long is not worth keeping the thing up for.
        var hidden = false
        let late = DispatchWorkItem { [weak cover] in
            if !hidden { hidden = true; hide() }
            cover?.removeFromSuperview()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: late)
        web.takeSnapshot(with: shot) { [weak web] image, _ in
            guard !hidden else { return }
            hidden = true
            late.cancel()
            hide()
            guard web != nil, let image, let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                cover.removeFromSuperview()
                return
            }
            blow(picture, at: spot, on: cover)
        }
    }

    // MARK: - the grains

    /// No more grains than this, whatever the size of what goes.
    private static let most = 5000.0

    /// Safari's: the picker's outline left where the thing was, no fill.
    private static func outline(_ spot: CGRect, on cover: Cover) {
        let ring = CALayer()
        ring.frame = cover.bounds
        ring.isGeometryFlipped = true
        let line = CALayer()
        line.frame = spot
        line.borderWidth = 2
        line.cornerRadius = 5
        line.borderColor = NSColor.controlAccentColor.cgColor
        line.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.4, 1]
        fade.duration = 0.32
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        line.add(fade, forKey: "fade")
        ring.addSublayer(line)
        cover.layer?.addSublayer(ring)
    }

    private static func blow(_ picture: CGImage, at spot: CGRect, on cover: Cover) {
        guard let paled = pale(picture) else { return cover.removeFromSuperview() }
        // Where the grains can go: right of the thing by up to 320, above
        // it by 110, below by 77, and a grain's width either side.
        let room = CGRect(x: spot.minX - 4, y: spot.minY - 116, width: spot.width + 330, height: spot.height + 200)
            .intersection(cover.bounds)
        guard !room.isEmpty else { return cover.removeFromSuperview() }

        let cell = max(2, (spot.width * spot.height / most).squareRoot())
        let scale = CGFloat(picture.width) / spot.width
        let columns = Int(ceil(spot.width / cell)), rows = Int(ceil(spot.height / cell))
        var grains: [Grain] = []
        grains.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let local = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    .intersection(CGRect(origin: .zero, size: spot.size))
                let pixels = CGRect(x: local.minX * scale, y: local.minY * scale,
                                    width: local.width * scale, height: local.height * scale).integral
                guard let color = paled.color(in: pixels) else { continue }
                let dark = paled.darkness(at: CGPoint(x: pixels.midX, y: pixels.midY)) > 0.65
                // Safari's grains wander a little as soon as they show; each
                // a bit bigger than its cell, so the picture stays whole.
                let x = spot.minX - room.minX + local.midX + .random(in: -0.8...0.8)
                let y = spot.minY - room.minY + local.midY + .random(in: -0.8...0.8)
                let upward = Double.random(in: 0...1) > 0.25
                grains.append(Grain(
                    x: x, y: y,
                    dx: .random(in: 120...320), dy: upward ? -.random(in: 20...110) : .random(in: 14...77),
                    size: cell * 1.4,
                    hold: 0.05 + .random(in: 0...0.2) + (dark ? 0.08 : 0),
                    life: .random(in: 0.6...1.0),
                    // A quarter of the picture thins out before it moves at all.
                    thin: Double.random(in: 0...1) < 0.25,
                    color: color
                ))
            }
        }

        let ground = CALayer()
        ground.frame = cover.bounds
        ground.isGeometryFlipped = true
        ground.masksToBounds = true
        let canvas = CALayer()
        canvas.frame = room
        canvas.contentsScale = cover.window?.backingScaleFactor ?? 2
        ground.addSublayer(canvas)
        cover.layer?.insertSublayer(ground, at: 0)

        let sand = Sand(grains: grains, size: room.size, scale: canvas.contentsScale)
        // The first frame at once, so the picture stands where the thing was.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvas.contents = sand.draw(at: 0)
        CATransaction.commit()
        Blower(sand: sand, canvas: canvas, cover: cover).start()
    }

    private struct Grain {
        let x, y, dx, dy, size: CGFloat
        let hold, life: Double
        let thin: Bool
        let color: (CGFloat, CGFloat, CGFloat, CGFloat)
    }

    /// The grains at a moment, drawn into one picture. Read only once made,
    /// so it is drawn on a queue of its own.
    private final class Sand: @unchecked Sendable {
        let grains: [Grain]
        let size: CGSize
        let scale: CGFloat
        let longest: Double

        init(grains: [Grain], size: CGSize, scale: CGFloat) {
            self.grains = grains
            self.size = size
            self.scale = scale
            longest = grains.map { $0.hold + $0.life }.max() ?? 0
        }

        func draw(at time: Double) -> CGImage? {
            let width = Int(ceil(size.width * scale)), height = Int(ceil(size.height * scale))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            // Top left, in points, as the grains are measured.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            for grain in grains {
                var x = grain.x, y = grain.y, side = grain.size
                var alpha = 0.95
                if time < grain.hold {
                    if grain.thin { alpha -= 0.57 * time / grain.hold }
                } else {
                    let q = (time - grain.hold) / grain.life
                    if q >= 1 { continue }
                    // Off with growing speed: about q squared.
                    let e = CGFloat(q * q)
                    x += grain.dx * e
                    y += grain.dy * e
                    alpha = (grain.thin ? 0.38 : 0.95) * (1 - q * q)
                    side *= 1 - 0.4 * CGFloat(q)
                }
                let (r, g, b, a) = grain.color
                context.setFillColor(red: r, green: g, blue: b, alpha: a * CGFloat(alpha))
                context.fill(CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side))
            }
            return context.makeImage()
        }
    }

    /// Paces the drawing by the display: a frame drawn on its queue while
    /// the last is shown, none queued behind a slow one, and the cover gone
    /// once the last grain is.
    private final class Blower: NSObject {
        let sand: Sand
        let canvas: CALayer
        weak var cover: Cover?
        private let queue = DispatchQueue(label: "dust", qos: .userInteractive)
        private var begun = 0.0
        private var drawing = false
        private var link: CADisplayLink?

        init(sand: Sand, canvas: CALayer, cover: Cover) {
            self.sand = sand
            self.canvas = canvas
            self.cover = cover
        }

        @MainActor
        func start() {
            begun = CACurrentMediaTime()
            link = cover?.displayLink(target: self, selector: #selector(tick))
            link?.add(to: .main, forMode: .common)
            cover?.blower = self
        }

        @MainActor @objc private func tick() {
            let time = CACurrentMediaTime() - begun
            guard cover != nil, time < sand.longest + 0.05 else {
                link?.invalidate()
                link = nil
                cover?.blower = nil
                cover?.removeFromSuperview()
                return
            }
            guard !drawing else { return }
            drawing = true
            let sand = sand, canvas = canvas
            queue.async { [weak self] in
                let picture = sand.draw(at: time)
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    canvas.contents = picture
                    CATransaction.commit()
                    self?.drawing = false
                }
            }
        }
    }

    /// Safari's picture is paler than the thing was, dark parts the most
    /// washed out of all, so it reads as already half gone.
    private static func pale(_ picture: CGImage) -> Paled? {
        let width = picture.width, height = picture.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(picture, in: all)
        guard let raw = context.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var darkness = [Float](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            let p = index * 4
            let r = Float(bytes[p]), g = Float(bytes[p + 1]), b = Float(bytes[p + 2])
            let dark = 1 - (r + g + b) / (3 * 255)
            darkness[index] = dark
            // Toward white: by 30 %, and the darkest by up to 45 %.
            let toward = 0.3 + 0.15 * dark
            let a = Float(bytes[p + 3])
            bytes[p] = UInt8(r + (a - r) * toward)
            bytes[p + 1] = UInt8(g + (a - g) * toward)
            bytes[p + 2] = UInt8(b + (a - b) * toward)
        }
        let pixels = Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
        return Paled(pixels: pixels, width: width, darkness: darkness)
    }

    private struct Paled {
        let pixels: [UInt8]
        let width: Int
        let darkness: [Float]

        var height: Int { darkness.count / width }

        /// The average of a cell, as a blurred picture shows it.
        func color(in cell: CGRect) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
            let x0 = max(Int(cell.minX), 0), x1 = min(Int(cell.maxX), width)
            let y0 = max(Int(cell.minY), 0), y1 = min(Int(cell.maxY), height)
            guard x1 > x0, y1 > y0 else { return nil }
            var sum = [0, 0, 0, 0]
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let p = (y * width + x) * 4
                    for c in 0..<4 { sum[c] += Int(pixels[p + c]) }
                }
            }
            let n = CGFloat((x1 - x0) * (y1 - y0) * 255)
            let alpha = CGFloat(sum[3]) / n
            guard alpha > 0.05 else { return nil }
            // Premultiplied in the picture, plain in the color.
            return (CGFloat(sum[0]) / n / alpha, CGFloat(sum[1]) / n / alpha, CGFloat(sum[2]) / n / alpha, alpha)
        }

        /// 0 white … 1 black, at a pixel counted from the picture's top.
        func darkness(at point: CGPoint) -> Float {
            let x = min(max(Int(point.x), 0), width - 1)
            let y = min(max(Int(point.y), 0), height - 1)
            return darkness[y * width + x]
        }
    }

    /// Over the page, under nothing: the pointer goes straight through.
    private final class Cover: NSView {
        /// Kept by the cover it draws on, for as long as it blows.
        var blower: Blower?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
