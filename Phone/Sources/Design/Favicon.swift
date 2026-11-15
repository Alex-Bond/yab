import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var syncedArtwork: SyncFolderArtwork? = nil
}

/// A site's icon. The picture from the app's Favicons when it carries
/// one (named by the site's key, `figma.png`, or its host, `figma.com.png`),
/// else a drawn tile: the site's color and its letter, as the prototype draws
/// the sites it has no picture for (.fv-draw).
struct Favicon: View {
    /// The prototype's key for the site: "figma", "hn", "tap"…
    let icon: String
    var host: String? = nil
    var size: CGFloat = 20
    var url: URL? = nil
    var isPrivate: Bool = false
    var mark: String? = nil
    var artwork: SyncFolderArtwork? = nil
    @Environment(\.syncedArtwork) private var syncedArtwork
    @Environment(\.colorScheme) private var scheme

    private var resolvedURL: URL? {
        url ?? (host ?? FaviconImages.host(for: icon)).flatMap { URL(string: "https://" + $0) }
    }

    var body: some View {
        Group {
            if let mark, mark.hasPrefix("icon:"), let image = MacIconMarks.image(String(mark.dropFirst(5))) {
                Image(uiImage: image).resizable().renderingMode(.template).scaledToFit().foregroundStyle(Ink.primary)
            } else if let mark, let image = (artwork ?? syncedArtwork)?.image(mark, isPrivate: isPrivate) {
                Image(uiImage: image).resizable().renderingMode(.original).scaledToFit()
            } else if let mark, !mark.isEmpty, !mark.contains(":"), !isPrivate {
                Text(mark).font(.system(size: size))
            } else if icon == "mail" {
                Glyph(.email1, size: size, color: Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255))
            } else if icon == "face" {
                AgentFace(size: size)
            } else if let image = (artwork ?? syncedArtwork)?.siteImage(for: resolvedURL, isPrivate: isPrivate)
                ?? FaviconImages.image(icon, host: host, url: resolvedURL, isPrivate: isPrivate) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    // A black mark on clear (GitHub's) is lost on a dark
                    // ground: it stands on a light plate there.
                    .background {
                        if scheme == .dark, FaviconImages.isDarkMark(image) { shape.fill(Color.white) }
                    }
                    .clipShape(shape)
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: resolvedURL?.absoluteString) {
            guard !isPrivate, icon != "mail", icon != "face",
                  let page = resolvedURL else { return }
            await SiteIcons.shared.load(for: page)
        }
    }

    /// Round for the sites whose marks are round, else a rounded square (23%).
    private var shape: AnyShape {
        Favicon.round.contains(icon) ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous))
    }

    private var drawn: some View {
        let tile = Favicon.drawn[icon] ?? (RGB(0x8E, 0x8E, 0x93), String((icon.first ?? "?").uppercased()))
        let white = tile.0 == RGB(255, 255, 255)
        return RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
            .fill(Color(rgb: tile.0))
            .overlay {
                if white {
                    RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12), lineWidth: 1)
                }
            }
            .overlay {
                Text(tile.1)
                    .font(.system(size: (size * 0.5).rounded(), weight: .bold))
                    .foregroundStyle(white ? Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(width: size, height: size)
    }

    /// The prototype's round marks (ROUND_FAV).
    static let round: Set<String> = ["github", "lumen", "nordbutik", "google"]
    /// The prototype's drawn tiles (DRAWN_FAV).
    static let drawn: [String: (RGB, String)] = [
        "orbit": (RGB(0x5B, 0x47, 0xE0), "O"), "paul": (RGB(0xB3, 0x1B, 0x1B), "PG"), "rams": (RGB(0xFF, 0xFF, 0xFF), "W"),
        "nng": (RGB(0x1B, 0x1B, 0x1B), "N"), "tap": (RGB(0xE2, 0x00, 0x1A), "T"), "linnea": (RGB(0x8C, 0x6E, 0x4E), "L"),
        "skandi": (RGB(0x2F, 0x4A, 0x3A), "S"), "llm": (RGB(0xFF, 0x00, 0x33), ""),
    ]
}

/// Favicon pictures, read from the bundle once. Favicons (Phone/Resources) names
/// them by host; its favicons.json says which host is which key.
@MainActor
enum FaviconImages {
    private static var cache: [String: UIImage] = [:]
    private static var missing: Set<String> = []

    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Favicons") }

    /// The key to file name map: "hn" is news.ycombinator.com.png.
    private static let hosts: [String: String] = {
        struct Entry: Decodable { let key: String; let host: String }
        guard let url = folder?.appendingPathComponent("favicons.json"), let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.key, $0.host) }, uniquingKeysWith: { a, _ in a })
    }()

    static func host(for icon: String) -> String? { hosts[icon] }

    private static var darkMarks: [ObjectIdentifier: Bool] = [:]

    /// A mark drawn dark on a clear ground: what shows of it is nearly black.
    static func isDarkMark(_ image: UIImage) -> Bool {
        let id = ObjectIdentifier(image)
        if let known = darkMarks[id] { return known }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { bytes in
            guard let cg = image.cgImage, let context = CGContext(
                data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        var shown = 0.0, light = 0.0, clear = 0
        if drawn {
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let a = Double(pixels[i + 3]) / 255
                if a < 0.1 { clear += 1; continue }
                // Premultiplied: undo it for the color's own lightness.
                let l = (0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])) / 255 / a
                shown += a
                light += a * l
            }
        }
        let dark = drawn && clear >= side * side / 8 && shown > 0 && light / shown < 0.25
        darkMarks[id] = dark
        return dark
    }

    static func image(_ icon: String, host: String?, url: URL? = nil, isPrivate: Bool = false) -> UIImage? {
        if !isPrivate {
            if let url, let image = SiteIcons.shared.image(for: url) { return image }
            if url == nil, let host, let image = SiteIcons.shared.image(for: host) { return image }
        }
        let key = icon + "|" + (host ?? "")
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }
        guard let folder else { return nil }
        let names = [hosts[icon], icon, host].compactMap { $0 }.filter { !$0.isEmpty }
        for name in names {
            for ext in ["png", "webp", "jpg"] {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if let image = UIImage(contentsOfFile: url.path) {
                    cache[key] = image
                    return image
                }
            }
        }
        missing.insert(key)
        return nil
    }
}

/// The agent's face, where a chat kept as a tab wears its icon: a circle
/// with two eyes, the Mac's AgentFace at rest.
struct AgentFace: View {
    var size: CGFloat = 20
    var color: Color = Ink.primary
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 24
            var face = Path()
            face.addEllipse(in: CGRect(x: 3 * k, y: 3 * k, width: 18 * k, height: 18 * k))
            face.move(to: CGPoint(x: 9.5 * k, y: 9.75 * k)); face.addLine(to: CGPoint(x: 9.5 * k, y: 12.25 * k))
            face.move(to: CGPoint(x: 14.5 * k, y: 9.75 * k)); face.addLine(to: CGPoint(x: 14.5 * k, y: 12.25 * k))
            context.stroke(face, with: .color(color), style: StrokeStyle(lineWidth: lineWidth * k, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
