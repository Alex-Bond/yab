import AppKit
import Metal
import QuartzCore
import simd
import SwiftUI

// Clear, from the line: today's tabs go to dust, the way Telegram lets a
// deleted message go (Telegram 10.5, 2023-12-31, "Thanos Snap"). Written
// here from how it behaves, not from its code, which is GPL.
//
// At the click the rows going are taken as they are drawn, one grain a
// point, each grain carrying its own pixels, and the rows are hidden in the
// same commit, so for a frame the grains are the rows. They go as a wave,
// top to bottom: each row sets off a moment after the one over it and,
// a beat later, gives up its room, so the rows left and New tab ride up
// behind the dust the whole way rather than waiting and jumping. The dust
// rides up with them, each row's lifted as the rows over it fold.
// In each row a window crosses left to right in 0.8 s and wakes each grain
// as it passes: off in a
// direction of its own at 42 to 84 points a second, pulled up at 120,
// living 0.7 to 1.5 of the effect's seconds, which run twice as fast as
// real ones, fading over its last 0.3. About 1.4 s and it is all gone.
//
// Only a row's ink goes: its title and its mark. The column's ground under
// it is the column's and stays; a row has no card of its own the way a
// message has a bubble.
//
// Where each grain is follows from the time alone (see the shader), so a
// frame is one draw and nothing on the CPU but the time. The frames are
// drawn on a thread of their own, paced by the display, and presented
// without waiting on the window's commits: the rows closing up under the
// dust, a SwiftUI commit, can't hold it back.
//
// Not with Reduce Motion or Low Power Mode on, not while the column is out
// of sight, and not before the shader is ready: then Clear is what it was.

@MainActor
final class Dust {
    static let shared = Dust()

    /// The wave: each row sets off this long after the one over it, and
    /// the last no later than `waveSpan` after the first, however many go.
    nonisolated static let waveStep: TimeInterval = 0.07
    nonisolated static let waveSpan: TimeInterval = 0.42
    /// A row gives up its room this long after its dust sets off, over
    /// `foldTime`, easing in and out: the shader lifts the rows still
    /// waiting on the same curve (inOut there).
    nonisolated static let foldDelay: TimeInterval = 0.1
    nonisolated static let foldTime: TimeInterval = 0.38
    static let fold = Animation.timingCurve(0.65, 0, 0.35, 1, duration: foldTime)
    /// When a row's last grain has faded, after it set off, in real seconds.
    nonisolated static let length: CFTimeInterval = 1.42

    private let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var warming = false
    private var runs: [DustRun] = []
    /// How many times it has played, for the bench to tell it from the
    /// plain way.
    private(set) var played = 0

    var ready: Bool { pipeline != nil }

    /// Whether the dust may be used now at all.
    static var allowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// The shader, built off the main thread, once: asked for when Clear
    /// first shows on the line, well before it can be pressed.
    func warm() {
        guard pipeline == nil, !warming, let device, Dust.allowed else { return }
        warming = true
        device.makeLibrary(source: DustShader.source, options: nil) { library, _ in
            guard let library else { DispatchQueue.main.async { self.warming = false }; return }
            let describe = MTLRenderPipelineDescriptor()
            describe.vertexFunction = library.makeFunction(name: "dustVertex")
            describe.fragmentFunction = library.makeFunction(name: "dustFragment")
            let color = describe.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            device.makeRenderPipelineState(descriptor: describe) { state, _ in
                DispatchQueue.main.async {
                    self.warming = false
                    self.pipeline = state
                    self.queue = state == nil ? nil : device.makeCommandQueue()
                }
            }
        }
    }

