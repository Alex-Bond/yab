import AppKit
import Darwin

// Whether Yab may write in the folder a download is going to, asked before
// WebKit is handed the file (#400).
//
// Downloads, Desktop and Documents are closed to an app until macOS's
// Files & Folders says otherwise, and the first write there waits on
// macOS's question. That write is WebKit's network process's, made on
// Yab's behalf: when the question never came up (tccd waiting on a dialog
// it never showed, as on main on 2026-10-13, evals/tcc_guard.py) the
// download said "in progress" forever and no file came. After a no, or
// in a folder without write permission, WebKit gives up with "Cannot
// create file" and the file never came either.
//
// So Yab writes a stand-in there itself first, off the main thread. The
// folder takes it: the download goes there as before. It doesn't, or
// macOS hasn't answered in a few seconds: the file goes to Yab's own
// folder instead, where nothing needs asking, and the corner says why,
// with Open Settings. The next download asks again, so a switch turned on
// meanwhile is heard at once; one still unanswered isn't asked behind.
enum DownloadFolder {
    /// This Mac's override, outside the synced Space model. An old Space
    /// or one with no choice follows General, including later changes to it.
    nonisolated static func custom(for space: UUID, store: UserDefaults = Store.settings) -> URL? {
        guard let path = store.string(forKey: key(for: space)), path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    nonisolated static func set(_ folder: URL?, for space: UUID, store: UserDefaults = Store.settings) {
        guard let folder else { store.removeObject(forKey: key(for: space)); return }
        guard folder.isFileURL else { return }
        store.set(folder.standardizedFileURL.path, forKey: key(for: space))
    }

    nonisolated static func destination(for space: UUID?, fallback: URL, store: UserDefaults = Store.settings) -> URL {
        space.flatMap { custom(for: $0, store: store) } ?? fallback
    }

    nonisolated static func key(for space: UUID) -> String { "downloads.space." + space.uuidString.lowercased() }

    /// The ordinary save panel, also replaceable by a native test's own
    /// answer so destination selection can be checked without showing UI.
    /// Its answer comes later, never from a modal loop: Chromium's download
    /// arrives inside a main-actor job (ChromiumProcess's event loop), and
    /// a modal loop there kept the main queue from the work the panel's own
    /// service needs to connect. AppKit then said "The save file operation
    /// failed to connect to the open and save panel service" over the
    /// panel, every time (#1715, #1726, #1731). `begin` leaves the job at
    /// once, as the page's own file panels do (Dialogs).
    @MainActor static func choose(_ name: String, in folder: URL, _ done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        panel.begin { response in
            MainActor.assumeIsolated { done(response == .OK ? panel.url : nil) }
        }
    }

    /// A folder for downloads, the same way: Settings' and a Space's
    /// choosers, whose pick can arrive inside a job of its own (#1711).
    @MainActor static func chooseFolder(starting folder: URL?, _ done: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = SettingsWords.text("Use This Folder")
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                done(url)
            }
        }
    }

    /// Where a file goes when its folder is closed to Yab.
    static var own: URL { Store.folder.appendingPathComponent("Downloads", isDirectory: true) }

    /// How long macOS has to answer before the file goes elsewhere.
    static let patience: TimeInterval = 4

    /// A write still out, by folder, since when, and the downloads waiting
    /// on its answer. Another download meanwhile waits on the same one; past
    /// `patience` it isn't asked behind it at all.
    @MainActor private static var waiting: [String: (since: Date, answers: [Once])] = [:]
    private static let queue = DispatchQueue(label: "yab.download-folder", qos: .userInitiated, attributes: .concurrent)

    /// `true` when Yab may write in `folder`; on the main actor.
    @MainActor static func check(_ folder: URL, _ answer: @escaping @MainActor (Bool) -> Void) {
        let path = folder.standardizedFileURL.path
        let once = Once(answer)
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) {
            MainActor.assumeIsolated { once.say(false) }
        }
        if let out = waiting[path] {
            guard Date().timeIntervalSince(out.since) < patience else { return once.say(false) }
            waiting[path]?.answers.append(once)
            return
        }
        waiting[path] = (Date(), [once])
        // A test world's folder macOS hasn't answered for: the write never
        // comes back, as tccd's unshown question kept it.
        let hangs = Store.testing && ProcessInfo.processInfo.environment["YAB_DOWNLOADS_HANG"] == path
        queue.async {
            if hangs { Thread.sleep(forTimeInterval: 3600) }
            let open = writable(path)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for waiter in waiting.removeValue(forKey: path)?.answers ?? [] { waiter.say(open) }
                }
            }
        }
    }

    /// The first answer, the write's or the clock's, and only that.
    @MainActor private final class Once {
        private var answer: ((Bool) -> Void)?
        init(_ answer: @escaping @MainActor (Bool) -> Void) { self.answer = answer }
        func say(_ open: Bool) {
            let then = answer
            answer = nil
            then?(open)
        }
    }

    /// A stand-in file made and taken away again; the folder made first
    /// when it isn't there (WebKit drops a download into a missing folder
    /// without a word).
    nonisolated static func writable(_ path: String) -> Bool {
        func stand() -> Int32 {
            let file = path + "/.yab-" + UUID().uuidString
            let fd = open(file, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else { return errno }
            close(fd)
            unlink(file)
            return 0
        }
        var failed = stand()
        if failed == ENOENT, (try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)) != nil {
            failed = stand()
        }
        return failed == 0
    }

    /// The Files & Folders pane of System Settings.
    @MainActor static func openSettings() {
        if Store.testing { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The folder's name for the corner: "Downloads", "Desktop", or its own.
    static func name(_ folder: URL) -> String {
        ClosedPlace.of(folder.path)?.name ?? FileManager.default.displayName(atPath: folder.path)
    }
}
