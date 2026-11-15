import AppKit
import ScreenCaptureKit

extension Bench {
    /// Read in the app that owns the cursor. A different process's
    /// currentSystemCursor is deprecated and may be nil (NSCursor.h).
    /// The HID probe also checks foreground/window ownership at this point.
    static func cursorState(windowNumber: Int? = nil) -> [String: Any] {
        guard Store.testing else { return ["error": "cursor-state requires an isolated test run"] }
        func image(_ cursor: NSCursor) -> Data? {
            cursor.image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .png, properties: [:])
        }
        let cursor = NSCursor.current
        guard let picture = image(cursor) else { return ["error": "Current app cursor has no image"] }
        let references: [(String, NSCursor)] = [("text", .iBeam), ("pointer", .pointingHand), ("arrow", .arrow)]
        let shape = references.first { reference in
            cursor.hotSpot == reference.1.hotSpot && picture == image(reference.1)
        }?.0 ?? "custom"
        // NSPopover's own isKeyWindow can differ from NSApp.keyWindow.
        // Inspect the original popup identity the HID probe is testing.
        let window: NSWindow?
        if let windowNumber { window = NSApp.window(withWindowNumber: windowNumber) }
        else { window = NSApp.keyWindow }
        let point = NSEvent.mouseLocation
        let hit = window.flatMap { window in
            window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: point))
        }
        return ["cursor": shape, "image": picture.base64EncodedString(),
                "hotspot": [cursor.hotSpot.x, cursor.hotSpot.y],
                "pid": ProcessInfo.processInfo.processIdentifier,
                "foregroundPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                "window": window?.windowNumber ?? 0, "key": window?.isKeyWindow ?? false,
                "acceptsMouseMovedEvents": window?.acceptsMouseMovedEvents ?? false,
                "position": [point.x, (NSScreen.screens.first?.frame.maxY ?? 0) - point.y],
                "hit": hit.map { String(describing: type(of: $0)) } ?? "none"]
    }

    /// The layer renderer cannot read another process's CALayerHost pixels.
    /// As in SharePicker, currentProcess supplies only our own windows and
    /// needs no Screen Recording permission. Isolated bench runs only.
    static func captureOwnWindow(_ window: NSWindow, path: String, cursor: Bool = false,
                                 answer: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.currentProcess
                guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    answer(["error": "Own window is not available for capture"])
                    return
                }
                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width * window.backingScaleFactor)
                configuration.height = Int(window.frame.height * window.backingScaleFactor)
                configuration.showsCursor = cursor
                configuration.ignoreShadowsSingleWindow = true
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    answer(["error": "Own window capture has no PNG"])
                    return
                }
                try data.write(to: URL(fileURLWithPath: path))
                let rect = window.contentView.map { $0.convert($0.bounds, to: nil) } ?? .zero
                answer(["path": path, "backend": "ScreenCaptureKit.currentProcess", "cursor": cursor, "window": window.windowNumber,
                        "size": [window.frame.width, window.frame.height],
                        "content": [rect.minX, window.frame.height - rect.maxY, rect.width, rect.height]])
            } catch { answer(["error": String(describing: error)]) }
        }
    }
}
