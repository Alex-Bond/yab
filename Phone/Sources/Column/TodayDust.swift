import Metal
import QuartzCore
import SwiftUI
import UIKit
import simd

// Clear on a space's page: today's tabs go to dust, as the Mac's do (its
// Sources/Fast/Dust.swift, after Telegram's "Thanos Snap"). The same wave,
// grains and shader: at the press the rows going are taken as drawn, one
// grain a point, each carrying its own pixels, and hidden in the same
// commit; they go top to bottom, each a moment after the one over it, and a
// beat later each gives up its room, so the rows left ride up behind the
// dust. About 1.4 s and it is all gone.
//
// Not with Reduce Motion or Low Power Mode on, nor before the shader is
// ready, nor for rows out of sight: then Clear is what it was.

@MainActor
@Observable
final class TodayDust {
    static let shared = TodayDust()

    nonisolated static let waveStep: TimeInterval = 0.07
    nonisolated static let waveSpan: TimeInterval = 0.42
    nonisolated static let foldDelay: TimeInterval = 0.1
    nonisolated static let foldTime: TimeInterval = 0.38
    static let fold = Animation.timingCurve(0.65, 0, 0.35, 1, duration: foldTime)
    nonisolated static let length: CFTimeInterval = 1.42

    /// Rows going: when each sets off after the first. Their rows read it.
    private(set) var going: [Tab.ID: TimeInterval] = [:]
    /// Where today's rows are drawn now, in the window's points.
    @ObservationIgnored var rows: [Tab.ID: CGRect] = [:]
    /// The part of the window each space's rows can be seen in: under the
    /// page's head, over the field (pages off to the side are off screen).
    @ObservationIgnored var visible: [Space.ID: CGRect] = [:]

    @ObservationIgnored private let device = MTLCreateSystemDefaultDevice()
    @ObservationIgnored private var queue: MTLCommandQueue?
    @ObservationIgnored private var pipeline: MTLRenderPipelineState?
    @ObservationIgnored private var warming = false
    @ObservationIgnored private var runs: [TodayDustRun] = []
    @ObservationIgnored private(set) var played = 0

    static var allowed: Bool {
        !UIAccessibility.isReduceMotionEnabled && !ProcessInfo.processInfo.isLowPowerModeEnabled && !Motion.disabled
    }

    /// The shader, built off the main thread, once: asked for when Clear
    /// first shows, well before it can be pressed.
    func warm() {
        guard pipeline == nil, !warming, let device, Self.allowed else { return }
        warming = true
        device.makeLibrary(source: TodayDustShader.source, options: nil) { library, _ in
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

    /// Today's `ids` on screen, in their order, gone to dust; returns once
    /// the last row has given up its room, so the batch can be put away with
    /// nothing moving for it. False, and nothing changed, when it can't.
    func play(_ ids: [Tab.ID], in space: Space.ID) async -> Bool {
        guard Self.allowed, let device, let pipeline, let queue,
              let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first,
              let root = window.layer as CALayer? else { return false }
        let room = (visible[space] ?? window.bounds).intersection(window.bounds)
        let seen = ids.compactMap { id -> (Tab.ID, CGRect)? in
            guard let rect = rows[id], !room.isNull else { return nil }
            let shown = rect.intersection(room)
            return shown.isNull || shown.height < rect.height * 0.5 ? nil : (id, rect)
        }.sorted { $0.1.minY < $1.1.minY }
        guard !seen.isEmpty else { return false }
        let step = seen.count > 1 ? min(Self.waveStep, Self.waveSpan / Double(seen.count - 1)) : 0
        let lines = seen.enumerated().map { n, row in
            TodayDustRow(rect: row.1.intersection(window.bounds), start: Double(n) * step, fold: row.1.height)
        }
        let scale = window.screen.scale
        let union = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }.integral
        guard let shot = TodayDustSnapshot(window: window, rect: union, rows: lines.map(\.rect), scale: scale),
              let run = TodayDustRun(device: device, pipeline: pipeline, queue: queue, shot: shot, rows: lines,
                                     window: window, root: root, scale: scale) else { return false }
        runs.append(run)
        played += 1
        // The rows hidden in the commit that shows the dust's first frame.
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) {
            for (n, row) in seen.enumerated() { going[row.0] = lines[n].start }
        }
        run.start { [weak self, weak run] in
            guard let self, let run else { return }
            self.runs.removeAll { $0 === run }
        }
        let last = lines.last?.start ?? 0
        try? await Task.sleep(for: .seconds(last + Self.foldDelay + Self.foldTime))
        return true
    }

