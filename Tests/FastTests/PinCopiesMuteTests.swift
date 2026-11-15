import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// A pin muted in one window is muted in every window's tab for it
/// (feedback #2018, register 2569): each window holds a tab of its own for
/// a pin and a kept tab (SharedPins.swift, KeptEverywhere.swift), and the
/// one the person never touched pinged on.
@MainActor
@Suite(.serialized)
struct PinCopiesMuteTests {
    private let url = URL(string: "http://127.0.0.1:9/pinged")!

    private func windows(_ body: (Browser, Browser) throws -> Void) throws {
        _ = NSApplication.shared
        let one = UUID(), two = UUID()
        let a = Browser(windowID: one), b = Browser(windowID: two)
        defer {
            BrowserWindows.shared.handOffWindows = nil
            KeptEverywhere.known = [:]
            a.letGo(); b.letGo()
            for id in [one, two] { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        BrowserWindows.shared.handOffWindows = [a, b]
        try body(a, b)
    }

    private func tab(in browser: Browser) -> Tab {
        let tab = Tab(configuration: Web.configuration(store: Spaces.store(for: browser.spaceID)))
        browser.prepare(tab)
        tab.restore(url: url, title: "Pinged")
        return tab
    }

    @Test func aSharedPinMutedInOneWindowIsMutedInTheOther() throws {
        try #require(AudioWatch.canMute)
        try windows { a, b in
            let key = UUID()
            let pin = tab(in: a)
            pin.pin = "P"
            pin.everywhere = key
            a.lay([pin])
            let entry = try #require(a.sessionEntry(pin, id: key))
            let copy = try #require(b.madePin(entry, key: key))
            b.lay([copy])
            pin.mute(true)
            #expect(pin.muted && copy.muted, "the other window's tab for the pin must be muted too")
            copy.mute(false)
            #expect(!pin.muted && !copy.muted, "let back in from either window, both are")
        }
    }

    @Test func aCopyMadeAfterTheMuteComesInMuted() throws {
        try #require(AudioWatch.canMute)
        try windows { a, b in
            let key = UUID()
            let pin = tab(in: a)
            pin.pin = "P"
            pin.everywhere = key
            a.lay([pin])
            pin.mute(true)
            // A window opened since, or the copy left behind when the page
            // goes over to another window (BrowserWindows.handOff).
            let entry = try #require(a.sessionEntry(pin, id: key))
            let copy = try #require(b.madePin(entry, key: key))
            #expect(copy.muted, "a copy of a muted pin must come in muted")
        }
    }

    /// A space's own pins go by the same list as its kept tabs.
    @Test func aKeptTabMutedIsMutedInEveryWindowOfTheSpace() throws {
        try #require(AudioWatch.canMute)
        try windows { a, b in
            let pin = tab(in: a)
            let other = tab(in: a)
            a.lay([pin, other])
            a.keepTabs([pin])
            pin.mute(true)
            b.followKept(a.keptList(a.tabs), in: b.spaceID)
            let copy = try #require(b.tabs.first { KeptEverywhere.key($0) == KeptEverywhere.key(pin) })
            #expect(copy !== pin)
            #expect(copy.muted, "the second window's tab for a muted kept tab must be muted")
            #expect(!other.muted && !(b.tabs.first { $0 !== copy }?.muted ?? false), "only the pin's copies")
            pin.mute(false)
            #expect(!copy.muted)
        }
    }
}