    /// The rows, in the host's flipped space, taken to dust over `view`.
    /// False if it can't be done now; nothing has changed then.
    func play(rows: [DustRow], host: NSView, over view: NSView, renaming: Bool = false) -> Bool {
        guard Dust.allowed, let device, let pipeline, let queue, let window = view.window, let root = view.layer else { return false }
        let bounds = host.bounds
        let rows = rows.map { DustRow(rect: $0.rect.intersection(bounds), start: $0.start, fold: $0.fold) }
            .filter { $0.rect.width > 4 && $0.rect.height > 4 }
        guard !rows.isEmpty else { return false }
        let scale = window.backingScaleFactor
        let union = rows.dropFirst().reduce(rows[0].rect) { $0.union($1.rect) }.integral
        guard let shot = Snapshot(host: host, rect: union, rows: rows.map(\.rect), scale: scale) else { return false }
        guard let run = DustRun(device: device, pipeline: pipeline, queue: queue, shot: shot, rows: rows, over: view, root: root, scale: scale, renaming: renaming) else { return false }
        runs.append(run)
        played += 1
        run.start { [weak self, weak run] in
            guard let self, let run else { return }
            self.runs.removeAll { $0 === run }
        }
        return true
    }
}

/// A row going: where it is, when its dust sets off after the first row's,
/// and how much room, its gap with it, it gives up as it goes.
struct DustRow {
    var rect: CGRect
    var start: TimeInterval
    var fold: CGFloat
}

/// The rows as drawn, only their ink kept, and the grains to cut them into.
struct Snapshot {
    /// Where the picture sits, in points of the host's flipped space.
    let rect: CGRect
    let width: Int, height: Int
    /// Premultiplied RGBA, top row first.
    var pixels: [UInt8]
    /// One grain a point with ink under it.
    var grains: [DustGrain]

    init?(host: NSView, rect: CGRect, rows: [CGRect], scale: CGFloat) {
        self.rect = rect
        width = Int((rect.width * scale).rounded())
        height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0, let layer = host.layer else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        // Only the layers of the rows going, each drawn where it is: SwiftUI
        // gives a row's mark, its letter and its title layers of their own.
        // Drawing the column whole, AppKit's cacheDisplay or the host's
        // layer, took 10 to 13 ms of the main thread for the same picture;
        // and the column's ground, a layer of its own too, stays out.
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // The host's space: flipped, y down, as its rows are measured.
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            func draw(_ sub: CALayer, alpha: CGFloat) {
                guard !sub.isHidden, sub.opacity > 0 else { return }
                let frame = sub.convert(sub.bounds, to: layer)
                guard rows.contains(where: { $0.intersects(frame) }) else { return }
                let seen = alpha * CGFloat(sub.opacity)
                // A row's own piece: drawn whole. Anything bigger holds rows
                // and is only gone through.
                if frame.height <= 40, sub !== layer {
                    ctx.saveGState()
                    ctx.translateBy(x: frame.minX, y: frame.minY)
                    ctx.setAlpha(seen)
                    sub.render(in: ctx)
                    ctx.restoreGState()
                    return
                }
                sub.sublayers?.forEach { draw($0, alpha: seen) }
            }
            draw(layer, alpha: 1)
            return true
        }
        guard drawn else { return nil }

