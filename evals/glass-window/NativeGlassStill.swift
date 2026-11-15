// Native composited proof: one isolated Yab window above one owned backdrop.
// NativeGlassStill PID WINDOW PNG dark|white|busy PAGE_RECT_JSON [BLACKOUT_PIDS...]
// No activation, desktop changes, permission requests or external window ordering.
import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text); fflush(stdout)
    }
}

func fail(_ message: String) -> NSError {
    NSError(domain: "NativeGlassStill", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func rectJSON(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height] }

func liveWindows() -> [[String: Any]] {
    CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
}

func frameOf(_ row: [String: Any]) -> CGRect {
    guard let bounds = row[kCGWindowBounds as String] as? [String: Any] else { return .zero }
    return CGRect(dictionaryRepresentation: bounds as CFDictionary) ?? .zero
}

func numberOf(_ row: [String: Any]) -> UInt32 {
    (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
}

func curtainCoverage(_ rows: [[String: Any]], pids: Set<Int32>, target: CGRect) throws -> [UInt32] {
    let covering = rows.filter {
        pids.contains(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1)
            && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) >= 0.99
            && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0
            && frameOf($0).contains(target)
    }.map(numberOf)
    if !pids.isEmpty && covering.isEmpty { throw fail("blackout is not raised over the complete target frame") }
    return covering
}

final class OwnedBackdrop: NSView {
    let kind: String
    init(kind: String, frame: NSRect) { self.kind = kind; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (kind == "dark" ? NSColor(srgbRed: 0.035, green: 0.045, blue: 0.07, alpha: 1) : .white).setFill()
        bounds.fill()
        guard kind == "busy" else { return }
        let colors: [NSColor] = [.white, .black, .systemYellow, .systemPink, .systemCyan, .systemGreen]
        let cell: CGFloat = 58
        for x in stride(from: CGFloat(0), to: bounds.width, by: cell) {
            for y in stride(from: CGFloat(0), to: bounds.height, by: cell) {
                colors[(Int(x / cell) + Int(y / cell) * 3) % colors.count].setFill()
                NSRect(x: x, y: y, width: cell, height: cell).fill()
            }
        }
        // Deliberately structured high frequency content like another document.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .bold),
            .foregroundColor: NSColor.black, .backgroundColor: NSColor.white,
        ]
        for y in stride(from: CGFloat(20), to: bounds.height, by: 76) {
            ("OTHER WINDOW  012345  // high contrast text" as NSString)
                .draw(at: NSPoint(x: 18, y: y), withAttributes: attributes)
        }
    }
}

