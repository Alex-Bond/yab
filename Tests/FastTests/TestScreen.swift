import AppKit
import CoreGraphics

/// The screen a test may show windows on. A Mac with
/// `~/.config/yab/keep-builtin-screen` (main) never lends its built-in
/// screen: tests go to the screens named in `~/.config/yab/stage-screen`
/// (main: "Yab Test,BenQ"), else any external one, else nowhere.
@MainActor
enum TestScreen {
    private static let config = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/yab")

    static var keepsBuiltin: Bool {
        FileManager.default.fileExists(atPath: config.appendingPathComponent("keep-builtin-screen").path)
    }

    static var screen: NSScreen? {
        let named = ((try? String(contentsOf: config.appendingPathComponent("stage-screen"), encoding: .utf8)) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let external = NSScreen.screens.filter { !isBuiltin($0) }
        for name in named {
            if let match = external.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) }) { return match }
        }
        if let first = external.first { return first }
        return keepsBuiltin ? nil : NSScreen.main
    }

    /// False only where the built-in screen is off-limits and no other is up.
    static var available: Bool { screen != nil }

    private static func isBuiltin(_ screen: NSScreen) -> Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = (screen.deviceDescription[key] as? NSNumber)?.uint32Value else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
