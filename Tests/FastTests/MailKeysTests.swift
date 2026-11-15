import AppKit
import Testing
@testable import Fast

// Mail's keys (docs/mail.md, Keys): every one an action of Keymap's Mail
// group, so Settings › Shortcuts lists it and can give it another key, no
// two on one key, G and the key after it fixed and shown there too; and
// picking rows to act on together (MailSelection).
struct MailKeysTests {
    static let mail = Shortcut.all.first { $0.title == "Mail" }?.items ?? []

    /// The keys P1.1 brought, and P1.9's L, V and Y.
    static let added: [Shortcut.Action] = [
        .mailStar, .mailTrash, .mailSpam, .mailMute, .mailNotDone,
        .mailSelect, .mailSelectDown, .mailSelectUp, .mailSelectBelow, .mailSelectAll,
        .mailOnlyUnread, .mailOnlyStarred, .mailOnlyUnanswered, .mailKeys,
        .mailLabel, .mailMove, .mailUnlabel,
    ]

    @Test func noTwoMailActionsOnOneKey() {
        // One key may be two actions never heard in the same place: one
        // only in a draft, one only in the list (Keymap.apart).
        let keyed = Self.mail.compactMap { item in item.action.flatMap { action in item.key.map { (action, $0) } } }
        for (n, one) in keyed.enumerated() {
            for other in keyed.dropFirst(n + 1) where one.1 == other.1 {
                #expect(Keymap.apart(one.0, other.0), "\(one.0.rawValue) and \(other.0.rawValue) share \(one.1.text)")
            }
        }
        let keys = keyed.map(\.1)
        // G is given to no action: it waits for the key after it.
        #expect(!keys.contains(MailGo.key))
        #expect(Self.mail.contains { $0.holds == [MailGo.key] })
        // The keys after G each go one place.
        let after = MailGo.places.map(\.key)
        #expect(after.count == Set(after).count)
    }

