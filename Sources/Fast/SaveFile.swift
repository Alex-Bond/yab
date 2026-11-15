import Foundation

// save_file: words an agent made (a table as .csv, dates as .ics, a note in
// Markdown, JSON) written as a file into its task's folder,
// ~/Downloads/yab/<task>/, and nowhere else. No Mac access is needed: the
// folder is the task's own, as for save_page. The chat shows the file as a
// card under the answer (ChatFileCard), which says what is in it ("48 rows",
// "4 events"). Plan: docs/agent-asks.md.

enum SaveFile {
    /// The most a file may be.
    static let limit = 5 << 20

    /// Endings that run something when the file is opened: such a file is
    /// saved as text instead ("setup.command.txt").
    static let running: Set<String> = [
        "app", "command", "tool", "terminal", "sh", "zsh", "bash", "csh", "ksh", "fish", "pkg", "mpkg", "dmg",
        "scpt", "scptd", "applescript", "workflow", "action", "shortcut", "jar", "plugin", "kext", "dylib", "so",
        "exe", "bat", "cmd", "ps1", "vbs", "inetloc", "fileloc", "webloc", "url", "mobileconfig", "prefpane",
    ]

    enum Trouble: Error, Equatable {
        case empty, tooBig(Int), outside

        var said: String {
            switch self {
            case .empty: "save_file needs text to write"
            case .tooBig(let bytes): "That is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); save_file writes up to 5 MB"
            case .outside: "save_file writes only into the task's folder"
            }
        }
    }

    /// The name a file is saved under, from whatever was asked: no folders
    /// ("../../.ssh/config" is "config.txt"), nothing hidden, an ending of
    /// a few letters or digits (txt when there is none), and never one
    /// that runs something.
    static func name(_ said: String) -> (base: String, ext: String) {
        let last = said.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var base = last.trimmingCharacters(in: .whitespacesAndNewlines)
        var ext = "txt"
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            let after = base[base.index(after: dot)...]
            if (1...10).contains(after.count), after.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
                ext = after.lowercased()
                base = String(base[..<dot])
            }
        }
        if running.contains(ext) {
            base += "." + ext
            ext = "txt"
        }
        // Nothing hidden: no leading dots.
        base = String(base.drop { $0 == "." || $0.isWhitespace })
        return (base, ext)
    }

    /// Writes `text` into `folder` under a name cleaned from `said`, never
    /// over a file already there ("Contacts 2.csv"); the file.
    static func write(_ text: String, named said: String, in folder: URL) throws(Trouble) -> URL {
        let data = Data(text.utf8)
        guard !data.isEmpty else { throw .empty }
        guard data.count <= limit else { throw .tooBig(data.count) }
        let (base, ext) = name(said)
        let own = folder.standardizedFileURL.resolvingSymlinksInPath().path
        // Two calls at once may pick the same free name: the second tries
        // the next one.
        for _ in 0..<20 {
            let file = PageSave.file(title: base, host: "File", format: ext, in: folder)
            guard file.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path == own else { throw .outside }
            do {
                try data.write(to: file, options: .withoutOverwriting)
                return file
            } catch {
                if FileManager.default.fileExists(atPath: file.path) { continue }
                throw .outside
            }
        }
        throw .outside
    }

    /// What the file card says is in a file save_file makes, past its size:
    /// "48 rows", "4 events", "12 items"; nil for kinds it doesn't count.
    nonisolated static func counted(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard ["csv", "tsv", "ics", "json"].contains(ext),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= limit * 2 else { return nil }
        switch ext {
        case "csv", "tsv":
            let records = rows(String(decoding: data, as: UTF8.self))
            // The first is its heading.
            return plural(records > 1 ? records - 1 : records, "row")
        case "ics":
            let text = String(decoding: data, as: UTF8.self)
            let events = text.components(separatedBy: "BEGIN:VEVENT").count - 1
            if events > 0 { return plural(events, "event") }
            let todos = text.components(separatedBy: "BEGIN:VTODO").count - 1
            return todos > 0 ? plural(todos, "to-do") : nil
        default:
            switch try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            case let list as [Any]: return plural(list.count, "item")
            case let object as [String: Any]: return plural(object.count, "field")
            default: return nil
            }
        }
    }

    /// Records in a CSV, a line break inside quotes not ending one, empty
    /// lines not counted.
    nonisolated static func rows(_ text: String) -> Int {
        var count = 0
        var quoted = false
        var filled = false
        for c in text.unicodeScalars {
            if c == "\"" { quoted.toggle() }
            if !quoted, c == "\n" || c == "\r" {
                if filled { count += 1 }
                filled = false
            } else if !CharacterSet.whitespaces.contains(c) {
                filled = true
            }
        }
        return count + (filled ? 1 : 0)
    }

    nonisolated static func plural(_ n: Int, _ word: String) -> String {
        n.formatted(.number) + " " + word + (n == 1 ? "" : "s")
    }
}
