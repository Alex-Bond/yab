import AppKit
import MetalKit

// A Ray/Flow light renderer, adapted to one noninteractive carrier.
// No browser or page is captured. All textures are released after the reveal.
enum LaunchLightError: Error { case unavailable, missingSource, missingFunction, renderFailed }

struct LaunchLightState {
    var elapsed: Float = 0
    var inset: Float = 0
    var nativeSurface = false
    var variant = 2
    var targetSize = CGSize.zero
    var targetOffset = CGPoint.zero
    var darkAppearance = false
    var rayPhaseLock: Float = -1
    var rayOpacityOverride: Float = -1
}

struct LaunchLightUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var inset: Float
    var nativeSurface: Float
    var scale: Float
    var variant: Float
    var style: Float
    var targetSize: SIMD2<Float>
    var targetOffset: SIMD2<Float>
    var tuning: SIMD4<Float>
}

enum LaunchLightFlow {
    static let style: Float = 7
    static let transition: Float = 1
    static let tuning = SIMD4<Float>(0.35, 1, 0.55, 0.58)
    static let bloomEnd: Float = 1.95
}

/// Same six float4 slots as the source shader. Collection stays at zero;
/// the centre is an optical emitter, with no logo texture.
struct LaunchLightEmitter {
    var frame = SIMD4<Float>(0, 0, 72, 72)
    var crop = SIMD4<Float>(0, 0, 1, 1)
    var options = SIMD4<Float>(1, 0, 0, 100)
    var timing = SIMD4<Float>(repeating: 100)
    var ending = SIMD4<Float>(.pi / 4, 0.5, -1, 100)
    var exit = SIMD4<Float>(repeating: 0)
}

/// The shader consumes linear radiance, not display RGB. Resolve the actual
/// Mac accent once per launch; graphite consequently stays neutral too.
struct LaunchLightPalette {
    var low: SIMD4<Float>
    var middle: SIMD4<Float>
    var high: SIMD4<Float>
    var core: SIMD4<Float>
    var surface = SIMD4<Float>(repeating: 0)
    var finish = SIMD4<Float>(repeating: 0)

    static func resolve(accent: NSColor) -> Self {
        let rgb = accent.usingColorSpace(.sRGB) ?? NSColor.systemBlue.usingColorSpace(.sRGB)!
        func linear(_ value: CGFloat) -> Float {
            let x = min(1, max(0, Double(value)))
            return Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4))
        }
        let base = SIMD3(linear(rgb.redComponent), linear(rgb.greenComponent), linear(rgb.blueComponent))
        func slot(_ scale: Float, _ white: Float = 0) -> SIMD4<Float> {
            let color = base * scale + SIMD3<Float>(repeating: white)
            return SIMD4(color.x, color.y, color.z, 0)
        }
        return Self(low: slot(0.26), middle: slot(0.95), high: slot(0.36, 0.64), core: slot(0.10, 0.90))
    }

    static func windowSurface(dark: Bool) -> SIMD4<Float> {
        let color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!
        return SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), dark ? 0.18 : 0.20)
    }
}

final class LaunchLightView: MTKView {
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); updateResolution() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateResolution() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateResolution() }

    private func updateResolution() {
        let scale = min(window?.backingScaleFactor ?? 2, 1.5)
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        if drawableSize != size { drawableSize = size }
    }
}

private final class LaunchLightResources {
    // MARK: Lifecycle

