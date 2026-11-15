import AppKit
import Foundation
import Testing
@testable import Fast

/// The floating window's minimize (rows 1090, 1038): the video plays on in
/// its tab and Picture in Picture automatically leaves it there while you
/// stay on other tabs, until you come back to its tab and leave it again.
@MainActor
@Suite(.serialized)
struct FloatMinimizeTests {
    private let video = UUID()
    private let notes = UUID()
    private let mail = UUID()

    @Test func noHoldAllowsEveryTab() {
        var hold = MinimizeHold()
        let allowed1 = hold.allowsAuto(video)
        #expect(allowed1)
        let allowed2 = hold.allowsAuto(nil)
        #expect(allowed2)
    }

    @Test func aMinimizedVideoStaysWhileYouAreElsewhere() {
        var hold = MinimizeHold()
        hold.minimized(video)
        // Other tabs in front and left: none of them is the video's.
        hold.shown(notes)
        let allowed3 = hold.allowsAuto(notes)
        #expect(allowed3)
        hold.shown(mail)
        let allowed4 = hold.allowsAuto(mail)
        #expect(allowed4)
        // Its own tab, never brought back to the front, stays held, again
        // and again.
        let allowed5 = hold.allowsAuto(video)
        #expect(!allowed5)
        let allowed6 = hold.allowsAuto(video)
        #expect(!allowed6)
        #expect(hold.tab == video)
    }

    @Test func comingBackToItsTabAndLeavingFloatsItAgain() {
        var hold = MinimizeHold()
        hold.minimized(video)
        hold.shown(video)
        #expect(hold.back)
        let allowed7 = hold.allowsAuto(video)
        #expect(allowed7)
        // The hold is spent: the leave after that floats as ever.
        #expect(hold.tab == nil)
        let allowed8 = hold.allowsAuto(video)
        #expect(allowed8)
    }

    @Test func minimizedWithItsTabInFrontIsNotComingBack() {
        // Yab left with the video in front floats it; minimized there, its
        // tab is still the one in front, but nobody came back to it.
        var hold = MinimizeHold()
        hold.minimized(video)
        #expect(!hold.back)
        let allowed9 = hold.allowsAuto(video)
        #expect(!allowed9)
    }

    @Test func floatingByHandEndsTheHold() {
        var hold = MinimizeHold()
        hold.minimized(video)
        hold.forget()
        let allowed10 = hold.allowsAuto(video)
        #expect(allowed10)
    }

    @Test func aSecondMinimizeHoldsTheNewVideo() {
        var hold = MinimizeHold()
        hold.minimized(video)
        hold.shown(video)
        hold.minimized(notes)
        #expect(!hold.back)
        let allowed11 = hold.allowsAuto(video)
        #expect(allowed11)
        let allowed12 = hold.allowsAuto(notes)
        #expect(!allowed12)
    }

    @Test func theBrowserMarksTheVideosTabComingBack() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tabs = (0..<2).map { number in
            let tab = Fast.Tab()
            tab.restore(url: URL(string: "https://float-minimize.invalid/\(number)")!, title: "Tab \(number)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        defer {
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            tabs.forEach { $0.close() }
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
            }
        }
        browser.activeID = tabs[1].id
        browser.minimizeHold.minimized(tabs[0].id)
        // Nothing floats the video back while another tab is in front.
        #expect(!browser.minimizeHold.back)
        browser.activeID = tabs[0].id
        #expect(browser.minimizeHold.back)
    }
}
