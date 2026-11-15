import Foundation
import Testing
@testable import Fast

/// Settings › Boosts: the list one sign-in sees, the order the person drags
/// it to, what is picked and what Delete asks.
@MainActor
struct BoostSettingsTests {
    private func record(_ id: String, _ name: String, sites: [String] = ["youtube.com"], on: Bool = true,
                        failures: Int = 0, day: Int = 1) -> BoostRecord {
        var record = BoostRecord(id: id, name: name, sites: sites, rung: .look, intent: "Hide it", author: "Claude", session: "s",
                                 revision: "r", updated: Date(timeIntervalSince1970: Double(day) * 86_400))
        record.enabled = on
        record.failures = failures
        return record
    }

    private func script(_ id: String, _ name: String, on: Bool = true, pending: Bool = false, day: Int = 1) -> Userscripts.Record {
        Userscripts.Record(id: id, name: name, version: "1.0", enabled: on, source: nil,
                           installed: Date(timeIntervalSince1970: 0), updated: Date(timeIntervalSince1970: Double(day) * 86_400), revision: "r",
                           pending: pending ? .init(version: "2.0", rights: ["GM_xmlhttpRequest"], revision: "x") : nil)
    }

    private func list(_ boosts: [BoostRecord], _ scripts: [Userscripts.Record] = [], asking: Set<String> = []) -> [BoostItem] {
        BoostItem.list(boosts: boosts, scripts: scripts, sites: [:], loaded: Set(boosts.map(\.id)), asking: asking,
                       scriptsLoaded: Set(scripts.map(\.id)))
    }

    @Test func rowsSaySiteEverySiteAndUserscript() {
        let items = list([record("a", "Calmer YouTube", sites: ["youtube.com", "m.youtube.com"]),
                          record("b", "Readable width", sites: ["<all_urls>"]),
                          record("c", "Wide", sites: ["github.com", "gist.github.com", "linear.app"]),
                          record("d", "Plain", sites: ["www.x.com"])],
                         [script("u", "Return Dislike")])
        #expect(items.map(\.place) == ["youtube.com", "Every site", "github.com and 1 more", "x.com", "userscript"])
        #expect(items[1].everySite && !items[0].everySite)
        #expect(items[4].kind == .userscript && items[4].markHost == nil)
    }

    @Test func troublesAreWordsBesideTheSwitch() {
        let items = list([record("a", "A", failures: 2), record("b", "B"), record("c", "C")], [script("u", "U", pending: true)], asking: ["b"])
        #expect(items[0].trouble == .stopped && items[0].warning == "Stopped working")
        #expect(items[1].trouble == .asksMore && items[1].detail == "youtube.com \u{00B7} New version asks for more")
        #expect(items[2].trouble == nil && items[2].warning == nil)
        #expect(items[3].trouble == .asksMore)
    }

    @Test func aBoostWhoseFilesWouldNotLoadIsBrokenAndOff() {
        let items = BoostItem.list(boosts: [record("a", "A")], scripts: [], sites: [:], loaded: [], asking: [], scriptsLoaded: [])
        #expect(items[0].trouble == .broken && items[0].warning == "Could not load" && !items[0].enabled)
    }

    @Test func aBoostAndAUserscriptWithOneIDAreTwoRows() {
        let items = list([record("same", "Boost")], [script("same", "Script")])
        #expect(Set(items.map(\.id)).count == 2)
    }

    @Test func orderIsTheDraggedOneThenNewestFirst() {
        let items = list([record("a", "A", day: 1), record("b", "B", day: 3), record("c", "C", day: 2), record("d", "D", day: 2)])
        #expect(BoostOrder.sorted(items, by: []).map(\.key) == ["b", "c", "d", "a"])
        #expect(BoostOrder.sorted(items, by: ["boost:a", "boost:c"]).map(\.key) == ["a", "c", "b", "d"])
        // An id that is gone stays out of the way.
        #expect(BoostOrder.sorted(items, by: ["boost:zzz", "boost:d"]).map(\.key) == ["d", "b", "c", "a"])
    }

