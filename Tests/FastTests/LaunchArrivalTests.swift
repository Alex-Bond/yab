import AppKit
import Metal
import Testing
@testable import Fast

struct LaunchArrivalTests {
    @Test func cleanPreviewCentersOnTheChosenScreenAndFitsSmallerDisplays() {
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let centered = LaunchArrivalPreview.frame(screen: main, visible: CGRect(x: 0, y: 50, width: 1728, height: 1040))
        #expect(centered.size == CGSize(width: 1180, height: 780))
        #expect(centered.midX == main.midX)
        #expect(centered.midY == main.midY)
        let external = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let there = LaunchArrivalPreview.frame(screen: external, visible: external.insetBy(dx: 0, dy: 30))
        #expect(there.midX == external.midX)
        #expect(there.midY == external.midY)
        let small = CGRect(x: 100, y: 80, width: 900, height: 650)
        let fitted = LaunchArrivalPreview.frame(screen: small, visible: small.insetBy(dx: 0, dy: 25))
        #expect(fitted == small.insetBy(dx: 0, dy: 25))
    }

    @Test func originalAudioCueRevealsTheWindow() {
        #expect(LaunchArrivalTiming.shaderTime(audioTime: 5.55) < LaunchArrivalTiming.handoff)
        #expect(abs(LaunchArrivalTiming.shaderTime(audioTime: 5.56) - LaunchArrivalTiming.handoff) < 0.000001)
        #expect(LaunchArrivalTiming.dimming(audioTime: 5.56) == 0)
        #expect(LaunchArrivalTiming.shaderTime(audioTime: 8) == LaunchArrivalTiming.end)
        var previous = 0.0
        for frame in 0 ... 600 {
            let time = LaunchArrivalTiming.shaderTime(audioTime: Double(frame) / 60)
            #expect(time >= previous)
            #expect(time <= LaunchArrivalTiming.end)
            previous = time
        }
    }

    @Test func failedAndBackwardsAudioCannotStrandTheWindow() {
        var progress = LaunchArrivalProgress()
        progress.advance(wallTime: 5.7, audioTime: 5.5)
        #expect(progress.revealsWindow)
        #expect(!progress.finished) // The healthy audio clock owns the handoff.
        progress.advance(wallTime: 5.8, audioTime: 5.65)
        #expect(progress.revealsWindow)
        progress.advance(wallTime: 5.9, audioTime: 5.4)
        #expect(progress.revealsWindow)
        progress.advance(wallTime: 8, audioTime: 0) // A stopped output device.
        #expect(progress.finished)
        progress.advance(wallTime: .nan, audioTime: .infinity)
        #expect(progress.finished)
        var silent = LaunchArrivalProgress()
        silent.advance(wallTime: 5.56, audioTime: nil)
        #expect(silent.revealsWindow)
        silent.advance(wallTime: 8, audioTime: nil)
        #expect(silent.finished)
    }

