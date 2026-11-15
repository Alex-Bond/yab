import AppKit
import Metal
import QuartzCore

// The glass of Yab Wrapped's arcade: the screen's pixel grid (WrappedGrid)
// put through one Metal pass that makes it a tube. The glass bulges, every
// grid row is a scanline, red and blue sit a hair apart, the light bleeds
// a little and the edges fall dark; a roll runs down it as a screen
// changes. One pass, one texture, nothing per element.
//
// The live screen draws on the display's clock while it is on screen and
// stops with the window. The share card goes through the same pass once,
// off screen, into a picture.

struct WrappedTubeUniforms {
    var time: Float = 0
    /// How much of a screen change's roll is left, 1 to 0.
    var roll: Float = 0
    var flicker: Float = 1
    /// How far the glass bulges.
    var curve: Float = 0.14
    /// Grid rows, one scanline each.
    var rows: Float = 320
    var pad: Float = 0
}

@MainActor
final class WrappedTube {
    static let shared = WrappedTube()

    let device = MTLCreateSystemDefaultDevice()
    private(set) var pipeline: MTLRenderPipelineState?
    private(set) var queue: MTLCommandQueue?

    /// Built once, the first time it is asked for, synchronously: the
    /// source is small and Wrapped opens on a click.
    func prepare() -> Bool {
        if pipeline != nil { return true }
        guard let device, let library = try? device.makeLibrary(source: Self.source, options: nil) else { return false }
        let describe = MTLRenderPipelineDescriptor()
        describe.vertexFunction = library.makeFunction(name: "tubeVertex")
        describe.fragmentFunction = library.makeFunction(name: "tubeFragment")
        describe.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: describe)
        queue = pipeline == nil ? nil : device.makeCommandQueue()
        return pipeline != nil
    }

    /// A texture the size of a grid, to copy each drawn frame into.
    func texture(width: Int, height: Int) -> MTLTexture? {
        let describe = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        describe.usage = .shaderRead
        return device?.makeTexture(descriptor: describe)
    }

    func upload(_ grid: WrappedGrid, to texture: MTLTexture) {
        guard let data = grid.context.data else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, grid.width, grid.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: grid.context.bytesPerRow)
    }

    func encode(_ buffer: MTLCommandBuffer, source: MTLTexture, into target: MTLTexture, uniforms: WrappedTubeUniforms) {
        guard let pipeline else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var u = uniforms
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<WrappedTubeUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The grid through the glass once, as a picture `width` by `height`.
    func picture(_ grid: WrappedGrid, width: Int, height: Int, uniforms: WrappedTubeUniforms) -> CGImage? {
        guard prepare(), let device, let queue, let source = texture(width: grid.width, height: grid.height) else { return nil }
        upload(grid, to: source)
        let describe = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        describe.usage = [.renderTarget, .shaderRead]
        describe.storageMode = .managed
        guard let target = device.makeTexture(descriptor: describe), let buffer = queue.makeCommandBuffer() else { return nil }
        encode(buffer, source: source, into: target, uniforms: uniforms)
        if let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Out { float4 position [[position]]; float2 uv; };
    struct Uniforms { float time; float roll; float flicker; float curve; float rows; float pad; };

    vertex Out tubeVertex(uint id [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        Out o;
        o.position = float4(p[id], 0, 1);
        o.uv = float2(p[id].x * 0.5 + 0.5, 0.5 - p[id].y * 0.5);
        return o;
    }

    static float hash(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }
    static float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);
        return mix(mix(hash(i), hash(i + float2(1, 0)), u.x), mix(hash(i + float2(0, 1)), hash(i + float2(1, 1)), u.x), u.y);
    }

    fragment float4 tubeFragment(Out in [[stage_in]], texture2d<float> grid [[texture(0)]], constant Uniforms& u [[buffer(0)]]) {
        constexpr sampler near(filter::nearest, address::clamp_to_edge);
        constexpr sampler soft(filter::linear, address::clamp_to_edge);
        float2 c = in.uv - 0.5;
        float2 uv = 0.5 + c * (1.0 + u.curve * dot(c, c));
        float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
        uv.x += (noise(float2(floor(uv.y * 60.0), u.time * 30.0)) - 0.5) * 0.06 * u.roll;
        float o = 0.0018;
        float3 col = float3(grid.sample(near, uv + float2(o, 0)).r, grid.sample(near, uv).g, grid.sample(near, uv - float2(o, 0)).b);
        float3 bleed = (grid.sample(soft, uv + float2(0.007, 0)).rgb + grid.sample(soft, uv - float2(0.007, 0)).rgb
                      + grid.sample(soft, uv + float2(0, 0.004)).rgb + grid.sample(soft, uv - float2(0, 0.004)).rgb) * 0.25;
        col += bleed * 0.7 + float3(0.012, 0.016, 0.035);
        float line = sin(uv.y * u.rows * 3.14159265);
        col *= 0.7 + 0.3 * line * line;
        float m = fmod(in.position.x, 3.0);
        col *= float3(m < 1.0 ? 1.06 : 0.94, (m >= 1.0 && m < 2.0) ? 1.06 : 0.94, m >= 2.0 ? 1.06 : 0.94);
        col *= 1.0 - u.flicker * 0.03 * (0.5 + 0.5 * sin(u.time * 50.0));
        float2 v = uv * (1.0 - uv);
        col *= pow(clamp(v.x * v.y * 16.0, 0.0, 1.0), 0.25);
        col = mix(float3(0.015), col, inside);
        return float4(col, 1.0);
    }
    """
}

/// The tube on screen: a Metal layer that asks for the next frame of the
/// grid on the display's clock, while it is in a window.
@MainActor
final class WrappedTubeView: NSView {
    /// Draws the grid for a moment, in seconds since the view went on screen.
    var draw: ((WrappedGrid, Double) -> WrappedTubeUniforms)?

    private let metal = CAMetalLayer()
    private let grid: WrappedGrid?
    private var source: MTLTexture?
    private var link: CADisplayLink?
    private var begun: CFTimeInterval = 0

    init(width: Int, height: Int) {
        grid = WrappedGrid(width: width, height: height)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let tube = WrappedTube.shared
        if tube.prepare() {
            metal.device = tube.device
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.isOpaque = true
            layer?.addSublayer(metal)
            source = tube.texture(width: width, height: height)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether the tube could be built: without Metal it stays black.
    var works: Bool { source != nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil, works else { return }
        begun = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let grid, let source, let draw, let queue = WrappedTube.shared.queue,
              let drawable = metal.nextDrawable(), let buffer = queue.makeCommandBuffer() else { return }
        let uniforms = draw(grid, CACurrentMediaTime() - begun)
        WrappedTube.shared.upload(grid, to: source)
        WrappedTube.shared.encode(buffer, source: source, into: drawable.texture, uniforms: uniforms)
        buffer.present(drawable)
        buffer.commit()
    }
}
