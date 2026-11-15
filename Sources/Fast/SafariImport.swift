import AppKit

// Everything Safari will give: its own export, File › Export Browsing Data,
// a ZIP of the bookmarks (Netscape HTML), the passwords (CSV), the payment
// cards and each profile's history (JSON), as Apple documents it in
// "Importing data exported from Safari". Safari keeps its cards and
// passwords where no other app can read them, so this file is the one way
// in, and macOS has no call to open that sheet from here (SFSafariSettings'
// is iOS and Catalyst only).
//
// So yab does the rest: opens Safari, says which menu item, and watches
// Downloads, where it asks the file be saved, for a new export. The
// moment one is there it is read whole, everything in it brought in at once,
// and said in one line. The file is not encrypted, so what it leaves behind
// is offered to the Trash. Files inside have localized names; they are known
// by what they hold instead.

enum SafariImport {
    /// What an export held, and what came in from it.
    struct Brought {
        var cards = 0
        var addresses = 0
        var passwords = 0
        var bookmarks = 0
        var places = 0

        /// "3 cards, 212 passwords, 1,204 bookmarks and 8,300 places".
        var line: String {
            let parts = [(cards, "card", "cards"), (passwords, "password", "passwords"), (bookmarks, "bookmark", "bookmarks"),
                         (places, "place", "places")]
                .filter { $0.0 > 0 }
                .map { "\($0.0.formatted()) \($0.0 == 1 ? $0.1 : $0.2)" }
            guard let last = parts.last else { return "Nothing new" }
            return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    /// The files of an export, by what each one is.
    struct Export {
        var cards: [SavedCard] = []
        var passwords: String?
        var bookmarks: URL?
        var history: [URL] = []
        /// Where it was unpacked, to be removed when done.
        var folder: URL
        var empty: Bool { cards.isEmpty && passwords == nil && bookmarks == nil && history.isEmpty }
    }

    // MARK: - reading one

    /// A ZIP unpacked in a folder of its own and sorted by what its files
    /// hold. Nil when it isn't Safari's.
    static func read(_ zip: URL) -> Export? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-safari-\(UUID().uuidString)", isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        do { try ditto.run() } catch { return nil }
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        var export = Export(folder: folder)
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath } ?? []
        for file in files {
            switch file.pathExtension.lowercased() {
            case "json":
                guard let data = try? Data(contentsOf: file),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let kind = (top["metadata"] as? [String: Any])?["data_type"] as? String
                else { continue }
                if kind == "payment_cards" { export.cards += cards(in: top) }
                if kind == "history" { export.history.append(file) }
            case "csv":
                // Title, URL, Username, Password, Notes, OTPAuth.
                guard let text = HistoryFile.text(of: file), text.prefix(200).lowercased().contains("password") else { continue }
                export.passwords = text
            case "html", "htm":
                guard let head = try? String(contentsOf: file, encoding: .utf8).prefix(300),
                      head.uppercased().contains("NETSCAPE-BOOKMARK") else { continue }
                export.bookmarks = file
            default:
                continue
            }
        }
        guard !export.empty else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return export
    }

    /// `payment_cards`: the number, the person's name for it, the name on
    /// it, the date, and when it was last used, in microseconds.
    static func cards(in top: [String: Any]) -> [SavedCard] {
        (top["payment_cards"] as? [[String: Any]] ?? []).compactMap { row in
            let digits = (row["card_number"] as? String ?? "").filter(\.isNumber)
            guard Wallet.luhn(digits) else { return nil }
            let used = (row["card_last_used_time_usec"] as? Double).map { Date(timeIntervalSince1970: $0 / 1_000_000) }
            return SavedCard(
                id: UUID().uuidString, number: digits, last4: String(digits.suffix(4)), brand: Wallet.brand(of: digits),
                name: row["cardholder_name"] as? String ?? "", month: row["card_expiration_month"] as? Int ?? 0,
                year: Wallet.fullYear(row["card_expiration_year"] as? Int ?? 0), used: used, saved: nil,
                nickname: row["card_name"] as? String ?? "", source: "Safari"
            )
        }
    }

    // MARK: - taking one in

    /// Everything in the export, into yab: cards and passwords into the
    /// keychain off the main thread, bookmarks and history the way their own
    /// imports take them, quietly, then one line for all of it.
    @MainActor
    static func take(_ zip: URL, into browser: Browser, then done: @escaping (Brought?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let export = read(zip) else { return DispatchQueue.main.async { done(nil) } }
            var brought = Brought()
            brought.cards = Wallet.take(cards: export.cards, addresses: []).cards
            if let csv = export.passwords { brought.passwords = Vault.take(csv: csv).kept }
            DispatchQueue.main.async {
                let group = DispatchGroup()
                if let file = export.bookmarks {
                    group.enter()
                    browser.takeBookmarks(file: file, quiet: true) { brought.bookmarks = $0 ?? 0; group.leave() }
                }
                for file in export.history {
                    group.enter()
                    browser.takePlaces(file: file, quiet: true) { brought.places += $0 ?? 0; group.leave() }
                }
                group.notify(queue: .main) {
                    try? FileManager.default.removeItem(at: export.folder)
                    done(brought)
                }
            }
        }
    }

