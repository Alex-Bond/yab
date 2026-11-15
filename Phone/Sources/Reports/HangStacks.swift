import Foundation

// What the main thread was doing when Yab stopped answering (MetricKit's
// hang diagnostics, a call stack of frames and binary ids): the newest few
// stay on this iPhone and go only inside a crash report you agreed to send,
// with the first that goes, then are forgotten. The Mac's FieldHangs keeps
// them the same way, in the same shape, so the site reads both alike.

enum HangStacks {
    /// How many are kept, newest last.
    static let kept = 5
    /// At most this much of them, so a crash report never grows past what
    /// the site takes for one (DiagnosticReports.reportBytes beside it).
    static let bytes = 128 * 1024

    /// Only what reads a stack: frames, the binaries they are in by name
    /// and id, and offsets. Anything else MetricKit adds stays here.
    static let stackKeys: Set<String> = [
        "callStackTree", "callStacks", "callStackPerThread", "threadAttributed", "callStackRootFrames", "subFrames",
        "binaryUUID", "binaryName", "offsetIntoBinaryTextSegment", "address", "sampleCount",
    ]

    static func stackOnly(_ value: Any) -> Any? {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: [String: Any]()) { kept, pair in
                guard stackKeys.contains(pair.key), let inner = stackOnly(pair.value) else { return }
                kept[pair.key] = inner
            }
        case let list as [Any]: return list.compactMap(stackOnly)
        case is String, is NSNumber: return value
        default: return nil
        }
    }

    /// A hang's stack as kept: how long, which build, the frames.
    static func stack(milliseconds: Int, build: String?, tree: Data) -> [String: Any]? {
        guard let json = try? JSONSerialization.jsonObject(with: tree), let frames = stackOnly(json) else { return nil }
        var kept: [String: Any] = ["ms": milliseconds, "stack": frames]
        if let build { kept["build"] = build }
        return kept
    }

    static func stacks(in file: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list
    }

    static func keep(_ new: [[String: Any]], in file: URL) {
        guard !new.isEmpty else { return }
        var all = Array((stacks(in: file) + new).suffix(kept))
        var data = (try? JSONSerialization.data(withJSONObject: all)) ?? Data()
        while data.count > bytes, !all.isEmpty {
            all.removeFirst()
            data = (try? JSONSerialization.data(withJSONObject: all)) ?? Data()
        }
        guard !all.isEmpty else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    static func forget(in file: URL) {
        try? FileManager.default.removeItem(at: file)
    }
}