    init(device: MTLDevice, sourceURL: URL?) throws {
        guard let url = sourceURL ?? Bundle.main
            .url(forResource: "Waves", withExtension: "metal", subdirectory: "LaunchArrival")
        else {
            throw LaunchLightError.missingSource
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        self.library = library
        guard let vertex = library.makeFunction(name: "fullScreenVertex"),
              let radiance = library.makeFunction(name: "rayRadianceFragment"),
              let composite = library.makeFunction(name: "rayCompositeFragment"),
              let extract = library.makeFunction(name: "rayBloomExtract"),
              let blur = library.makeFunction(name: "rayBloomBlur")
        else {
            throw LaunchLightError.missingFunction
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = radiance
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        self.rayPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        // The compositor writes premultiplied RGBA directly onto a transparent drawable.
        descriptor.fragmentFunction = composite
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.rayComposite = try device.makeRenderPipelineState(descriptor: descriptor)
        self.bloomExtract = try device.makeComputePipelineState(function: extract)
        self.bloomBlur = try device.makeComputePipelineState(function: blur)
    }

    // MARK: Internal

    let library: MTLLibrary
    let rayPipeline: MTLRenderPipelineState
    let rayComposite: MTLRenderPipelineState
    let bloomExtract: MTLComputePipelineState
    let bloomBlur: MTLComputePipelineState

}

final class LaunchLightRenderer: NSObject, MTKViewDelegate {
    // MARK: Lifecycle

    init(device: MTLDevice, palette: LaunchLightPalette, surface: SIMD4<Float>, sourceURL: URL? = nil) throws {
        guard let queue = device.makeCommandQueue() else { throw LaunchLightError.unavailable }
        let resources = try LaunchLightResources(device: device, sourceURL: sourceURL)
        self.library = resources.library
        self.rayPipeline = resources.rayPipeline
        self.rayComposite = resources.rayComposite
        self.bloomExtract = resources.bloomExtract
        self.bloomBlur = resources.bloomBlur
        self.commandQueue = queue
        self.palette = palette
        self.surface = surface
        super.init()
    }

    // MARK: Internal

    var state = LaunchLightState()
    var onFailure: ((String) -> Void)?
    var onPresented: ((Double) -> Void)?
    let commandQueue: MTLCommandQueue

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay(view.bounds)
    }

    func draw(in view: MTKView) {
        guard view.window?.isVisible == true, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = commandQueue.makeCommandBuffer() else { inFlight.signal(); return }
        do {
            try encode(pass: pass, command: command, width: drawable.texture.width,
                       height: drawable.texture.height,
                       scale: Float(view.drawableSize.width / max(view.bounds.width, 1)))
        } catch {
            inFlight.signal()
            onFailure?(error.localizedDescription)
            return
        }
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            if completed.status == .error {
                let message = completed.error?.localizedDescription ?? "Launch light command failed"
                DispatchQueue.main.async { self?.onFailure?(message) }
            }
        }
        let time = Double(state.elapsed)
        drawable.addPresentedHandler { [weak self] _ in
            DispatchQueue.main.async { self?.onPresented?(time) }
        }
        command.present(drawable)
        command.commit()
    }

