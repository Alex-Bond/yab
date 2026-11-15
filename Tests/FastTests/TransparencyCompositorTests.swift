import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Fast

/// Opt in on an unlocked Mac with Screen Recording. Capturing the display
/// crop is necessary: an individual-window image omits the real backdrop.
struct TransparencyCompositorTests {
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["YAB_TRANSPARENCY_CAPTURE"] == "1"))
    func actualBrowserChromeBlursTheDesktopAndKeepsItsPageOpaque() async throws {
        _ = NSApplication.shared
        try #require(CGPreflightScreenCaptureAccess())
        let screen = try #require(NSScreen.main)
        let frame = NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 60, width: 880, height: 660)
        func window() -> NSWindow {
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            return window
        }
        let fixture = window()
        fixture.ignoresMouseEvents = true
        fixture.contentView = TransparencyStripes(frame: NSRect(origin: .zero, size: frame.size))
        let target = window()
        target.title = "Yab transparency verification"
        let browser = Browser(windowID: UUID())
        let held = SpacePaint(browser.prefs)
        let backdropMode = browser.prefs.backdrop
        let sidebar = browser.prefs.sidebar
        let welcomed = browser.prefs.welcomed
        defer {
            target.orderOut(nil)
            fixture.orderOut(nil)
            target.contentView = nil
            for tab in browser.tabs + browser.parkedTabs { tab.close() }
            held.wear(browser.prefs)
            browser.prefs.backdrop = backdropMode
            browser.prefs.sidebar = sidebar
            browser.prefs.welcomed = welcomed
            try? FileManager.default.removeItem(at: Store.file("session-window-\(browser.windowID!.uuidString).json"))
        }
        browser.prefs.welcomed = true
        browser.prefs.backdrop = .color
        browser.prefs.swatch = .custom
        browser.prefs.backdropColor = NSColor(hex: "8DB6E6")!
        browser.prefs.backdropTransparency = 0
        browser.prefs.grain = 0
        browser.prefs.backdropColors = []
        browser.prefs.sidebar = true
        let tab = browser.open(URL(string: "about:blank#transparency-verification")!, foreground: true)
        tab.page.navigate(html: "<html><body style='background:white;color:black;margin:40px;font:24px system-ui'>Opaque page</body></html>", base: nil)
        target.contentView = NSHostingView(rootView: ContentView(browser: browser))
        fixture.orderFrontRegardless()
        target.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let captured = try #require(content.windows.first { $0.windowID == CGWindowID(target.windowNumber) })
        let display = try #require(content.displays.first { $0.frame.intersects(captured.frame) })
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 880
        config.height = 660
        config.showsCursor = false
        config.sourceRect = CGRect(x: captured.frame.minX - display.frame.minX,
                                   y: captured.frame.minY - display.frame.minY, width: 880, height: 660)
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/transparency-proof")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func capture(_ name: String) async throws -> TransparencyPixels {
            fixture.orderFrontRegardless()
            target.orderFrontRegardless()
            try await Task.sleep(nanoseconds: 650_000_000)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: folder.appendingPathComponent(name + ".png"))
            return TransparencyPixels(image)
        }
        let solid = try await capture("solid")
        browser.prefs.backdropTransparency = 0.5
        let half = try await capture("half")
        browser.prefs.backdropTransparency = 1
        let glass = try await capture("glass")
        func backdrop(in view: NSView) -> WindowBackdropView? {
            if let result = view as? WindowBackdropView { return result }
            return view.subviews.lazy.compactMap { backdrop(in: $0) }.first
        }
        let native = try #require(backdrop(in: target.contentView!))
        #expect(native.glass.alphaValue == 1 && !native.glass.isHidden)
        #expect(browser.prefs.backdropColor.hex == "8DB6E6")
        native.glass.isHidden = true
        let clear = try await capture("without-blur")
        native.glass.isHidden = false
        let first = solid.difference(half, x: 130..<190, y: 430..<490)
        let second = half.difference(glass, x: 130..<190, y: 430..<490)
        let page = solid.difference(glass, x: 380..<800, y: 180..<290)
        let report = "Chrome differences: \(first), \(second)\nPage difference: \(page)\nStripe energy, glass: \(glass.stripeEnergy), clear: \(clear.stripeEnergy)\n"
        try report.write(to: folder.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        print(report)
        #expect(first > 5 && second > 5)
        #expect(page < 1)
        #expect(clear.stripeEnergy > 5 && glass.stripeEnergy < clear.stripeEnergy * 0.5)
    }
}

private final class TransparencyStripes: NSView {
    override func draw(_ dirtyRect: NSRect) {
        for x in stride(from: 0, to: Int(bounds.width), by: 8) {
            (x % 16 == 0 ? NSColor.white : NSColor.black).setFill()
            NSRect(x: CGFloat(x), y: 0, width: 8, height: bounds.height).fill()
        }
    }
}

private struct TransparencyPixels {
    let bytes: [UInt8]
    init(_ image: CGImage) {
        var data = [UInt8](repeating: 0, count: 880 * 660 * 4)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 880, height: 660, bitsPerComponent: 8,
                                    bytesPerRow: 880 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 880, height: 660))
        }
        bytes = data
    }
    func difference(_ other: Self, x: Range<Int>, y: Range<Int>) -> Double {
        var sum = 0.0
        for row in y { for col in x { for c in 0..<3 {
            let p = (row * 880 + col) * 4 + c
            sum += abs(Double(bytes[p]) - Double(other.bytes[p]))
        } } }
        return sum / Double(x.count * y.count * 3)
    }
    var stripeEnergy: Double {
        var sum = 0.0
        for y in 430..<490 { for x in 130..<190 { for c in 0..<3 {
            let p = (y * 880 + x) * 4 + c
            sum += abs(Double(bytes[p + 4]) - Double(bytes[p]))
        } } }
        return sum / Double(60 * 60 * 3)
    }
}
