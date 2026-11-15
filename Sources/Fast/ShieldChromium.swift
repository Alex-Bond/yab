import Foundation
import YabCoreClient

/// Shield for Chromium pages: the helper matches every request against a file
/// of the same rules WebKit compiled (ShieldRules), and is told the switches
/// whenever `Shield.apply` tells WebKit's pages. WebKit's quiet-site lists have
/// no counterpart here: a look costs the helper microseconds, not a list.
@MainActor
enum ShieldChromium {
    nonisolated private static var file: URL {
        Store.folder.appendingPathComponent("Shield/chromium.rules")
    }

    /// Off the main thread, from the build that made the rules.
    nonisolated static func write(_ rules: Filters.Rules) {
        guard EngineRules.available else { return }
        let made = ShieldRules.text(rules)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(made.text.utf8).write(to: file, options: .atomic)
        Task { @MainActor in tell() }
    }

    private static var writing = false

    /// What the helper needs now. A helper that isn't running hears it when
    /// it starts; this never starts one.
    static func tell() {
        guard let core = ChromiumProcess.shared.connectedClient else { return }
        let shield = Shield.shared
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970
        // A copy from before this build knew Chromium: made once, in the
        // background, from the lists kept on disk.
        if stamp == nil, !writing {
            writing = true
            let sources = shield.selected
            Task.detached(priority: .utility) {
                write(Shield.converted(sources: sources))
                await MainActor.run { writing = false }
            }
        }
        var params: [String: JSONValue] = [
            "enabled": .bool(shield.enabled),
            "local": .bool(Shield.blocksLocalPages),
            "off": .array((shield.paused.union(LocalNetwork.homes)).sorted().map(JSONValue.string)),
        ]
        if let stamp {
            params["path"] = .string(file.path)
            params["stamp"] = .number(stamp)
        }
        Task { _ = try? await core.request("shield.configure", params: params) }
    }
}

extension ChromiumPage {
    /// What Shield did on this page, for the bench.
    func shieldStatus() async -> [String: Any] {
        guard let value = try? await navigationRequest("shield.status"),
              let data = try? JSONEncoder().encode(value),
              let out = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["error": "No helper"] }
        return out
    }
}