    // MARK: - waiting for one

    /// The folder a save is asked to go to. Downloads only: yab already
    /// saves there, where the Desktop would be a macOS question nobody
    /// expected; a file saved anywhere else is picked by hand.
    static var folders: [URL] {
        if Store.testing, let testFolder { return [testFolder] }
        return [.downloadsDirectory].compactMap { FileManager.default.urls(for: $0, in: .userDomainMask).first }
    }

    /// A test run's own Downloads (Bench `wallet` "downloads").
    nonisolated(unsafe) static var testFolder: URL?

    /// Waiting for Safari's export to be saved: a watch on those folders,
    /// once a second, for a ZIP newer than the moment it started that holds
    /// Safari's files. Stopped by `stop`, or after ten minutes.
    @MainActor
    final class Watch {
        private var timer: Timer?
        private let since = Date()
        private var seen = Set<URL>()
        private let found: (URL) -> Void

        init(found: @escaping (URL) -> Void) {
            self.found = found
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.look() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func look() {
            guard Date().timeIntervalSince(since) < 600 else { return stop() }
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            for folder in SafariImport.folders {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
                for file in files where file.pathExtension.lowercased() == "zip" && !seen.contains(file) {
                    let values = try? file.resourceValues(forKeys: Set(keys))
                    guard let at = values?.contentModificationDate, at > since.addingTimeInterval(-2) else { continue }
                    // Still being written: the next look.
                    guard let size = values?.fileSize, size > 0, Date().timeIntervalSince(at) > 1 else { continue }
                    seen.insert(file)
                    guard SafariImport.looksLikeExport(file) else { continue }
                    stop()
                    found(file)
                    return
                }
            }
        }
    }

    /// A ZIP whose list of files has Safari's in it, read without unpacking.
    static func looksLikeExport(_ zip: URL) -> Bool {
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        list.arguments = ["-1", zip.path]
        let pipe = Pipe()
        list.standardOutput = pipe
        list.standardError = FileHandle.nullDevice
        do { try list.run() } catch { return false }
        let names = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        list.waitUntilExit()
        // Its names are localized; the kinds of file are not.
        let json = names.components(separatedBy: "\n").filter { $0.hasSuffix(".json") }.count
        return json >= 1 && (names.contains(".csv") || names.contains(".html"))
    }

    /// Safari, in front, for its File menu.
    static func openSafari() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Running now, or when it was last used: its history's last write
    /// where yab may read it, else when the app last ran. Nil without Safari.
    static var recency: (running: Bool, at: Date)? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return nil }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").isEmpty
        let history = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari/History.db")
        let at = (try? history.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? NSMetadataItem(url: app)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
        return (running, at ?? .distantPast)
    }

    /// Safari's icon, small, for a page's row.
    static var icon: NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari").map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

extension SafariImport {
    /// One import at a time, for whichever place asked (Autofill,
    /// Passwords, PlaceEdit.swift): the watch, the one waiting on it, and the file
    /// that came, to be put in the Trash if asked.
    @MainActor
    final class Desk {
        static let shared = Desk()
        weak var browser: Browser?
        private var watch: Watch?
        private var waiting: ((Any?, String?) -> Void)?
        private var last: URL?

        /// A page's word: "safari" waits for the export, "safariFile" picks
        /// one, "safariCancel" stops waiting, "safariTrash" puts the last
        /// one in the Trash.
        func answer(_ verb: String, _ reply: @escaping (Any?, String?) -> Void) {
            switch verb {
            case "safari":
                cancel()
                waiting = reply
                watch = Watch { [weak self] file in self?.took(file) }
                SafariImport.openSafari()
            case "safariFile":
                cancel()
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.zip]
                panel.allowsMultipleSelection = false
                panel.prompt = "Bring In"
                panel.message = "The file Safari saved with File › Export Browsing Data"
                panel.directoryURL = SafariImport.folders.first
                guard panel.runModal() == .OK, let file = panel.url else { return reply(["cancelled": true], nil) }
                waiting = reply
                took(file)
            case "safariCancel":
                cancel()
                reply(true, nil)
            case "safariTrash":
                guard let last, FileManager.default.fileExists(atPath: last.path) else { return reply(false, nil) }
                NSWorkspace.shared.recycle([last]) { _, error in
                    MainActor.assumeIsolated { reply(error == nil, nil) }
                }
                self.last = nil
            default:
                reply(nil, "unknown")
            }
        }

        private func cancel() {
            watch?.stop()
            watch = nil
            waiting?(["cancelled": true], nil)
            waiting = nil
        }

        /// The export is here: taken in whole, yab brought back in front,
        /// and one line for all of it, where the page asked.
        private func took(_ file: URL) {
            watch = nil
            guard let browser else { return }
            NSApp.activate()
            SafariImport.take(file, into: browser) { [weak self] brought in
                guard let self else { return }
                let reply = waiting
                waiting = nil
                guard let brought else {
                    reply?(["error": "That isn’t a Safari export"], nil)
                    return
                }
                last = file
                let folder = file.deletingLastPathComponent().lastPathComponent
                reply?(["line": brought.line, "cards": brought.cards, "file": file.lastPathComponent, "folder": folder], nil)
            }
        }
    }
}
