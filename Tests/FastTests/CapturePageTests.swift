import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct CapturePageTests {
    private func withPage(_ body: (PageView) async throws -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = PageView(frame: CGRect(x: 0, y: 0, width: 320, height: 200), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFront(nil)
        defer { window.close() }
        web.navigate(html: Self.fixture, base: URL(string: "https://capture.test/"))
        _ = try await Loaded.until(15) { (try? await web.run("document.readyState === 'complete' && !!document.getElementById('sticky')")) as? Bool == true }
        _ = try await web.run(CaptureScript.source, in: .yab)
        try await body(web)
    }

    private static let fixture = #"""
    <!doctype html><meta name="viewport" content="width=device-width">
    <style>
    html {scroll-behavior:smooth;scroll-snap-type:y mandatory}
    body {margin:0;width:720px;height:735px;background:#2468ac}
    #fixed {position:fixed;top:0;left:0;width:30px;height:30px;background:#ff0000}
    #sticky {position:sticky;top:0;height:20px;width:30px;background:#00ff00}
    #pattern {position:absolute;top:60px;left:40px;width:160px;height:70px;
              background:repeating-linear-gradient(90deg,#102030 0 6px,#f0e0d0 6px 12px);border-radius:25px}
    #glass {position:absolute;top:60px;left:40px;width:160px;height:70px;
            background:#ffffff55;backdrop-filter:blur(8px);border-radius:25px;box-shadow:8px 8px 5px #0008}
    </style>
    <div id="fixed"></div><div style="height:280px"></div>
    <div id="sticky" style="top:0px!important"></div><div id="pattern"></div><div id="glass"></div>
    <script>
    addEventListener('scroll', () => {
      if (scrollY > 300 && !document.getElementById('secret')) {
        const field = document.createElement('input'); field.id='secret'; field.type='email';
        field.value='private@example.test'; field.style='position:absolute;left:100px;top:510px;width:140px;height:25px';
        document.body.appendChild(field);
      }
    });
    </script>
    """#

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        // colorAt returns NSCalibratedRGB even for an sRGB bitmap. Converting
        // that color to sRGB applies a second profile transform on macOS 27.
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
                                            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return NSColor(srgbRed: CGFloat(bytes[offset]) / 255, green: CGFloat(bytes[offset + 1]) / 255,
                       blue: CGFloat(bytes[offset + 2]) / 255, alpha: CGFloat(bytes[offset + 3]) / 255)
    }

    @Test func pixelReaderRespectsSRGB() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        let colors: [[CGFloat]] = [[1, 0, 0, 1], [0, 1, 0, 1], [36.0 / 255, 104.0 / 255, 172.0 / 255, 1]]
        for components in colors {
            context.setFillColor(try #require(CGColor(colorSpace: space, components: components)))
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            let color = try pixel(image, x: 1, y: 1)
            #expect(matches(color, components[0], components[1], components[2]))
        }
    }

    private func matches(_ color: NSColor, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
        abs(color.redComponent - r) < 0.04 && abs(color.greenComponent - g) < 0.04 && abs(color.blueComponent - b) < 0.04
    }

    @Test(arguments: [1.0, 1.25])
    func screenPaintSurvivesAllTilesAndFractionalZoom(_ zoom: Double) async throws {
        try await withPage { web in
            web.pageZoom = zoom
            _ = try await web.call("window.scrollTo({left:0,top:0,behavior:'instant'}); return true")
            let width = 352
            let visible = try await web.snapshot(PageShot(width: CGFloat(width) / (web.window?.backingScaleFactor ?? 1)))
            let reference = try #require(visible.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let result = try #require(await CapturePage.take(web, rect: CGRect(x: 0, y: 0, width: 320, height: 735 * zoom),
                                                           pixelWidth: width, zoom: zoom, valid: { true }))
            if let folder = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] {
                for (name, image) in [("visible", reference), ("whole", result.image)] {
                    let file = URL(fileURLWithPath: folder).appendingPathComponent("capture-\(name)-\(zoom).png")
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
                }
            }
            #expect(result.image.width == width)
            #expect(result.image.height == Int((735 * zoom * 1.1).rounded()))
            // The first tile's composited glass must match the ordinary
            // visible screenshot, rather than a PDF approximation.
            for (x, y) in [(70, 90), (170, 100), (225, 150)] {
                let a = try pixel(result.image, x: x, y: y), b = try pixel(reference, x: x, y: y)
                #expect(abs(a.redComponent - b.redComponent) < 0.04)
                #expect(abs(a.greenComponent - b.greenComponent) < 0.04)
                #expect(abs(a.blueComponent - b.blueComponent) < 0.04)
            }
            let first = try pixel(result.image, x: 10, y: 10)
            print("CAPTURE_PIXEL zoom=\(zoom) y=10 rgb=\(first.redComponent),\(first.greenComponent),\(first.blueComponent)")
            #expect(matches(first, 1, 0, 0))
            // No repeated fixed header at the top of later tiles. Check
            // either side of every seam, including the clamped last tile.
            for y in [219, 220, 221, 439, 440, 441, result.image.height - 2] {
                let color = try pixel(result.image, x: 10, y: y)
                print("CAPTURE_PIXEL zoom=\(zoom) y=\(y) rgb=\(color.redComponent),\(color.greenComponent),\(color.blueComponent)")
                #expect(matches(color, 36.0 / 255, 104.0 / 255, 172.0 / 255))
            }
            #expect(matches(try pixel(result.image, x: 10, y: Int(290 * zoom * 1.1)), 0, 1, 0))
            #expect(result.secrets.contains { abs($0.minY - 510 * zoom) < 3 && $0.width > 100 })
            #expect(try await web.run("scrollX === 0 && scrollY === 0") as? Bool == true)
            #expect(try await web.run("getComputedStyle(document.getElementById('sticky')).position === 'sticky'") as? Bool == true)
        }
    }

    @Test func tallFragmentDoesNotAcquireTheFixedHeader() async throws {
        try await withPage { web in
            let result = try #require(await CapturePage.take(web, rect: CGRect(x: 0, y: 250, width: 320, height: 400),
                                                           pixelWidth: 320, zoom: 1, valid: { true }))
            #expect(matches(try pixel(result.image, x: 10, y: 5), 36.0 / 255, 104.0 / 255, 172.0 / 255))
            #expect(matches(try pixel(result.image, x: 10, y: 40), 0, 1, 0))
            #expect(try await web.run("getComputedStyle(document.getElementById('fixed')).visibility === 'visible'") as? Bool == true)
        }
    }

    @Test func restoresBothScrollAxesAndInlineStyles() async throws {
        try await withPage { web in
            _ = try await web.run("window.scrollTo({left:80,top:125,behavior:'instant'}); true")
            let result = await CapturePage.take(web, rect: CGRect(x: -80, y: -125, width: 320, height: 735),
                                                pixelWidth: 320, zoom: 1, valid: { true })
            #expect(result != nil)
            #expect(try await web.run("scrollX === 80 && scrollY === 125") as? Bool == true)
            #expect(try await web.run("document.getElementById('sticky').getAttribute('style') === 'top: 0px !important;'") as? Bool == true)
            #expect(try await web.run("getComputedStyle(document.getElementById('fixed')).visibility === 'visible'") as? Bool == true)
            #expect(try await web.run("getComputedStyle(document.documentElement).scrollBehavior === 'smooth'") as? Bool == true)
            #expect(try await web.run("typeof window.__yabCaptureTiles", in: .yab) as? String == "undefined")
        }
    }

    @Test func cancellationDiscardsPartialImageAndRestoresPage() async throws {
        try await withPage { web in
            _ = try await web.run("window.scrollTo({left:80,top:125,behavior:'instant'}); true")
            var calls = 0
            let result = await CapturePage.take(web, rect: CGRect(x: -80, y: -125, width: 320, height: 735),
                                                pixelWidth: 320, zoom: 1) {
                calls += 1
                return calls < 5
            }
            #expect(result == nil)
            #expect(calls >= 5)
            #expect(try await web.run("scrollX === 80 && scrollY === 125") as? Bool == true)
            #expect(try await web.run("getComputedStyle(document.getElementById('sticky')).position === 'sticky'") as? Bool == true)
            #expect(try await web.run("getComputedStyle(document.getElementById('fixed')).visibility === 'visible'") as? Bool == true)
            #expect(try await web.run("typeof window.__yabCaptureTiles", in: .yab) as? String == "undefined")
        }
    }

    @Test func invalidOutputRestoresCaptureState() async throws {
        try await withPage { web in
            let result = await CapturePage.take(web, rect: CGRect(x: 0, y: 0, width: 320, height: 735),
                                                pixelWidth: 100_000, zoom: 1, valid: { true })
            let state = try await web.run("typeof window.__yabCaptureTiles", in: .yab) as? String
            let restored = try await web.run("getComputedStyle(document.documentElement).scrollBehavior === 'smooth'") as? Bool
            #expect(result == nil)
            #expect(state == "undefined")
            #expect(restored == true)
        }
    }
}
