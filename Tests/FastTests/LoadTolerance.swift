import Foundation
import QuartzCore
import WebKit
@testable import Fast

/// For tests that run beside builds and other suites: wait for a condition
/// instead of a fixed time, and check what depends on timing only when the
/// timing held.
@MainActor
enum Loaded {
    /// Polls `check` until it holds or `seconds` have passed; whether it held.
    static func until(_ seconds: Double, every: Duration = .milliseconds(20), _ check: () async throws -> Bool) async throws -> Bool {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            if try await check() { return true }
            try await Task.sleep(for: every)
        }
        return try await check()
    }
}

/// How late the main actor wakes while a test waits: a heartbeat every
/// 10 ms, its worst lateness kept. A Mac busy with a build wakes it
/// hundreds of milliseconds late; a check of how soon something happened
/// means something only when `held`.
@MainActor
final class Punctuality {
    private(set) var worst: Double = 0
    private var beat: Task<Void, Never>?

    init() {
        beat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let asked = CACurrentMediaTime()
                try? await Task.sleep(for: .milliseconds(10))
                guard let self else { return }
                self.worst = max(self.worst, CACurrentMediaTime() - asked - 0.010)
            }
        }
    }

    /// No wake more than `slack` seconds late since it started.
    func held(_ slack: Double = 0.2) -> Bool { worst < slack }

    func stop() { beat?.cancel(); beat = nil }
}

/// An extension controller of a test's own whose pages and workers carry
/// Yab's user agent (Web.userAgentName), as Extensions' own do. WebKit gives
/// workers the user agent of the last page that loaded and stops, for good,
/// the workers whose agent differs: in a whole test run, beside the suites
/// loading Yab's pages, a test controller's worker on WebKit's default agent
/// never started or stopped halfway (m4, 2026-10-14).
///
/// And a website data store of its own, as Yab's controller has
/// (Store.websites). The first context a persistent controller loads makes
/// WebKit sweep that controller's data store for extension origins it
/// doesn't have loaded (WebExtensionContext::removeStaleExtensionWebsiteData,
/// once per new storage folder), service worker registrations included,
/// which ends their workers. On WebKit's default
/// store, shared by every test controller, each suite's fresh controller
/// ended the other suites' running workers, and WebKit, never told, didn't
/// start them again: the rule-updates worker went quiet in its 12 s wait
/// and its answer never came ("SWContextManager::terminateWorker" right
/// after "deleteWebsiteDataForOrigins" for session 1, m4, 2026-10-18).
@MainActor
enum TestExtensions {
    static func controller() -> WKWebExtensionController {
        let configuration = WKWebExtensionController.Configuration(identifier: UUID())
        let store = WKWebsiteDataStore(forIdentifier: UUID())
        configuration.defaultWebsiteDataStore = store
        let views = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        views.websiteDataStore = store
        views.applicationNameForUserAgent = Web.userAgentName
        configuration.webViewConfiguration = views
        return WKWebExtensionController(configuration: configuration)
    }
}
