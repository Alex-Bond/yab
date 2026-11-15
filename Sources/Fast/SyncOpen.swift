import AppKit
import SyncKit

// Open on Mac (R10, Phone/Reference/digest/sync-ios.md; docs/sync.md,
// "Chats and words from the iPhone"): a page another device asks this Mac
// to show, as a `send` of kind `open` with its `url` and the `space` it was
// in there. Only the addressed Mac takes it, once (OpenOnMac.consume keeps a
// local receipt before anything opens), and says `taken`, so the iPhone
// says "Opened on <Mac>". It never starts an agent or acts on the page.

extension SyncCenter {
    /// The open requests waiting for this Mac, each opened once.
    func takeOpenRequests() {
        guard let journal else { return }
        let device = Self.deviceID
        for record in journal.all(SyncChats.send) where record["kind"]?.string == "open" {
            // Read from the very record whose receipt is claimed.
            let space = OpenOnMac.space(record["space"])
            do {
                try OpenOnMac.consume(record, in: journal, device: device) { url in
                    guard SyncOpen.show(url, space: space) else { throw OpenOnMac.Failure.unavailable }
                }
            } catch {
                // A journal that couldn't keep the claim opens nothing.
                // `opening` left by a failed result write is said to be
                // interrupted on the next pass, never opened again.
            }
        }
    }
}

@MainActor
enum SyncOpen {
    /// The page in a tab of the main window, in front: the tab that already
    /// shows it if there is one, else a tab of its own, in the space it was
    /// in on the other device when this Mac has that one, else where Link
    /// Routes send its site, else the space in front. False with no window
    /// to open it in.
    static func show(_ url: URL, space: String?, in window: Browser? = nil) -> Bool {
        guard let browser = window ?? BrowserWindows.shared.browsers.first(where: { $0.windowID == nil }) else { return false }
        Headless.show(.person)
        let target = place(named: space, among: browser.spaces.map(\.id), usesSpaces: browser.prefs.usesSpaces)
            ?? LinkRoutes.shared.space(for: url, in: browser)
        if let target, target != browser.spaceID { browser.switchSpace(to: target) }
        browser.pickUp(url)
        Links.showBrowser(browser)
        NSApp.activate()
        return true
    }

    /// The space the other device named, when this Mac uses spaces and has it.
    nonisolated static func place(named space: String?, among spaces: [UUID], usesSpaces: Bool) -> UUID? {
        guard usesSpaces, let space else { return nil }
        return spaces.first { ContinuePage.sameSpace($0.uuidString, space) }
    }
}