    @MainActor @Test func everyNewActionIsInSettingsShortcuts() {
        let listed = Set(Self.mail.compactMap(\.action))
        for action in Self.added {
            #expect(listed.contains(action), "\(action.rawValue) isn't in Settings › Shortcuts")
            #expect(Shortcut.context(action) == .mail)
            let item = Shortcut.byAction[action]
            #expect(item?.does.isEmpty == false && item?.taken.isEmpty == false)
            if let key = item?.key { #expect(Keymap.valid(key, for: action), "\(action.rawValue)") }
        }
        // G and each list it goes to, as rows of their own.
        for place in MailGo.places {
            #expect(Self.mail.contains { $0.fixed == [["G"], place.key.caps] && $0.does == "Go to " + place.name })
        }
    }

    /// ⇧⌘A: every message in the list, and free slots in a draft. Both
    /// keep it, Settings › Shortcuts shows it on both rows, and a third
    /// heard in a draft can't take it too.
    @MainActor @Test func oneKeyForTheListAndTheDraft() {
        let both = Hotkey("a", [.shift, .command])
        #expect(Shortcut.byAction[.mailSelectAll]?.key == both && Shortcut.byAction[.mailSlots]?.key == both)
        #expect(!Keymap.conflicts(.mailSelectAll, both, .mailSlots, both))
        #expect(Keymap.conflicts(.mailSlots, both, .mailBcc, both))
        #expect(Keymap.conflicts(.mailSelectAll, both, .mailStar, both))
        let resolved = Keymap.resolve(Shortcut.items.enumerated().compactMap { order, item in
            item.action.flatMap { action in item.key.map { Keymap.Binding(action: action, key: $0, priority: 1, order: order) } }
        })
        #expect(resolved[.mailSelectAll] == both && resolved[.mailSlots] == both)
        #expect(Keymap.shared.text(.mailSlots) == "⇧⌘A" && Keymap.shared.text(.mailSelectAll) == "⇧⌘A")
        // An invitation's answers: A, M, N, each a command of ⌘K and ?.
        #expect([Shortcut.Action.mailAccept, .mailMaybe, .mailDecline].map { Shortcut.byAction[$0]?.key?.text } == ["A", "M", "N"])
        for action in [Shortcut.Action.mailAccept, .mailMaybe, .mailDecline, .mailSlots] {
            #expect(Shortcut.context(action) == .mail)
            #expect(Browser.command(forKey: action.rawValue) != nil, "\(action.rawValue) has no command")
            if let key = Shortcut.byAction[action]?.key { #expect(Keymap.valid(key, for: action), "\(action.rawValue)") }
        }
        // Heard while words are written: never a key with no modifier.
        #expect(!Keymap.valid(Hotkey("a", []), for: .mailSlots))
    }

    @Test func theKeysAsTheirMarks() {
        #expect(Shortcut.byAction[.mailTrash]?.key?.text == "#")
        #expect(Shortcut.byAction[.mailSpam]?.key?.text == "!")
        #expect(Shortcut.byAction[.mailKeys]?.key?.text == "?")
        #expect(Shortcut.byAction[.mailMute]?.key?.text == "⇧M")
        #expect(Shortcut.byAction[.mailSelectAll]?.key?.text == "⇧⌘A")
        // Only ⇧ with a digit or a mark: ⌃⇧1 stays as it was.
        #expect(Hotkey("1", [.control, .shift]).text == "⌃⇧1")
        #expect(Hotkey.typed("⇧3") == "#")
    }

    @MainActor @Test func everyActOnThreadsIsACommandToo() {
        for action in [Shortcut.Action.mailStar, .mailTrash, .mailSpam, .mailMute, .mailNotDone, .mailDone,
                       .mailSelect, .mailSelectBelow, .mailSelectAll, .mailOnlyUnread, .mailOnlyStarred, .mailOnlyUnanswered,
                       .mailLabel, .mailMove, .mailUnlabel] {
            #expect(Browser.command(forKey: action.rawValue) != nil, "\(action.rawValue) has no command for ⌘K and ?")
        }
        #expect(Browser.command(forKey: "Go to Starred") == "go:starred")
        // G then L: the labels to pick one from.
        #expect(Browser.command(forKey: "Go to a label") == "go:label")
        #expect(Shortcut.byAction[.mailLabel]?.key?.text == "L" && Shortcut.byAction[.mailMove]?.key?.text == "V"
                && Shortcut.byAction[.mailUnlabel]?.key?.text == "Y")
        // ?'s rows are Settings' rows, with their keys as they are now.
        let starring = Shortcut.byAction[.mailStar]!
        #expect(Browser.keys(starring) == Keymap.shared.text(.mailStar))
        let going = Self.mail.first { $0.does == "Go to Starred" }!
        #expect(Browser.keys(going) == "G S")
    }

    // MARK: - picking rows

    let rows = ["a", "b", "c", "d", "e"]

    @Test func xPicksAndLetsGo() {
        var picked = MailSelection()
        picked.toggle("b")
        picked.toggle("d")
        #expect(picked.ids == ["b", "d"])
        picked.toggle("b")
        #expect(picked.ordered(rows) == ["d"])
    }

    @Test func aRunGrowsAndShrinks() {
        var picked = MailSelection()
        // ⇧J twice from b: b, c, d; ⇧K back: b, c; on past b: a, b.
        picked.extend(rows, from: 1, to: 2)
        picked.extend(rows, from: 2, to: 3)
        #expect(picked.ordered(rows) == ["b", "c", "d"])
        picked.extend(rows, from: 3, to: 2)
        #expect(picked.ordered(rows) == ["b", "c"])
        picked.extend(rows, from: 2, to: 1)
        picked.extend(rows, from: 1, to: 0)
        #expect(picked.ordered(rows) == ["a", "b"])
        // X keeps what the run picked; the next run starts where it is.
        picked.toggle("e")
        picked.extend(rows, from: 3, to: 2)
        #expect(picked.ordered(rows) == ["a", "b", "c", "d", "e"])
        // A move by itself (J, K) ends the run too.
        picked.clear()
        picked.extend(rows, from: 0, to: 1)
        picked.ended()
        picked.extend(rows, from: 3, to: 4)
        #expect(picked.ordered(rows) == ["a", "b", "d", "e"])
    }

    @Test func fromHereAllAndNone() {
        var picked = MailSelection()
        picked.toggle("a")
        picked.below(rows, from: 3)
        #expect(picked.ordered(rows) == ["a", "d", "e"])
        picked.all(rows)
        #expect(picked.count == 5)
        picked.clear()
        #expect(picked.isEmpty)
    }

    @Test func rowsGoneLetGo() {
        var picked = MailSelection()
        picked.all(rows)
        picked.keep(["a", "c"])
        #expect(picked.ordered(rows) == ["a", "c"])
        let same = picked
        picked.keep(["a", "b", "c"])
        #expect(picked == same)
    }
}
