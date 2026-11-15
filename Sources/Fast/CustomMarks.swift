import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum CustomMarks {
    private static var cache: [String: NSImage] = [:]

    static func image(_ mark: String?) -> NSImage? {
        guard let mark, !mark.isEmpty else { return nil }
        if let cached = cache[mark] { return cached }
        let image: NSImage?
        if mark.hasPrefix("image:") {
            let name = String(mark.dropFirst(6))
            guard name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".png") else { return nil }
            image = NSImage(contentsOf: directory.appendingPathComponent(name))
        } else if mark.hasPrefix("icon:") {
            // One of Change Icon's icons, a template the tab's ink fills.
            image = IconMarks.art(String(mark.dropFirst(5)))
        } else if mark.hasPrefix("space:") {
            image = SpaceIconArt.art(String(mark.dropFirst(6)))
        } else if mark.count > 1, mark.contains(":") {
            // A kind of mark a newer Yab on another Mac knows: its site's
            // icon here, never the words drawn as though an emoji.
            return nil
        } else {
            image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { _ in
                let text = NSAttributedString(string: mark, attributes: [.font: NSFont.systemFont(ofSize: 27)])
                let size = text.size()
                text.draw(at: NSPoint(x: (32 - size.width) / 2, y: (32 - size.height) / 2))
                return true
            }
        }
        if let image { cache[mark] = image }
        return image
    }

    private static var directory: URL { Store.folder.appendingPathComponent("custom-icons", isDirectory: true) }

    static func chooseImage(_ picked: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { picked(nil); return }
            guard response == .OK, let url = panel.url,
                  let source = NSImage(contentsOf: url), source.size.width > 0, source.size.height > 0,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { picked(nil); return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let scale = min(128 / source.size.width, 128 / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            source.draw(in: NSRect(x: (128 - size.width) / 2, y: (128 - size.height) / 2, width: size.width, height: size.height))
            NSGraphicsContext.restoreGraphicsState()
            guard let data = bitmap.representation(using: .png, properties: [:]) else { picked(nil); return }
            let name = UUID().uuidString + ".png"
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                picked("image:" + name)
            } catch {
                picked(nil)
                // Said in the corner, as every notice is; the menu that
                // asked has closed, and nothing on screen shows it.
                MainActor.assumeIsolated {
                    (BrowserWindows.shared.activeBrowser ?? Links.browser)?
                        .announce("Couldn’t save the icon", mark: "exclamationmark.triangle")
                }
            }
        }
    }
}

/// The menu's Change Icon…: the picker, hanging from the pin, row or
/// folder the menu was opened on (IconPicker.swift).
struct ChangeIconItem: View {
    let target: IconPicking.Target
    var mark: String? = nil

    var body: some View {
        Button("Change Icon…", mark: mark) { IconPicking.shared.open(target) }
    }
}

struct RefreshIconItem: View {
    let tab: Tab

    var body: some View {
        Button("Refresh Site Icon", mark: "arrow.clockwise") { Favicons.shared.refresh(tab) }
            .disabled(!Favicons.canRefresh(tab))
    }
}
