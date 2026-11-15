import Foundation
import WebKit

/// A file on this Mac opened without the main thread waiting on macOS.
///
/// WebKit's loadFileURL gives the page's process a sandbox extension for the
/// file's folder, issued on the main thread, and the kernel asks TCC whether
/// yab may read that folder first (Documents, Desktop, iCloud, a removable
/// disk). On 2026-10-13 the user's tccd sat on a consent dialog no window ever
/// showed: every such question waited behind it, and yab's main thread waited
/// in _sandbox_extension_issue for half an hour after a file opened from
/// ~/Documents, the whole browser frozen with no CPU spent (stalls.log). So
/// the same question is asked first on a queue of its own, once per folder
/// in a run: answered, the page loads at once and WebKit's own question finds
/// the answer kept; not answered, the tab waits and the app goes on, and the
/// page loads when macOS answers.
@MainActor
enum FileReach {
    /// Folders macOS has answered about in this run.
    private static var answered = Set<String>()
    /// Folders being asked about, and what each answer is waited for by.
    private static var asking = [String: [Wait]]()

    private struct Wait {
        weak var web: WKWebView?
        let url: URL
        /// The page the view showed when asked: anything else by the time
        /// the answer comes is a navigation since, which wins.
        let from: URL?
    }

    /// A note in stalls.log once the answer is this late.
    static let late: TimeInterval = 2

    static func open(_ url: URL, in web: WKWebView) {
        let folder = url.deletingLastPathComponent()
        let key = folder.standardizedFileURL.path
        if answered.contains(key) {
            web.loadFileURL(url, allowingReadAccessTo: folder)
            return
        }
        let wait = Wait(web: web, url: url, from: web.url)
        if asking[key] != nil {
            asking[key]?.append(wait)
            return
        }
        asking[key] = [wait]
        // A test setting: the answer held back this long, for evals/file-reach.
        let delay = Store.settings.double(forKey: "files.reachDelay")
        let began = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            ask(key)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { arrived(key, after: Date().timeIntervalSince(began)) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + late) {
            MainActor.assumeIsolated {
                guard asking[key] != nil else { return }
                Watchdog.note("file: macOS hasn't answered whether yab may read \(key) in \(Int(late)) s; the tab waits, the app goes on")
            }
        }
    }

    private static func arrived(_ key: String, after seconds: TimeInterval) {
        answered.insert(key)
        let waits = asking.removeValue(forKey: key) ?? []
        if seconds >= late { Watchdog.note(String(format: "file: macOS answered about %@ after %.1f s", key, seconds)) }
        for wait in waits {
            guard let web = wait.web, web.url == wait.from else { continue }
            web.loadFileURL(wait.url, allowingReadAccessTo: wait.url.deletingLastPathComponent())
        }
    }

    /// The question WebKit asks, asked by yab: a read extension for the
    /// folder, issued and thrown away. Symbols looked up, so a macOS without
    /// them just loads.
    private nonisolated static func ask(_ path: String) {
        typealias Issue = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UInt32) -> UnsafeMutablePointer<CChar>?
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let issue = dlsym(everywhere, "sandbox_extension_issue_file"),
              let kind = dlsym(everywhere, "APP_SANDBOX_READ")?.assumingMemoryBound(to: UnsafePointer<CChar>.self).pointee
        else { return }
        free(unsafeBitCast(issue, to: Issue.self)(kind, path, 0))
    }
}
