import Foundation
import Testing
@testable import Fast

/// Owner, row 1109: an import from Arc turns on "Today's tabs in every
/// window", as Arc shares Today across a space's windows, unless the
/// switch was ever set here; other browsers leave it as it is.
@MainActor
@Suite(.serialized)
struct ArcTodayEveryWindowTests {
    private let key = KeptEverywhere.todayKey

    /// Runs `body` with the switch never set, or set to `stored`, and puts
    /// the test world's setting back after.
    private func world(stored: Bool?, _ body: (Browser) throws -> Void) throws {
        #expect(Store.testing)
        guard Store.testing else { return }
        let store = Store.settings
        let before = store.object(forKey: key)
        let previousSpaces = Spaces.read()
        // A space of its own: brought into the first space, the kept pages
        // stayed in its row and came ahead of WelcomeImportTests' own.
        let space = UUID()
        let browser = Browser()
        browser.spaces = [Space(id: space, name: "Today test", icon: "", ownSignIns: false)]
        browser.spaceID = space
        if browser.prefs.todayEveryWindow { browser.prefs.todayEveryWindow = false }
        if let stored { store.set(stored, forKey: key) } else { store.removeObject(forKey: key) }
        defer {
            if browser.prefs.todayEveryWindow { browser.prefs.todayEveryWindow = false }
            KeptEverywhere.turnToday(false)
            if let before { store.set(before, forKey: key) } else { store.removeObject(forKey: key) }
            Spaces.write(previousSpaces)
            Session.erase(space: space)
        }
        try body(browser)
    }

    private func bring(_ browser: Browser, from name: String, bundle: String) {
        let page = URL(string: "https://arc-today-\(UUID().uuidString.prefix(8).lowercased()).test/")!
        let place = TabImport.Place(id: "\(name):today-\(UUID().uuidString)", name: "Today test", profile: "Default", shared: true,
                                    pinned: [], kept: [TabImport.Entry(url: page, title: "Kept")], open: [])
        let source = Chromium.Source(name: name, folder: "Yab missing import fixture", service: "", account: "", bundle: bundle)
        browser.bring([place], withOpen: true, asSpaces: false, signIns: false, from: source)
    }

    @Test func arcImportTurnsItOnWhenNeverSet() throws {
        try world(stored: nil) { browser in
            bring(browser, from: "Arc", bundle: TabImport.arc)
            #expect(browser.prefs.todayEveryWindow)
            #expect(Store.settings.object(forKey: key) as? Bool == true)
            #expect(KeptEverywhere.today)
        }
    }

    @Test func arcImportKeepsAnExplicitOff() throws {
        try world(stored: false) { browser in
            bring(browser, from: "Arc", bundle: TabImport.arc)
            #expect(!browser.prefs.todayEveryWindow)
            #expect(Store.settings.object(forKey: key) as? Bool == false)
        }
    }

    @Test func otherImportsLeaveItOff() throws {
        try world(stored: nil) { browser in
            bring(browser, from: "Dia", bundle: TabImport.dia)
            bring(browser, from: "Chrome", bundle: "com.google.Chrome")
            #expect(!browser.prefs.todayEveryWindow)
            #expect(Store.settings.object(forKey: key) == nil)
        }
    }
}