        // Only the rows' own layers are drawn, so there is usually nothing
        // under the ink. When a row draws a ground of its own, read where a
        // row never draws, the gap before its mark, it is taken out: what is
        // near it is the ground, what is far is the ink.
        var grains: [DustGrain] = []
        grains.reserveCapacity(Int(rect.width * rect.height) / 3)
        let s = Float(scale)
        let stride = w * 4
        pixels.withUnsafeMutableBufferPointer { p in
            for (number, row) in rows.enumerated() {
                let x0 = max(0, Int(((row.minX - rect.minX) * scale).rounded())), x1 = min(w, Int(((row.maxX - rect.minX) * scale).rounded()))
                let y0 = max(0, Int(((row.minY - rect.minY) * scale).rounded())), y1 = min(h, Int(((row.maxY - rect.minY) * scale).rounded()))
                guard x1 > x0, y1 > y0 else { continue }
                let gi = ((y0 + y1) / 2) * stride + min(x1 - 1, x0 + Int(3 * scale)) * 4
                if p[gi + 3] > 127 {
                    let ga = Float(p[gi + 3])
                    let gr = Float(p[gi]) / ga, gg = Float(p[gi + 1]) / ga, gb = Float(p[gi + 2]) / ga
                    for y in y0..<y1 {
                        var i = y * stride + x0 * 4
                        for _ in x0..<x1 {
                            let a = Float(p[i + 3])
                            if a > 0 {
                                let r = Float(p[i]) / a, g = Float(p[i + 1]) / a, b = Float(p[i + 2]) / a
                                let far = (abs(r - gr) + abs(g - gg) + abs(b - gb)) / 3
                                let ink = min(1, max(0, (far - 0.02) / 0.22)) * a
                                p[i] = UInt8(min(255, r * ink + 0.5)); p[i + 1] = UInt8(min(255, g * ink + 0.5))
                                p[i + 2] = UInt8(min(255, b * ink + 0.5)); p[i + 3] = UInt8(min(255, ink + 0.5))
                            }
                            i += 4
                        }
                    }
                }
                // A grain a point, where the point has any ink.
                let step = max(1, Int(scale.rounded()))
                var index = UInt32(truncatingIfNeeded: grains.count)
                for y in Swift.stride(from: y0, to: y1, by: step) {
                    for x in Swift.stride(from: x0, to: x1, by: step) {
                        index &+= 1
                        var any = false
                        for dy in 0..<min(step, y1 - y) where !any {
                            let r = (y + dy) * stride + x * 4 + 3
                            for dx in 0..<min(step, x1 - x) where p[r + dx * 4] > 2 { any = true; break }
                        }
                        guard any else { continue }
                        grains.append(DustGrain(base: SIMD2(Float(x) / s, Float(y) / s),
                                                fraction: Float(x - x0) / Float(max(1, x1 - x0)),
                                                seed: index &* 2654435761 &+ UInt32(truncatingIfNeeded: y),
                                                row: UInt32(number), pad: 0))
                    }
                }
            }
        }
        guard !grains.isEmpty else { return nil }
        self.pixels = pixels
        self.grains = grains
    }
}

/// One grain: where it starts, in points from the picture's corner, how far
/// across its row it is, what picks its own way, and which row it is of.
struct DustGrain {
    var base: SIMD2<Float>
    var fraction: Float
    var seed: UInt32
    var row: UInt32
    var pad: UInt32
}

/// A row as the shader has it: when it sets off, its top, its room.
struct DustRowUniform {
    var start: Float
    var top: Float
    var fold: Float
    var pad: Float = 0
}

struct DustUniforms {
    var phase: Float
    var cell: Float
    /// The layer's size, and where the picture's corner is in it, points.
    var layerSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var pictureSize: SIMD2<Float>
    var rowCount: UInt32
    var renaming: UInt32
}

/// One tidy-up's dust: its layer, its picture, its grains, its clock.
final class DustRun: NSObject, CAMetalDisplayLinkDelegate {
    private let layer = CAMetalLayer()
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private let texture: MTLTexture
    private let grains: MTLBuffer
    private let rows: MTLBuffer
    private let count: Int
    /// When the last row's last grain has faded.
    private let length: CFTimeInterval
    private var uniforms: DustUniforms
    private var link: CAMetalDisplayLink?
    private var thread: Thread?
    private var begun: CFTimeInterval = 0
    private var finished: (() -> Void)?
    private var deadline: DispatchWorkItem?

