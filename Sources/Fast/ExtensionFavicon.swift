import AppKit

// Chrome's favicon permission, chrome-extension://<id>/_favicon/?pageUrl=…,
// answered from the icons Yab keeps (Icons.swift): the shim turns such an
// image or fetch into "favicon.get" (extension-shims.js). Like Chromium's,
// only what the browser already has, nothing fetched for it; a site it has
// no icon for gets one plain globe, the same picture every time, which is
// how OneTab tells "no icon" from an icon and asks elsewhere.

@MainActor
enum ExtensionFavicon {
    /// Answers already drawn, by site and size: a list of hundreds of tabs
    /// asks for each, and many are the same site.
    private static var drawn: [String: String] = [:]

    /// A PNG data: URL of the page's site icon at `size` points, drawn
    /// twice as many pixels across for a Retina screen.
    static func dataURL(for page: URL?, size: Int) -> String {
        let points = max(16, min(128, size))
        let host = page?.host()?.lowercased() ?? ""
        let favicons = Favicons.shared
        let found: (key: String, image: NSImage)? = host.isEmpty ? nil : [host, Favicons.bare(host), "www." + Favicons.bare(host)]
            .lazy.compactMap { key in favicons.cached(key).map { (key: key, image: $0) } }.first
        let key = (found?.key ?? "") + "@\(points)" + (Favicons.dark ? "d" : "")
        if let hit = drawn[key] { return hit }
        let image = found?.image ?? globe
        guard let answer = png(image, pixels: points * 2).map({ "data:image/png;base64," + $0.base64EncodedString() }) else { return "" }
        if drawn.count > 500 { drawn.removeAll() }
        drawn[key] = answer
        return answer
    }

    /// The icon for a site with none, gray as Chromium's.
    private static var globe: NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            .applying(.init(paletteColors: [.systemGray]))
        return NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
    }

    private static func png(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // Square, centered, whatever shape it came in.
        let size = image.size
        let scale = size.width > 0 && size.height > 0 ? min(CGFloat(pixels) / size.width, CGFloat(pixels) / size.height) : 1
        let drawnSize = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: NSRect(x: (CGFloat(pixels) - drawnSize.width) / 2, y: (CGFloat(pixels) - drawnSize.height) / 2,
                              width: drawnSize.width, height: drawnSize.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
