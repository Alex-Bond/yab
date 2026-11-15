import AppKit
import Testing
@testable import Fast

@MainActor
struct PDFHUDProbeTests {
    private final class Legacy: NSView {
        var shown = false
        @objc(_setVisible:) func setVisible(_ visible: Bool) { shown = visible }
    }

    private final class Native: NSView {
        var shown = false
        @objc func show() { shown = true }
    }

    @Test func invokesTheActualVisibilityInterfaceOnBothVersions() {
        let legacy = Legacy(), native = Native()
        #expect(PDFHUDProbe.show(legacy))
        #expect(legacy.shown)
        #expect(PDFHUDProbe.show(native))
        #expect(native.shown)
        #expect(!PDFHUDProbe.show(NSView()))
    }

    @Test func nativeButtonsNeedNoRootLayerAndKeepWindowCoordinatesAndOpacity() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bar = NSView(frame: NSRect(x: 10, y: 20, width: 300, height: 100))
        let panel = NSView(frame: NSRect(x: 30, y: 40, width: 250, height: 50))
        window.contentView?.addSubview(bar)
        bar.addSubview(panel)
        // Deliberately insert right first, as subview order isn't button order.
        panel.addSubview(NSButton(frame: NSRect(x: 100, y: 5, width: 24, height: 20)))
        panel.addSubview(NSButton(frame: NSRect(x: 5, y: 5, width: 24, height: 20)))
        bar.alphaValue = 0.8
        panel.alphaValue = 0.5
        let controls = PDFHUDProbe.controls(in: bar)
        #expect(controls.frames == [NSRect(x: 45, y: 65, width: 24, height: 20),
                                    NSRect(x: 140, y: 65, width: 24, height: 20)])
        #expect(abs(controls.opacity - 0.4) < 0.0001)
        panel.isHidden = true
        #expect(PDFHUDProbe.controls(in: bar).opacity == 0)
    }

    @Test func legacyLayersStillExcludeTheSeparator() {
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        bar.wantsLayer = true
        let panel = CALayer()
        panel.frame = CGRect(x: 10, y: 20, width: 200, height: 40)
        panel.opacity = 0.75
        bar.layer?.addSublayer(panel)
        for frame in [CGRect(x: 5, y: 0, width: 24, height: 20),
                      CGRect(x: 30, y: 0, width: 1, height: 20),
                      CGRect(x: 40, y: 0, width: 24, height: 20)] {
            let layer = CALayer()
            layer.frame = frame
            panel.addSublayer(layer)
        }
        let controls = PDFHUDProbe.controls(in: bar)
        #expect(controls.frames.count == 2)
        #expect(controls.frames.map(\.width) == [24, 24])
        #expect(controls.opacity == 0.75)
        #expect(PDFHUDProbe.controls(in: NSView()).frames.isEmpty)
    }
}