    @MainActor
    init?(device: MTLDevice, pipeline: MTLRenderPipelineState, queue: MTLCommandQueue, shot: Snapshot, rows: [DustRow], over view: NSView, root: CALayer, scale: CGFloat, renaming: Bool = false) {
        self.pipeline = pipeline
        self.queue = queue
        let describe = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: shot.width, height: shot.height, mipmapped: false)
        describe.usage = .shaderRead
        describe.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: describe) else { return nil }
        shot.pixels.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, shot.width, shot.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: shot.width * 4) }
        self.texture = texture
        guard let buffer = shot.grains.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        grains = buffer
        count = shot.grains.count
        let lines = rows.map { DustRowUniform(start: Float($0.start), top: Float($0.rect.minY), fold: Float($0.fold)) }
        guard let lined = lines.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        self.rows = lined
        length = (renaming ? Rename.cross : Dust.length) + (rows.map(\.start).max() ?? 0)

        // Over the column only, from well above the rows (the dust rises) to
        // a little under them; the page beside it is left alone.
        let column = CGRect(x: 0, y: 0, width: shot.rect.maxX + 2, height: view.bounds.height)
        let top = max(0, shot.rect.minY - 280), bottom = min(column.height, shot.rect.maxY + 150)
        let frame = CGRect(x: 0, y: top, width: column.width, height: bottom - top)
        uniforms = DustUniforms(phase: 0, cell: 1,
                                layerSize: SIMD2(Float(frame.width), Float(frame.height)),
                                origin: SIMD2(Float(shot.rect.minX - frame.minX), Float(shot.rect.minY - frame.minY)),
                                pictureSize: SIMD2(Float(shot.rect.width), Float(shot.rect.height)),
                                rowCount: UInt32(rows.count), renaming: renaming ? 1 : 0)
        super.init()

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        layer.maximumDrawableCount = 3
        // The column's layer is not flipped: its y runs up.
        let flipped = view.isFlipped
        layer.frame = CGRect(x: frame.minX, y: flipped ? frame.minY : view.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        layer.masksToBounds = true
        layer.zPosition = 10
        layer.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull()]
        root.addSublayer(layer)
    }

    /// The first frame now, in the commit that hides the rows, and the rest
    /// on the display's clock off the main thread, once that commit is done.
    @MainActor
    func start(finished: @escaping () -> Void) {
        self.finished = finished
        // A display link can stop supplying drawables while the window is
        // covered. Its last snapshot must not outlive this one effect.
        let deadline = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        self.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + length + 0.35, execute: deadline)
        layer.presentsWithTransaction = true
        if let drawable = layer.nextDrawable() {
            render(phase: 0, into: drawable, waiting: true)
        }
        begun = CACurrentMediaTime()
        // Turned off before the commit, the first frame never showed, and
        // the link's first, 50 ms ahead as it always aims, came some 70 ms
        // after the rows had gone: the column stood empty that long.
        // Core Animation commits as the main run loop is about to wait, at
        // order 2000000; this runs once, right after it.
        let after = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, 2_000_001) { [self] _, _ in
            MainActor.assumeIsolated {
                layer.presentsWithTransaction = false
                tick()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), after, .commonModes)
    }

    @MainActor
    private func tick() {
        guard finished != nil else { return }
        let link = CAMetalDisplayLink(metalLayer: layer)
        // Sixty a second on a 120 Hz screen too: grains this small don't
        // move smoother at twice the frames, and each frame is the driver's
        // work as much as ours.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.delegate = self
        self.link = link
        nonisolated(unsafe) let ticking = link
        let thread = Thread {
            ticking.add(to: .current, forMode: .default)
            // This thread alone ends its display link. The delegate and
            // the deadline only cancel this owned thread, never invalidate
            // the same native link for a second time.
            defer {
                ticking.delegate = nil
                ticking.invalidate()
            }
            // A cancelled effect must release this owned run loop even if
            // the display link never calls its delegate again.
            while !Thread.current.isCancelled {
                if CFRunLoopRunInMode(.defaultMode, 0.1, false) == .finished { break }
            }
        }
        thread.name = "yab.dust"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let phase = update.targetPresentationTimestamp - begun
        render(phase: Float(phase), into: update.drawable, waiting: false)
        guard phase >= length else { return }
        thread?.cancel()
        CFRunLoopStop(CFRunLoopGetCurrent())
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    @MainActor
    private func finish() {
        guard let completion = finished else { return }
        finished = nil
        deadline?.cancel()
        deadline = nil
        thread?.cancel()
        link = nil
        layer.removeFromSuperlayer()
        completion()
    }

    private func render(phase: Float, into drawable: CAMetalDrawable, waiting: Bool) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        u.phase = phase
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(grains, offset: 0, index: 0)
        encoder.setVertexBytes(&u, length: MemoryLayout<DustUniforms>.stride, index: 1)
        encoder.setVertexBuffer(rows, offset: 0, index: 2)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        encoder.endEncoding()
        if waiting {
            buffer.commit()
            buffer.waitUntilScheduled()
            drawable.present()
        } else {
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

enum DustShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Grain { packed_float2 base; float fraction; uint seed; uint row; uint pad; };
    struct Row { float start; float top; float fold; float pad; };
    struct Uniforms { float phase; float cell; float2 layerSize; float2 origin; float2 pictureSize; uint rowCount; uint renaming; };
    struct Out { float4 position [[position]]; float2 uv; float alpha; };

    // A number in 0..<1 that stays the grain's own.
    static float next(thread uint &s) {
        s = s * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return float((w >> 22u) ^ w) / 4294967296.0;
    }

    // The rows' fold, as SwiftUI's timingCurve(0.65, 0, 0.35, 1) runs it.
    static float inOut(float x) {
        x = clamp(x, 0.0, 1.0);
        return x < 0.5 ? 4.0 * x * x * x : 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0;
    }

    vertex Out dustVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          const device Grain *grains [[buffer(0)]],
                          constant Uniforms &u [[buffer(1)]],
                          const device Row *rows [[buffer(2)]]) {
        Grain g = grains[iid];
        Row own = rows[g.row];
        // It rides up with the rows as those over it fold, before its row
        // sets off and after: held where its row was, a row still waiting
        // under it would catch it up and the two words print over each other.
        float rise = 0.0;
        for (uint j = 0; j < u.rowCount; j++) {
            Row r = rows[j];
            if (r.top < own.top) rise += r.fold * inOut((u.phase - r.start - \(Dust.foldDelay)) / \(Dust.foldTime));
        }
        uint s = g.seed;
        float direction = next(s) * 6.2831853;
        float speed = 42.0 + next(s) * 42.0;
        float life = 0.7 + next(s) * 0.8;

        // Renaming stays inside an 18-point band. Ahead is the old name,
        // behind it no old pixels remain. Clear's flight is unchanged.
        if (u.renaming != 0) {
            float t = max(0.0, u.phase - own.start);
            float edge = clamp(t / 0.62, 0.0, 1.0);
            float band = 18.0 / max(1.0, u.pictureSize.x);
            float delta = g.fraction - edge;
            float active = 1.0 - smoothstep(0.0, band, abs(delta));
            uint frameSeed = g.seed ^ (uint(t * 40.0) * 7919u);
            float noise = next(frameSeed);
            float2 at = float2(g.base) + u.origin;
            at.y += (noise - 0.5) * 8.0 * active;
            float2 corner = float2(vid & 1, vid >> 1);
            float2 p = at + corner * u.cell;
            Out o;
            o.position = float4(p.x / u.layerSize.x * 2.0 - 1.0, 1.0 - p.y / u.layerSize.y * 2.0, 0, 1);
            o.uv = (float2(g.base) + corner * u.cell) / u.pictureSize;
            o.alpha = delta < -band || edge >= 1.0 ? 0.0 : (noise < active * 0.6 ? 0.0 : 1.0);
            return o;
        }

        // The effect's own time for this grain: none until the window
        // reaches its place, then speeding up to twice real time.
        float start = g.fraction / 2.25, ramp = 0.8 / 2.25;
        float t = u.phase - own.start;
        float tau = t <= start ? 0.0 : (t < start + ramp ? (t - start) * (t - start) / ramp : ramp + 2.0 * (t - start - ramp));

        float2 v = float2(cos(direction), sin(direction)) * speed;
        // y down here: the pull up is negative.
        float2 at = float2(g.base) + u.origin + float2(v.x * tau, -v.y * tau - 60.0 * tau * tau - rise);
        float left = life - tau;

        float2 corner = float2(vid & 1, vid >> 1);
        float2 p = at + corner * u.cell;
        Out o;
        o.position = float4(p.x / u.layerSize.x * 2.0 - 1.0, 1.0 - p.y / u.layerSize.y * 2.0, 0, 1);
        o.uv = (float2(g.base) + corner * u.cell) / u.pictureSize;
        o.alpha = clamp(left, 0.0, 0.3) / 0.3;
        return o;
    }

    fragment float4 dustFragment(Out in [[stage_in]], texture2d<float> picture [[texture(0)]]) {
        constexpr sampler near(coord::normalized, filter::nearest, address::clamp_to_edge);
        return picture.sample(near, in.uv) * in.alpha;
    }
    """
}