func sample(_ image: CGImage, rect: CGRect) -> [String: Any] {
    let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    guard !clipped.isEmpty, let part = image.cropping(to: clipped),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return ["available": false] }
    var rgba = [UInt8](repeating: 0, count: 4)
    let made = rgba.withUnsafeMutableBytes { bytes -> Bool in
        guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .high
        context.draw(part, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    return ["available": made, "pixel_rect": rectJSON(clipped), "rgba_255": rgba.map(Int.init)]
}

let args = CommandLine.arguments
guard args.count >= 6, let pid = Int32(args[1]), let targetID = UInt32(args[2]),
      ["dark", "white", "busy"].contains(args[4]),
      let pageData = args[5].data(using: .utf8),
      let page = (try? JSONSerialization.jsonObject(with: pageData)) as? [Double], page.count == 4 else {
    emit(["error": "NativeGlassStill PID WINDOW PNG dark|white|busy PAGE_RECT_JSON [BLACKOUT_PIDS...]"])
    exit(2)
}
guard CGPreflightScreenCaptureAccess() else {
    emit(["error": "Screen Recording unavailable for this native helper", "permission_requested": false])
    exit(3)
}
let output = URL(fileURLWithPath: args[3])
let kind = args[4]
let curtainPIDs = Set(args.dropFirst(6).compactMap(Int32.init))
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.finishLaunching()
Task { @MainActor in
    var owned: NSWindow?
    do {
        let initialRows = liveWindows()
        guard let targetRow = initialRows.first(where: { numberOf($0) == targetID }),
              (targetRow[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (targetRow[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
            throw fail("isolated target is not an observed normal-level window of the owned process")
        }
        let targetFrame = frameOf(targetRow)
        let coveringBefore = try curtainCoverage(initialRows, pids: curtainPIDs, target: targetFrame)
        let initial = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = initial.displays.first(where: { $0.frame.contains(targetFrame) }),
              let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
              }) else { throw fail("target must fit on one display") }
        let underlay = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        owned = underlay
        underlay.title = "Yab owned glass test " + kind
        underlay.isReleasedWhenClosed = false
        underlay.isOpaque = true
        underlay.hasShadow = false
        underlay.backgroundColor = .white
        underlay.ignoresMouseEvents = true
        underlay.level = .normal
        underlay.collectionBehavior = [.stationary, .ignoresCycle]
        underlay.contentView = OwnedBackdrop(kind: kind, frame: NSRect(origin: .zero, size: screen.frame.size))
        underlay.order(.below, relativeTo: Int(targetID))
        underlay.display()
        try await Task.sleep(nanoseconds: 150_000_000)
        // Reassert only the owned underlay after WindowServer registration.
        underlay.order(.below, relativeTo: Int(targetID))
        try await Task.sleep(nanoseconds: 500_000_000)
        let ordered = liveWindows()
        guard let targetIndex = ordered.firstIndex(where: { numberOf($0) == targetID }),
              let underlayIndex = ordered.firstIndex(where: { numberOf($0) == UInt32(underlay.windowNumber) }),
              underlayIndex > targetIndex,
              (ordered[underlayIndex][kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else {
            throw fail("owned backdrop is not physically below the isolated target")
        }
        let interference = ordered[(targetIndex + 1)..<underlayIndex].filter {
            (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
                && frameOf($0).intersects(targetFrame)
        }.count
        guard interference == 0 else { throw fail("another window is physically between the target and owned backdrop") }
        let coveringAfter = try curtainCoverage(ordered, pids: curtainPIDs, target: targetFrame)
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = available.windows.first(where: { $0.windowID == targetID }),
              let backdrop = available.windows.first(where: { $0.windowID == UInt32(underlay.windowNumber) }) else {
            throw fail("target or owned backdrop is unavailable to ScreenCaptureKit")
        }
        let captureFrame = targetFrame.insetBy(dx: -16, dy: -16).intersection(display.frame)
        let scale: CGFloat = 2
        let config = SCStreamConfiguration()
        config.sourceRect = captureFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(captureFrame.width * scale)
        config.height = Int(captureFrame.height * scale)
        config.showsCursor = false
        config.capturesAudio = false
        config.shouldBeOpaque = false
        config.colorSpaceName = CGColorSpace.sRGB
        config.scalesToFit = true
        config.captureResolution = .best
        let filter = SCContentFilter(display: display, including: [target, backdrop])
        filter.includeMenuBar = false
        let picture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw fail("cannot create PNG destination")
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw fail("cannot write PNG") }
        let offset = CGPoint(x: targetFrame.minX - captureFrame.minX, y: targetFrame.minY - captureFrame.minY)
        func patch(_ x: Double, _ y: Double) -> [String: Any] {
            sample(picture, rect: CGRect(x: (offset.x + CGFloat(x) - 3) * scale,
                y: (offset.y + CGFloat(y) - 3) * scale, width: 6 * scale, height: 6 * scale))
        }
        let pageSample = patch(page[0] + page[2] * 0.75, page[1] + page[3] * 0.85)
        let coveringFinal = try curtainCoverage(liveWindows(), pids: curtainPIDs, target: targetFrame)
        emit(["capture": "ScreenCaptureKit.displayIncludingTargetAndOwnedBackdrop", "png": output.path,
            "size": [picture.width, picture.height], "scale": scale,
            "target_pid": pid, "target_window": targetID, "target_frame_points": rectJSON(targetFrame),
            "capture_frame_points": rectJSON(captureFrame), "display_id": display.displayID,
            "app_offset_points": [offset.x, offset.y], "backdrop": kind,
            "owned_backdrop_window": underlay.windowNumber, "owned_backdrop_pid": ProcessInfo.processInfo.processIdentifier,
            "owned_backdrop_level": 0, "owned_backdrop_opaque": true,
            "target_order_index": targetIndex, "backdrop_order_index": underlayIndex,
            "owned_backdrop_physically_below_target": true, "intervening_intersecting_windows": interference,
            "included_windows": [targetID, UInt32(underlay.windowNumber)],
            "capture_other_windows": false, "capture_menu_bar": false, "cursor": false, "audio": false,
            "blackout_pids": Array(curtainPIDs).sorted(), "covering_before": coveringBefore,
            "covering_after": coveringAfter, "covering_final": coveringFinal,
            "permission_requested": false, "system_desktop_changed": false,
            "system_reduce_transparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            "system_increase_contrast": NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            "page_sample": pageSample,
            "sidebar_sample": patch(80, min(Double(targetFrame.height) - 65, 470)),
            "toolbar_sample": patch(min(Double(targetFrame.width) - 50, 500), 24)])
        underlay.orderOut(nil)
        underlay.close()
        exit(0)
    } catch {
        owned?.orderOut(nil)
        owned?.close()
        emit(["error": String(describing: error), "permission_requested": false,
              "system_desktop_changed": false])
        exit(1)
    }
}
RunLoop.main.run()