    @Test func droppingARowMovesItInItsGroupAndLeavesTheOthers() {
        let all = ["1", "2", "3", "4", "5"]
        // Group On is 1, 3, 5; 5 is dropped first.
        #expect(BoostOrder.moved(all, group: ["1", "3", "5"], id: "5", to: 0) == ["5", "2", "1", "4", "3"])
        #expect(BoostOrder.moved(all, group: ["1", "3", "5"], id: "1", to: 2) == ["3", "2", "5", "4", "1"])
        #expect(BoostOrder.moved(all, group: ["1", "3", "5"], id: "3", to: 1) == all)
        #expect(BoostOrder.moved(all, group: ["1", "3"], id: "9", to: 0) == all)
        #expect(BoostOrder.moved(all, group: ["2", "4"], id: "2", to: 99) == ["1", "4", "3", "2", "5"])
    }

    @Test func picksCountToggleAndKeepOnlyWhatIsThere() {
        let items = list([record("a", "Wide diffs"), record("b", "Readable width", on: false), record("c", "Quiet sidebar")])
        var picks = BoostPicks()
        #expect(picks.words == "Select boosts" && !picks.canDelete(items))
        picks.toggle("boost:a")
        #expect(picks.words == "1 boost selected")
        picks.toggle("boost:b")
        picks.toggle("boost:c")
        #expect(picks.words == "3 boosts selected")
        picks.toggle("boost:c")
        #expect(picks.words == "2 boosts selected" && !picks.contains("boost:c"))
        // Turn On needs one that is off, Turn Off one that is on.
        #expect(picks.canTurnOn(items) && picks.canTurnOff(items) && picks.canDelete(items))
        var onlyOn = BoostPicks(); onlyOn.toggle("boost:a")
        #expect(!onlyOn.canTurnOn(items) && onlyOn.canTurnOff(items))
        var onlyOff = BoostPicks(); onlyOff.toggle("boost:b")
        #expect(onlyOff.canTurnOn(items) && !onlyOff.canTurnOff(items))
        // One gone from the list is gone from the picks.
        picks.keep(Array(items.prefix(1)))
        #expect(picks.count == 1 && picks.contains("boost:a"))
    }

    @Test func aBrokenBoostIsNotTurnedOn() {
        let items = BoostItem.list(boosts: [record("a", "A", on: false)], scripts: [], sites: [:], loaded: [], asking: [], scriptsLoaded: [])
        var picks = BoostPicks(); picks.toggle("boost:a")
        #expect(!picks.canTurnOn(items))
    }

    @Test func deleteAsksOnceWithTheNames() {
        let items = list([record("a", "Wide diffs"), record("b", "Readable width"), record("c", "Quiet sidebar")])
        #expect(BoostDeletion.title(items) == "Delete 3 boosts?")
        #expect(BoostDeletion.detail(items) == "Wide diffs, Readable width and Quiet sidebar stop changing their sites. A boost from the Store can be kept again from the Store.")
        #expect(BoostDeletion.title([items[0]]) == "Delete Wide diffs?")
        #expect(BoostDeletion.detail([items[0]]).hasPrefix("Wide diffs stops changing its site."))
        let scripts = list([], [script("u", "Return Dislike")])
        #expect(BoostDeletion.detail(scripts) == "Return Dislike stops running. It can be added again from its file.")
        #expect(BoostDeletion.names(["A", "B"]) == "A and B")
    }

    @Test func historyDatesReadAsToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 9, minute: 41))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 18, minute: 12))!
        let older = calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 11, minute: 5))!
        #expect(BoostWords.when(morning, now: now, calendar: calendar) == "Today, 9:41 AM")
        #expect(BoostWords.when(yesterday, now: now, calendar: calendar) == "Yesterday, 6:12 PM")
        #expect(BoostWords.when(older, now: now, calendar: calendar) == "Oct 22, 11:05 AM")
        #expect(BoostWords.made(kind: "Look", by: "Claude", on: older, calendar: calendar) == "Look \u{00B7} Made by Claude \u{00B7} Oct 22")
        #expect(BoostWords.made(kind: "Page", by: "You", on: older, calendar: calendar) == "Page \u{00B7} Made by you \u{00B7} Oct 22")
    }

    @Test func theSettingsPageIsInTheSidebarAndFound() {
        #expect(SettingsPage.sidebar.contains(.boosts))
        #expect(SettingsPage.boosts.title == "Boosts" && SettingsPage.boosts.tint == .systemPurple)
        #expect(PenArt.has(.boosts))
        #expect(SettingsPage.boosts.score("boosts") != nil)
        #expect(SettingsPage.boosts.found("userscripts") != nil)
        #expect(SettingsItem.all.contains { $0.id == "boosts" && $0.page == .boosts })
    }
}
