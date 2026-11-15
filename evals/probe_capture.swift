// One target-window picture beneath the raised blackout, using ScreenCaptureKit.
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

let pid = Int32(CommandLine.arguments[1])!
let path = CommandLine.arguments[2]
let wantedWindow = UInt32(CommandLine.arguments[3]) ?? 0
let curtainPIDs = Set(CommandLine.arguments.dropFirst(4).compactMap(Int32.init))
_ = NSApplication.shared
Task {
    do {
        let all = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        let target = all.compactMap { entry -> (entry: [String: Any], frame: CGRect)? in
            guard entry[kCGWindowOwnerPID as String] as? Int32 == pid,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            if wantedWindow == 0 {
                // WebKit's intentional offscreen rendering room can be
                // larger than the browser. Capture the actual normal app
                // window, never that layer -1 surface at (-20000,-20000).
                guard entry[kCGWindowLayer as String] as? Int == 0,
                      entry[kCGWindowIsOnscreen as String] as? Bool == true,
                      frame.width > 400 && frame.height > 300 else { return nil }
            } else if number != wantedWindow { return nil }
            return (entry, frame)
        }.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        guard let target, let number = target.entry[kCGWindowNumber as String] as? UInt32 else {
            throw NSError(domain: "probe-capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no target window"])
        }
        let layer = target.entry[kCGWindowLayer as String] as? Int ?? 0
        let candidates = all.filter { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32 else { return false }
            return curtainPIDs.contains(owner)
        }
        let covering = candidates.filter { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? Int32, curtainPIDs.contains(owner),
                  entry[kCGWindowIsOnscreen as String] as? Bool == true,
                  ((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) >= 0.99,
                  let curtainLayer = entry[kCGWindowLayer as String] as? Int, curtainLayer > layer,
                  let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
            return frame.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
        }
        var result: [String: Any] = ["window": number, "on_screen": target.entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
            "window_layer": layer, "frame": [target.frame.minX, target.frame.minY, target.frame.width, target.frame.height],
            "blackout_pids": Array(curtainPIDs), "covering_windows": covering.compactMap { $0[kCGWindowNumber as String] as? UInt32 },
            "covering_alphas": covering.compactMap { ($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue },
            "blackout_candidates": candidates.map { entry -> [String: Any] in
                let bounds = entry[kCGWindowBounds as String] as? [String: Any] ?? [:]
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) ?? .zero
                return ["window": entry[kCGWindowNumber as String] ?? 0,
                        "layer": entry[kCGWindowLayer as String] ?? 0,
                        "alpha": (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0,
                        "on_screen": entry[kCGWindowIsOnscreen as String] as? Bool ?? false,
                        "frame": [frame.minX, frame.minY, frame.width, frame.height]]
            }]
        if !curtainPIDs.isEmpty && covering.isEmpty {
            result["error"] = "blackout is not raised over the target window"
            print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
            throw NSError(domain: "probe-capture", code: 2, userInfo: [NSLocalizedDescriptionKey: "blackout is not raised over the target window"])
        }
        if CommandLine.arguments.contains("--metadata-only") {
            print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
            exit(0)
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == number }) else {
            throw NSError(domain: "probe-capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "no target window"])
        }
        // At the window's own screen's scale: asked for twice its points on
        // a 1x screen (m4's), the window came drawn into a quarter of the
        // picture, the rest blank, and a picture's points read off it were
        // half what they are.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(SCShareableContent.info(for: filter).pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let picture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "probe-capture", code: 3)
        }
        CGImageDestinationAddImage(destination, picture, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "probe-capture", code: 4) }
        result["size"] = [picture.width, picture.height]
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
        exit(0)
    } catch {
        fputs("ScreenCaptureKit: \(error)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