    @Test func approvedHandoffCrossfadesBothSurfacesOnTheSameAudioClock() {
        var previous = 0.0
        for frame in 0 ... 420 {
            let time = Double(frame) / 60
            var progress = LaunchArrivalProgress()
            progress.advance(wallTime: time, audioTime: time)
            #expect(progress.windowOpacity >= previous)
            #expect(progress.windowOpacity + progress.lightOpacity == 1)
            if time <= 5.36 { #expect(progress.windowOpacity == 0) }
            if time >= 5.66 {
                #expect(progress.windowOpacity == 1)
                #expect(progress.lightOpacity == 0)
                #expect(progress.finished)
            }
            previous = progress.windowOpacity
        }
        #expect(abs(LaunchArrivalTiming.windowOpacity(audioTime: 5.51) - 0.5) < 0.000001)
        #expect(abs(LaunchArrivalTiming.revealEnd - LaunchArrivalTiming.revealStart - 0.30) < 0.000001)
    }

    @Test func onlyAnOrdinaryFirstForegroundWindowPlays() {
        #expect(LaunchArrivalEligibility().plays)
        #expect(!LaunchArrivalEligibility(primary: false).plays)
        #expect(!LaunchArrivalEligibility(offered: true).plays)
        #expect(!LaunchArrivalEligibility(headless: true).plays)
        #expect(!LaunchArrivalEligibility(hidden: true).plays)
        #expect(!LaunchArrivalEligibility(reduceMotion: true).plays)
        #expect(!LaunchArrivalEligibility(testing: true).plays)
        #expect(!LaunchArrivalEligibility(overrideValue: "0").plays)
        #expect(!LaunchArrivalEligibility(seen: true).plays)
        #expect(LaunchArrivalEligibility(seen: true, overrideValue: "1").plays)
        #expect(LaunchArrivalEligibility(testing: true, overrideValue: "first").plays)
        #expect(!LaunchArrivalEligibility(testing: true, seen: true, overrideValue: "first").plays)
        #expect(LaunchArrivalEligibility(testing: true, overrideValue: "1").plays)
        #expect(!LaunchArrivalEligibility(headless: true, testing: true, overrideValue: "1").plays)
        #expect(!LaunchArrivalEligibility(reduceMotion: true, overrideValue: "1").plays)
    }

    @Test @MainActor func accentUsesLinearRadianceAndGraphiteStaysNeutral() {
        let palette = LaunchLightPalette.resolve(accent: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        #expect(abs(palette.middle.x - 0.203339) < 0.00001)
        #expect(palette.middle.x == palette.middle.y)
        #expect(palette.middle.y == palette.middle.z)
        #expect(palette.low.x < palette.middle.x)
        #expect(palette.middle.x < palette.high.x)
        #expect(palette.high.x < palette.core.x)
        #expect(MemoryLayout<LaunchLightUniforms>.stride == 64)
        #expect(MemoryLayout<LaunchLightPalette>.stride == 96)
        #expect(MemoryLayout<LaunchLightEmitter>.stride == 96)
    }

    /// Compile the real shipped shader, draw it through the production encoder,
    /// and inspect pixels. A renamed/missing entry point or a Metal ABI mismatch
    /// must fail the shared check, rather than silently falling back in the app.
    @Test @MainActor func shaderRendersTheAccentAndLeavesNoFinalOverlay() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/LaunchArrival/Waves.metal")
        let red = try LaunchLightRenderer(device: device,
            palette: .resolve(accent: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
            surface: SIMD4(0.1, 0.1, 0.1, 0.18), sourceURL: source)
        let blue = try LaunchLightRenderer(device: device,
            palette: .resolve(accent: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
            surface: SIMD4(0.1, 0.1, 0.1, 0.18), sourceURL: source)
        func pixels(_ renderer: LaunchLightRenderer, at time: Float) throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 160, height: 120, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let command = try #require(renderer.commandQueue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            renderer.state.elapsed = time
            renderer.state.variant = 703
            renderer.state.targetSize = CGSize(width: 160, height: 120)
            try renderer.encode(pass: pass, command: command, width: 160, height: 120, scale: 1)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: 160 * 120 * 4)
            bytes.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: 160 * 4,
                                from: MTLRegionMake2D(0, 0, 160, 120), mipmapLevel: 0)
            }
            return bytes
        }
        #expect(try pixels(red, at: 0).allSatisfy { $0 == 0 })
        let redPixels = try pixels(red, at: 1.5), bluePixels = try pixels(blue, at: 1.5)
        func sum(_ pixels: [UInt8], _ channel: Int) -> Int {
            stride(from: channel, to: pixels.count, by: 4).reduce(0) { $0 + Int(pixels[$1]) }
        }
        #expect(sum(redPixels, 3) > 0)
        #expect(sum(redPixels, 2) > sum(redPixels, 0))
        #expect(sum(bluePixels, 0) > sum(bluePixels, 2))
        for time: Float in [2.05, 2.4, 2.88] {
            let frame = try pixels(red, at: time)
            for pixel in stride(from: 0, to: frame.count, by: 4) {
                #expect(frame[pixel] <= frame[pixel + 3])
                #expect(frame[pixel + 1] <= frame[pixel + 3])
                #expect(frame[pixel + 2] <= frame[pixel + 3])
            }
        }
        #expect(try pixels(red, at: 2.88).allSatisfy { $0 == 0 })
        // The carrier contains light only, never a solid window-coloured
        // plate. Its alpha is its brightest emitted channel, within dither.
        for time: Float in [1.8, 2.05, 2.4] {
            let frame = try pixels(red, at: time)
            for pixel in stride(from: 0, to: frame.count, by: 4) {
                let peak = max(frame[pixel], frame[pixel + 1], frame[pixel + 2])
                #expect(Int(frame[pixel + 3]) - Int(peak) <= 1)
            }
        }
        // The production handoff override wins even while radiance is at
        // its peak: the fully revealed native window has zero light over it.
        red.state.rayOpacityOverride = 0
        #expect(try pixels(red, at: 1.5).allSatisfy { $0 == 0 })
    }
}
