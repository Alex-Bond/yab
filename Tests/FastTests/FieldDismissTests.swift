import Foundation
import Testing
@testable import Fast

struct FieldDismissTests {
    @MainActor private func withForm(_ run: (Browser) -> Void) {
        let id = UUID(), browser = Browser(windowID: id)
        defer { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        let page = browser.open(URL(string: "about:blank#form")!, foreground: true)
        page.typing = true
        browser.edit()
        // Closing a place needs no keychain read or stored credentials.
        browser.query.place = .passwords
        browser.typed = ""
        run(browser)
    }

    @MainActor @Test func escapeReturnsToTheFormWithoutAnEmptyField() {
        withForm { browser in
            #expect(browser.query.form != nil)
            #expect(browser.fieldShowing)
            #expect(browser.leavePlace(returnToForm: true))
            #expect(!browser.fieldShowing)
            #expect(browser.query.place == nil)
            #expect(browser.query.form == nil)
            #expect(browser.active?.typing == true)
        }
    }

    @MainActor @Test func escapeClosesActionsBeforeReturningToTheForm() {
        withForm { browser in
            browser.query.acting = 0
            #expect(browser.leavePlace(returnToForm: true))
            #expect(browser.query.acting == nil)
            #expect(browser.query.place == .passwords)
            #expect(browser.fieldShowing)
            #expect(browser.leavePlace(returnToForm: true))
            #expect(!browser.fieldShowing)
        }
    }

    @MainActor @Test func backspaceStillReturnsToThePlainField() {
        withForm { browser in
            #expect(browser.leavePlace())
            #expect(browser.query.place == nil)
            #expect(browser.fieldShowing)
            #expect(browser.query.form != nil)
        }
    }

    @MainActor @Test func aPlaceInANewTabStillReturnsToThePlainField() {
        withForm { browser in
            browser.openFresh()
            browser.query.place = .passwords
            #expect(browser.leavePlace(returnToForm: true))
            #expect(browser.query.place == nil)
            #expect(browser.fieldShowing)
            #expect(browser.asked == .tab)
        }
    }

    @MainActor @Test func aPlaceWithoutAFormStillReturnsToANewTab() {
        withForm { browser in
            browser.query.form = nil
            #expect(browser.leavePlace(returnToForm: true))
            #expect(browser.query.place == nil)
            #expect(browser.fieldShowing)
            #expect(browser.asked == .tab)
        }
    }
}