    /// The original radiance and bloom, fading onto Yab at the handoff.
    func encode(
        pass: MTLRenderPassDescriptor,
        command: MTLCommandBuffer,
        width: Int,
        height: Int,
        scale: Float
    ) throws {
        var uniforms = LaunchLightUniforms(
            resolution: SIMD2(Float(width), Float(height)), time: self.state.elapsed,
            inset: self.state.inset * scale, nativeSurface: self.state.nativeSurface ? 1 : 0, scale: scale,
            variant: Float(self.state.variant), style: LaunchLightFlow.style,
            targetSize: SIMD2(Float(self.state.targetSize.width), Float(self.state.targetSize.height)),
            targetOffset: SIMD2(Float(self.state.targetOffset.x), Float(self.state.targetOffset.y)),
            tuning: LaunchLightFlow.tuning
        )
        let targets = try self.targets(width: width, height: height)
        let hdrPass = MTLRenderPassDescriptor()
        hdrPass.colorAttachments[0].texture = targets.radiance
        hdrPass.colorAttachments[0].loadAction = .dontCare
        hdrPass.colorAttachments[0].storeAction = .store
        guard let volume = command.makeRenderCommandEncoder(descriptor: hdrPass) else { throw LaunchLightError.renderFailed }
        volume.label = "Ray · 28-sample light volume"
        volume.setRenderPipelineState(self.rayPipeline)
        volume.setFragmentBytes(&uniforms, length: MemoryLayout<LaunchLightUniforms>.stride, index: 0)
        var palette = self.palette
        volume.setFragmentBytes(&palette, length: MemoryLayout<LaunchLightPalette>.stride, index: 1)
        var transition = SIMD4<Float>(
            LaunchLightFlow.transition, self.state.rayPhaseLock, self.state.darkAppearance ? 1 : 0,
            self.state.rayOpacityOverride
        )
        volume.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        var logo = LaunchLightEmitter()
        volume.setFragmentBytes(&logo, length: MemoryLayout<LaunchLightEmitter>.stride, index: 3)
        volume.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        volume.endEncoding()

        if !self.state.nativeSurface, self.state.elapsed < LaunchLightFlow.bloomEnd {
            try self.compute(command, self.bloomExtract, input: targets.radiance, output: targets.bright)
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.bright,
                output: targets.scratch,
                axis: SIMD2(scale, 0)
            )
            try self.compute(
                command,
                self.bloomBlur,
                input: targets.scratch,
                output: targets.bloom,
                axis: SIMD2(0, scale)
            )
        }
        guard let composite = command.makeRenderCommandEncoder(descriptor: pass) else { throw LaunchLightError.renderFailed }
        composite.label = "Launch light · bloom and native window reveal"
        composite.setRenderPipelineState(self.rayComposite)
        composite.setFragmentBytes(&uniforms, length: MemoryLayout<LaunchLightUniforms>.stride, index: 0)
        var surface = self.surface
        composite.setFragmentBytes(&surface, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        composite.setFragmentBytes(&transition, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        composite.setFragmentTexture(targets.radiance, index: 0)
        composite.setFragmentTexture(targets.bloom, index: 1)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        composite.endEncoding()
    }

    // MARK: Private

    private struct RayTargets {
        let radiance: MTLTexture
        let bright: MTLTexture
        let scratch: MTLTexture
        let bloom: MTLTexture
    }

    private let inFlight = DispatchSemaphore(value: 3)
    private let palette: LaunchLightPalette
    private let surface: SIMD4<Float>
    private let library: MTLLibrary
    private let rayPipeline: MTLRenderPipelineState
    private let rayComposite: MTLRenderPipelineState
    private let bloomExtract: MTLComputePipelineState
    private let bloomBlur: MTLComputePipelineState
    private var rayTargets: RayTargets?

    /// Private, reusable GPU textures; bloom runs at quarter resolution.
    private func targets(width: Int, height: Int) throws -> RayTargets {
        if let rayTargets, rayTargets.radiance.width == width, rayTargets.radiance.height == height {
            return rayTargets
        }
        func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false
            )
            descriptor.storageMode = .private
            descriptor.usage = usage
            guard let result = commandQueue.device.makeTexture(descriptor: descriptor) else {
                throw LaunchLightError.renderFailed
            }
            result.label = label
            return result
        }
        let w = max(1, (width + 3) / 4), h = max(1, (height + 3) / 4)
        let result = try RayTargets(
            radiance: texture(width, height, [.renderTarget, .shaderRead], "Ray linear radiance"),
            bright: texture(w, h, [.shaderRead, .shaderWrite], "Ray bloom bright pass"),
            scratch: texture(w, h, [.shaderRead, .shaderWrite], "Ray horizontal bloom"),
            bloom: texture(w, h, [.shaderRead, .shaderWrite], "Ray vertical bloom")
        )
        self.rayTargets = result
        return result
    }

    private func compute(
        _ command: MTLCommandBuffer,
        _ pipeline: MTLComputePipelineState,
        input: MTLTexture,
        output: MTLTexture,
        axis: SIMD2<Float>? = nil
    ) throws {
        guard let encoder = command.makeComputeCommandEncoder() else { throw LaunchLightError.renderFailed }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        if var axis { encoder.setBytes(&axis, length: MemoryLayout<SIMD2<Float>>.stride, index: 0) }
        let w = pipeline.threadExecutionWidth
        let h = min(8, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1)
        )
        encoder.endEncoding()
    }
}
