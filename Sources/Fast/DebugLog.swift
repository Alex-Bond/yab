import AppKit

// A debug build's journal (docs/debug-builds.md): what a feature under
// investigation did, step by step, and every time the main thread stopped
// answering for 50 ms or more, with its stack, in one file of JSON lines,
// debug.jsonl beside the app's other files, for an agent to read back after
// someone has tried the build by hand (scripts/debug/pip.py for the
// floating window).
//
// Off in every build but a debug one: Info.plist's YabDebug, written by
// `YAB_DEBUG=pip ./build.sh`, or YAB_DEBUG for a run from the shell, names
// what it writes down. Off, a call is one load and a branch; what it would
// write isn't even made (`@autoclosure`).

enum DebugLog {
    /// The words this build writes down: "pip" for the floating window.
    static let channels: Set<String> = {
        let words = Bundle.main.object(forInfoDictionaryKey: "YabDebug") as? String
            ?? ProcessInfo.processInfo.environment["YAB_DEBUG"] ?? ""
        return Set(words.split { $0 == " " || $0 == "," }.map(String.init))
    }()
    /// The floating window, by hand: every press, drag, swipe, decision and
    /// glide.
    static let pip = channels.contains("pip")
    /// Any debug build watches the main thread (Hangs, at 50 ms).
    static let freezes = !channels.isEmpty

    static var file: URL { Store.file("debug.jsonl") }

    private static let queue = DispatchQueue(label: "yab.debug-log", qos: .utility)
    private nonisolated(unsafe) static var handle: FileHandle?
    private nonisolated(unsafe) static var screensSaid = ""

    /// One line: `event` and what goes with it, stamped with the wall clock
    /// in seconds (`t`), so lines from the watchdog's thread fall in order.
    static func note(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard freezes else { return }
        var line = fields()
        line["e"] = event
        line["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        guard JSONSerialization.isValidJSONObject(line),
              var data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        queue.async { [data] in write(data) }
    }

    /// The displays, when they differ from the last ones written down.
    @MainActor static func screens() {
        guard freezes else { return }
        let all = NSScreen.screens.map { ["frame": rect($0.frame), "visible": rect($0.visibleFrame), "name": $0.localizedName] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys]) else { return }
        let said = String(decoding: data, as: UTF8.self)
        guard said != screensSaid else { return }
        screensSaid = said
        note("screens", ["screens": all])
    }

    static func rect(_ r: NSRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { (Double($0) * 10).rounded() / 10 } }
    static func point(_ p: NSPoint) -> [Double] { [p.x, p.y].map { (Double($0) * 10).rounded() / 10 } }
    static func ms(_ seconds: TimeInterval) -> Double { (seconds * 10000).rounded() / 10 }

    private static func write(_ data: Data) {
        if handle == nil {
            let url = file
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        try? handle?.write(contentsOf: data)
    }
}
