import AppKit
import SwiftUI

/// An extension's icon that fills its whole square, corners and all, gets
/// round corners, as an app's icon has: beside the round and already
/// rounded ones on the pins and in the lists, a sharp square read as
/// something else (a picture, a page). One that has its own shape is left
/// as it is.
enum ExtensionIconShape {
    /// The corner's radius as a share of the side, an app icon's.
    static let radius: CGFloat = 0.225

    /// The same icon asked for again (every redraw of the pins asks for
    /// it) is cut once.
    @MainActor private static let cut: NSCache<NSImage, NSImage> = {
        let cache = NSCache<NSImage, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    @MainActor
    static func rounded(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        if let done = cut.object(forKey: image) { return done }
        let out = isSquare(image) ? clipped(image) : image
        cut.setObject(out, forKey: image)
        return out
    }

    /// Whether its four corners are painted: drawn small, the pixel just
    /// inside each corner is nearly opaque.
    static func isSquare(_ image: NSImage) -> Bool {
        let side = 32
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let corners = [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)]
        return corners.allSatisfy { x, y in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.8 }
    }

    /// Cut to a rounded square, the continuous corner SwiftUI draws.
    static func clipped(_ image: NSImage) -> NSImage {
        let size = image.size
        return NSImage(size: size, flipped: false) { rect in
            let path = RoundedRectangle(cornerRadius: min(rect.width, rect.height) * radius, style: .continuous).path(in: rect).cgPath
            NSBezierPath(cgPath: path).addClip()
            image.draw(in: rect)
            return true
        }
    }
}