    /// The batch has been put away (or kept after all): rows read as before.
    func settle() {
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) { going = [:] }
    }
}

/// A today row on a space's page: its frame for the dust, and, going, its
/// ink gone at once and its room given up on the wave's beat.
struct TodayDustFold: ViewModifier {
    let id: Tab.ID
    @State private var height: CGFloat?
    @State private var folded = false

    func body(content: Content) -> some View {
        let start = TodayDust.shared.going[id]
        content
            .opacity(start == nil ? 1 : 0)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                TodayDust.shared.rows[id] = frame
                if start == nil { height = frame.height }
            }
            .frame(height: start == nil ? nil : (folded ? 0 : height), alignment: .top)
            .clipped()
            .onChange(of: start) { _, start in
                guard let start else { folded = false; return }
                withAnimation(TodayDust.fold.delay(start + TodayDust.foldDelay)) { folded = true }
            }
            .onDisappear { TodayDust.shared.rows[id] = nil }
    }
}

struct TodayDustRow {
    var rect: CGRect
    var start: TimeInterval
    var fold: CGFloat
}

/// The rows as drawn, only their ink kept, and the grains to cut them into.
struct TodayDustSnapshot {
    let rect: CGRect
    let width: Int, height: Int
    var pixels: [UInt8]
    var grains: [TodayDustGrain]

