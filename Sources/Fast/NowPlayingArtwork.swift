import AppKit
import ImageIO
import MediaPlayer
import YabCoreClient

/// System artwork retains the source pixels. Accent's 112px thumbnail is
/// deliberately only for the small in-app player and its color analysis.
enum NowPlayingArtwork {
    static func ranked(_ rows: [JSONValue]) -> [JSONValue] {
        rows.enumerated().sorted {
            let lhs = area($0.element), rhs = area($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs > rhs
        }.map(\.element)
    }

    private static func area(_ row: JSONValue) -> Double {
        func pixels(_ width: Double, _ height: Double) -> Double {
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
            return width * height
        }
        // Native Chromium supplies size dictionaries; MediaSession JS supplies
        // a whitespace-separated list such as "96x96 512x512".
        if case .array(let sizes) = row["sizes"] {
            return sizes.map { pixels($0["width"].number ?? 0, $0["height"].number ?? 0) }.max() ?? 0
        }
        return (row["sizes"].string ?? "").split(whereSeparator: \.isWhitespace).map { size in
            let dimensions = size.lowercased().split(separator: "x")
            guard dimensions.count == 2, let width = Double(dimensions[0]), let height = Double(dimensions[1]) else { return 0.0 }
            return pixels(width, height)
        }.max() ?? 0
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber,
              width.intValue > 0, height.intValue > 0 else { return nil }
        // ImageIO's transform applies EXIF orientation. The limit is the
        // source's own maximum side, so this retains every original pixel.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width.intValue, height.intValue),
        ] as CFDictionary)
    }

    @MainActor static func item(_ image: CGImage) -> MPMediaItemArtwork {
        let size = NSSize(width: image.width, height: image.height)
        let original = NSImage(cgImage: image, size: size)
        return MPMediaItemArtwork(boundsSize: size) { _ in original }
    }

    @MainActor private static var known: [URL: CGImage] = [:]
    @MainActor private static var waiting: [URL: [(CGImage?) -> Void]] = [:]

    @MainActor static func load(_ url: URL, then: @escaping (CGImage?) -> Void) {
        if let image = known[url] { then(image); return }
        if waiting[url] != nil { waiting[url]?.append(then); return }
        waiting[url] = [then]
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let image = data.flatMap(decode)
            DispatchQueue.main.async {
                if let image {
                    if known.count >= 4 { known.removeAll() }
                    known[url] = image
                }
                let callbacks = waiting.removeValue(forKey: url) ?? []
                callbacks.forEach { $0(image) }
            }
        }.resume()
    }
}
