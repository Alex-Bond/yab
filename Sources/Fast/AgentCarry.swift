import Foundation

// Keep the provider conversation available when an agent changes accounts.

enum AgentCarry {
    enum Result: Equatable {
        /// Both accounts read the same store.
        case shared
        /// The next account had it already, as new as the source.
        case present
        /// Copied into the next account's store.
        case copied
        /// No transcript to carry: the session never wrote one, or it's gone.
        case missing
    }

    /// Claude Code's folder name for a working folder.
    static func slug(_ folder: String) -> String {
        let real = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
        return String(real.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    static func claudeFile(home: URL, folder: String, session: String) -> URL {
        home.appendingPathComponent("projects").appendingPathComponent(slug(folder)).appendingPathComponent(session + ".jsonl")
    }

    /// Codex's rollout for a thread, wherever its day folder is.
    static func codexFile(home: URL, thread: String) -> URL? {
        let manager = FileManager.default
        for top in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(top)
            guard let walk = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in walk where file.lastPathComponent.hasSuffix("-" + thread + ".jsonl") && file.lastPathComponent.hasPrefix("rollout-") {
                return file
            }
        }
        return nil
    }

    /// Whether two account folders keep conversations in the same place.
    static func sameStore(_ cli: String, _ a: URL, _ b: URL) -> Bool {
        let name = cli == "codex" ? "sessions" : "projects"
        let one = a.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
        let two = b.appendingPathComponent(name).resolvingSymlinksInPath().standardizedFileURL.path
        return one == two
    }

    /// Makes `session` resumable from the account folder `to`, having been
    /// written under `from`. `folder` is the working folder it ran in
    /// (Claude's transcripts are filed by it).
    @discardableResult
    static func ensure(cli: String, session: String, folder: String, from: URL, to: URL) -> Result {
        let manager = FileManager.default
        if cli == "codex" {
            guard let source = codexFile(home: from, thread: session) else { return .missing }
            if sameStore(cli, from, to) { return .shared }
            if let there = codexFile(home: to, thread: session) {
                if newer(there, than: source) { return .present }
                return copy(source, to: there) ? .copied : .missing
            }
            // Its day folder, kept as Codex named it.
            let parts = source.pathComponents.suffix(4)
            let target = parts.dropLast().reduce(to.appendingPathComponent("sessions")) { $0.appendingPathComponent($1) }
                .appendingPathComponent(source.lastPathComponent)
            return copy(source, to: target) ? .copied : .missing
        }
        let source = claudeFile(home: from, folder: folder, session: session)
        guard manager.fileExists(atPath: source.path) else { return .missing }
        if sameStore(cli, from, to) { return .shared }
        let target = claudeFile(home: to, folder: folder, session: session)
        var result = Result.present
        if !(manager.fileExists(atPath: target.path) && newer(target, than: source)) {
            guard copy(source, to: target) else { return .missing }
            result = .copied
        }
        // Long tool results it reads back on resume.
        let results = source.deletingPathExtension()
        var isFolder: ObjCBool = false
        if manager.fileExists(atPath: results.path, isDirectory: &isFolder), isFolder.boolValue {
            let there = target.deletingPathExtension()
            if !manager.fileExists(atPath: there.path) {
                try? manager.createDirectory(at: there.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? manager.copyItem(at: results, to: there)) != nil { result = .copied }
            }
        }
        return result
    }

    private static func newer(_ a: URL, than b: URL) -> Bool {
        let date = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        return date(a) >= date(b) && size(a) >= size(b)
    }

    /// Beside, then renamed into place: never half a file.
    private static func copy(_ source: URL, to target: URL) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let beside = target.deletingLastPathComponent().appendingPathComponent(".yab-carry-" + UUID().uuidString)
            try manager.copyItem(at: source, to: beside)
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: beside)
            } else {
                try manager.moveItem(at: beside, to: target)
            }
            return true
        } catch {
            return false
        }
    }

    /// An account's folder: its own, or the CLI's usual one.
    static func home(_ account: PlanAccount?, cli: String, user: URL = AgentSetup.home) -> URL {
        if let home = account?.home { return URL(fileURLWithPath: home) }
        return user.appendingPathComponent(cli == "codex" ? ".codex" : ".claude")
    }
}
