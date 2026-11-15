import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture saved from a page as a file any app takes. Sites serve WebP and
/// AVIF because browsers read them; plenty of what a file is dragged to next
/// does not. A still one becomes a PNG with its pixels and color kept, and
/// everything else stays byte for byte: a JPEG is not made bigger for
/// nothing, and an animated WebP would lose its frames (docs/capture.md).
enum PictureFile {
    private static let awkward = ["org.webmproject.webp", "public.avif"]

    /// The PNG of a still WebP or AVIF, nil for anything else.
    static func portable(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let kind = CGImageSourceGetType(source) as String?, awkward.contains(kind),
              CGImageSourceGetCount(source) == 1 else { return nil }
        let out = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(target, source, 0, nil)
        return CGImageDestinationFinalize(target) ? out as Data : nil
    }

    /// A finished download made portable where it lies: the file to show for
    /// it from now on, the same one when there was nothing to do or the PNG
    /// could not be written.
    static func portable(file: URL) -> URL {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), let png = portable(data) else { return file }
        let folder = file.deletingLastPathComponent(), stem = file.deletingPathExtension().lastPathComponent
        var target = folder.appendingPathComponent(stem + ".png"), n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) \(n).png")
            n += 1
        }
        guard (try? png.write(to: target, options: .withoutOverwriting)) != nil else { return file }
        try? FileManager.default.removeItem(at: file)
        return target
    }
}