    @MainActor
    init?(window: UIWindow, rect: CGRect, rows: [CGRect], scale: CGFloat) {
        self.rect = rect
        width = Int((rect.width * scale).rounded())
        height = Int((rect.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        // The window as it is on screen, the rows' part of it.
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let picture = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: window.bounds.size),
                                 afterScreenUpdates: false)
        }
        guard let image = picture.cgImage else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // The page's ground is in the picture too: read where a row never
        // draws, the gap before its mark, and take it out; what is near it is
        // the ground, what is far is the ink.
        var grains: [TodayDustGrain] = []
        grains.reserveCapacity(Int(rect.width * rect.height) / 3)
        let s = Float(scale)
        let stride = w * 4
        pixels.withUnsafeMutableBufferPointer { p in
            for (number, row) in rows.enumerated() {
                let x0 = max(0, Int(((row.minX - rect.minX) * scale).rounded())), x1 = min(w, Int(((row.maxX - rect.minX) * scale).rounded()))
                let y0 = max(0, Int(((row.minY - rect.minY) * scale).rounded())), y1 = min(h, Int(((row.maxY - rect.minY) * scale).rounded()))
                guard x1 > x0, y1 > y0 else { continue }
                let gi = ((y0 + y1) / 2) * stride + min(x1 - 1, x0 + Int(3 * scale)) * 4
                let ga = max(1, Float(p[gi + 3]))
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
                        grains.append(TodayDustGrain(base: SIMD2(Float(x) / s, Float(y) / s),
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

struct TodayDustGrain {
    var base: SIMD2<Float>
    var fraction: Float
    var seed: UInt32
    var row: UInt32
    var pad: UInt32
}

struct TodayDustRowUniform {
    var start: Float
    var top: Float
    var fold: Float
    var pad: Float = 0
}

struct TodayDustUniforms {
    var phase: Float
    var cell: Float
    var layerSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var pictureSize: SIMD2<Float>
    var rowCount: UInt32
}

/// One Clear's dust: its layer over the window, its picture, its grains,
/// its clock on a thread of its own.
final class TodayDustRun: NSObject, CAMetalDisplayLinkDelegate {
    private let layer = CAMetalLayer()
    private let pipeline: MTLRenderPipelineState
    private let queue: MTLCommandQueue
    private let texture: MTLTexture
    private let grains: MTLBuffer
    private let rows: MTLBuffer
    private let count: Int
    private let length: CFTimeInterval
    private var uniforms: TodayDustUniforms
    private var link: CAMetalDisplayLink?
    private var thread: Thread?
    private var begun: CFTimeInterval = 0
    private var finished: (() -> Void)?

    @MainActor
    init?(device: MTLDevice, pipeline: MTLRenderPipelineState, queue: MTLCommandQueue, shot: TodayDustSnapshot,
          rows: [TodayDustRow], window: UIWindow, root: CALayer, scale: CGFloat) {
        self.pipeline = pipeline
        self.queue = queue
        let describe = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: shot.width, height: shot.height, mipmapped: false)
        describe.usage = .shaderRead
        describe.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: describe) else { return nil }
        shot.pixels.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, shot.width, shot.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: shot.width * 4)
        }
        self.texture = texture
        guard let buffer = shot.grains.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        grains = buffer
        count = shot.grains.count
        let lines = rows.map { TodayDustRowUniform(start: Float($0.start), top: Float($0.rect.minY), fold: Float($0.fold)) }
        guard let lined = lines.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else { return nil }
        self.rows = lined
        length = TodayDust.length + (rows.map(\.start).max() ?? 0)

        // The screen's width, from well above the rows (the dust rises) to a
        // little under them.
        let bounds = window.bounds
        let top = max(0, shot.rect.minY - 280), bottom = min(bounds.height, shot.rect.maxY + 150)
        let frame = CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
        uniforms = TodayDustUniforms(phase: 0, cell: 1,
                                     layerSize: SIMD2(Float(frame.width), Float(frame.height)),
                                     origin: SIMD2(Float(shot.rect.minX - frame.minX), Float(shot.rect.minY - frame.minY)),
                                     pictureSize: SIMD2(Float(shot.rect.width), Float(shot.rect.height)),
                                     rowCount: UInt32(rows.count))
        super.init()

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
        layer.maximumDrawableCount = 3
        layer.frame = frame
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
        layer.presentsWithTransaction = true
        if let drawable = layer.nextDrawable() {
            render(phase: 0, into: drawable, waiting: true)
        }
        begun = CACurrentMediaTime()
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
        let link = CAMetalDisplayLink(metalLayer: layer)
        // Sixty a second on a 120 Hz screen too: grains this small don't
        // move smoother at twice the frames.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.delegate = self
        self.link = link
        nonisolated(unsafe) let ticking = link
        let thread = Thread {
            ticking.add(to: .current, forMode: .default)
            CFRunLoopRun()
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
        link.invalidate()
        CFRunLoopStop(CFRunLoopGetCurrent())
        DispatchQueue.main.async { [self] in
            layer.removeFromSuperlayer()
            finished?()
            finished = nil
        }
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
        encoder.setVertexBytes(&u, length: MemoryLayout<TodayDustUniforms>.stride, index: 1)
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

/// The Mac's shader (Sources/Fast/Dust.swift), word for word.
enum TodayDustShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Grain { packed_float2 base; float fraction; uint seed; uint row; uint pad; };
    struct Row { float start; float top; float fold; float pad; };
    struct Uniforms { float phase; float cell; float2 layerSize; float2 origin; float2 pictureSize; uint rowCount; };
    struct Out { float4 position [[position]]; float2 uv; float alpha; };

    static float next(thread uint &s) {
        s = s * 747796405u + 2891336453u;
        uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
        return float((w >> 22u) ^ w) / 4294967296.0;
    }

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
        float rise = 0.0;
        for (uint j = 0; j < u.rowCount; j++) {
            Row r = rows[j];
            if (r.top < own.top) rise += r.fold * inOut((u.phase - r.start - \(TodayDust.foldDelay)) / \(TodayDust.foldTime));
        }
        uint s = g.seed;
        float direction = next(s) * 6.2831853;
        float speed = 42.0 + next(s) * 42.0;
        float life = 0.7 + next(s) * 0.8;

        float start = g.fraction / 2.25, ramp = 0.8 / 2.25;
        float t = u.phase - own.start;
        float tau = t <= start ? 0.0 : (t < start + ramp ? (t - start) * (t - start) / ramp : ramp + 2.0 * (t - start - ramp));

        float2 v = float2(cos(direction), sin(direction)) * speed;
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
