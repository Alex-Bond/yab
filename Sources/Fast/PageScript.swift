import Foundation

/// The scripts yab puts in pages, kept as JavaScript files in
/// Resources/PageScripts rather than as Swift strings. build.sh copies the
/// folder into the app; `swift test` and a binary run from .build find it in
/// the source tree, as Bins and EmojiMeaning find theirs.
///
/// A file ends in one newline the string never had, so what a page gets is
/// byte for byte what the Swift literal was. Values only Swift knows stand
/// in the file as `__YAB_KEY__` and come in through `vars`.
enum PageScript {
    nonisolated static let folder = "PageScripts"

    /// An app reads only its own copy, so one built without the folder
    /// fails on the Mac that built it too, not first on someone else's.
    nonisolated static func url(_ name: String) -> URL? {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = Bundle.main.bundleURL.pathExtension == "app"
        let places = [Bundle.main.resourceURL?.appendingPathComponent(folder), app ? nil : repo.appendingPathComponent("Resources/" + folder)]
        return places.compactMap { $0?.appendingPathComponent(name + ".js") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func load(_ name: String, vars: [String: String] = [:]) -> String {
        guard let url = url(name), var text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
            assertionFailure("No page script \(name).js")
            NSLog("yab: no page script %@.js", name)
            return ""
        }
        if text.hasSuffix("\n") { text.removeLast() }
        for (key, value) in vars {
            let marker = "__YAB_" + key + "__"
            assert(text.contains(marker), "\(name).js has no \(marker)")
            text = text.replacingOccurrences(of: marker, with: value)
        }
        return text
    }
}
