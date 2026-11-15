import Foundation
import Testing
@testable import Fast

// Feedback #278: a pinned or kept tab picked from the field while asleep
// waited for its site, the page left on screen, and then switched. Picked,
// it is the stage's to take in at once, as a tab opened from ⌘T is
// (StageView.willOpen; PagePaintTests.openedTabIsInAtOnce shows the stage
// side), and its page loads inside it.
@MainActor
struct WakeAtOnceTests {
    @Test func aSleepingTabPickedIsTakenInAtOnce() throws {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let browser = world.browser
        let kept = try #require(world.tabs["ywm"])
        #expect(kept.asleep && kept.kept)
        browser.select(kept)
        #expect(browser.activeID == kept.id)
        #expect(!kept.asleep)
        #expect(StageView.opensAtOnce(kept.id))
    }

    /// One awake already is shown by the stage as before: its last frame,
    /// or the page left until it has drawn its next frame.
    @Test func anAwakeTabPickedIsNot() throws {
        let world = NestedFoldersBrowserTests.world()
        defer { world.done() }
        let browser = world.browser
        let tab = try #require(world.tabs["hn"])
        _ = tab.wake()
        StageView.willOpen(UUID())
        browser.select(tab)
        #expect(browser.activeID == tab.id)
        #expect(!StageView.opensAtOnce(tab.id))
    }
}
