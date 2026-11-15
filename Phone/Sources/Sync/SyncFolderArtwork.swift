import UIKit
import ImageIO
import Observation
#if canImport(SyncKit)
import SyncKit
#endif

/// The current account's custom artwork and public site icons. The journal already
/// persists their bytes, so hydration needs no second files or website cache.
@MainActor
@Observable
final class SyncFolderArtwork {
    private(set) var account: String?
    private var sites: [String: String] = [:]
    private var sources: [String: Data] = [:]
    @ObservationIgnored private let decoded: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 32; cache.totalCostLimit = 2 * 1024 * 1024
        return cache
    }()

    func replace(account: String, icons: [SyncIcon]) {
        let next = Dictionary(icons.map { ($0.id, $0.data) }, uniquingKeysWith: { _, last in last })
        if self.account != account { reset() }
        self.account = account
        for (id, old) in sources where next[id] != old { decoded.removeObject(forKey: id as NSString) }
        sources = next
        sites = Dictionary(icons.compactMap { icon in icon.origin.map { ($0.absoluteString, icon.id) } }, uniquingKeysWith: { _, last in last })
    }

    func apply(account: String, id: String, icon: SyncIcon?) {
        guard self.account == account else { return }
        sites = sites.filter { $0.value != id }
        if let icon, icon.id == id, let origin = icon.origin { sites[origin.absoluteString] = id }
        let next = icon?.id == id ? icon?.data : nil
        guard sources[id] != next else { return }
        sources[id] = next
        decoded.removeObject(forKey: id as NSString)
    }

    func reset() {
        sources = [:]; sites = [:]; account = nil; decoded.removeAllObjects()
    }

    func siteImage(for page: URL?, isPrivate: Bool = false) -> UIImage? {
        guard !isPrivate, let page, let origin = SyncIcon.siteOrigin(page), let id = sites[origin.absoluteString] else { return nil }
        return image("image:" + id)
    }

    func image(_ mark: String, isPrivate: Bool = false) -> UIImage? {
        guard !isPrivate, account != nil, mark.hasPrefix("image:") else { return nil }
        let id = String(mark.dropFirst(6))
        // Read the observed source before the cache: an arriving record must
        // redraw a folder which previously had only its grid fallback.
        guard SyncIcon.validName(id), let data = sources[id] else { return nil }
        if let hit = decoded.object(forKey: id as NSString) { return hit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let kind = CGImageSourceGetType(source), kind as String == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0, height.intValue > 0, width.intValue <= 512, height.intValue <= 512,
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: pixels)
        decoded.setObject(image, forKey: id as NSString, cost: pixels.bytesPerRow * pixels.height)
        return image
    }
}
