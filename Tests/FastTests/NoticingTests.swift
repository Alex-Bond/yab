import Foundation
import Testing
@testable import Fast
@testable import MailCore

// The one queue under the empty field (PLAN-hints §7): what an agent found,
// what yab noticed itself and your habits, in one order, and a meeting off
// the calendar that an agent found too as one row.
struct NoticingTests {
    static let now = ISO8601DateFormatter().date(from: "2026-09-25T09:00:00-07:00")!

    static func hint(_ id: String, source: Hint.Source?, due: TimeInterval? = nil, join: String? = nil,
                     copied: TimeInterval? = nil, routine: Bool = false, setup: Bool = false, title: String? = nil) -> Hint {
        Hint(id: id, icon: .symbol("x"), title: title ?? id, detail: "", setup: setup,
             routine: routine ? ["weekdays 9:00", "check"] : nil,
             due: due.map { now.addingTimeInterval($0) }, join: join.flatMap(URL.init(string:)),
             source: source, copied: copied.map { now.addingTimeInterval($0) })
    }

    @Test func oneQueueInThePlansOrder() {
        let found = [
            Self.hint("mail", source: .found),
            Self.hint("routine", source: .found, routine: true),
            Self.hint("flight", source: .found, due: 90 * 60),
        ]
        let noticed = [
            Self.hint("habit", source: .habit),
            Self.hint("copy", source: .noticed, copied: -12),
            Self.hint("meeting", source: .noticed, due: 20 * 60, title: "Design sync"),
        ]
        let setup = [Self.hint("setup.cli", source: nil, setup: true)]
        let order = Hints.order(found: found, noticed: noticed, setup: setup, now: Self.now).map(\.id)
        #expect(order == ["meeting", "flight", "copy", "mail", "habit", "routine", "setup.cli"])
    }

    // A dispute due tomorrow, a party tonight: before mail that waits on a
    // reply. One row a thread: the agent's, which read it, over yab's own.
    @Test func whatCantWaitGoesBeforeMailAndAThreadIsOneRow() {
        var danny = Self.hint("found.danny", source: .found)
        danny.url = URL(string: "yab://mail#thread=me@example.com%7Cdanny")
        let found = [
            Self.hint("found.stripe", source: .found, due: 30 * 3600),
            Self.hint("found.later", source: .found, due: 5 * 86_400),
            danny,
        ]
        let noticed = [
            Self.hint("mail.chase", source: .noticed),
            Self.hint("mail.danny", source: .noticed),
        ]
        let order = Hints.order(found: found, noticed: noticed, setup: [], now: Self.now).map(\.id)
        #expect(order == ["found.stripe", "mail.chase", "found.later", "found.danny"])
        #expect(Hints.mailThread(danny.url)?.thread == "danny")
        #expect(Hints.mailThread(URL(string: "https://mail.google.com/mail/u/0/#all/1a2b")) == nil)
        // yab's own mail page is a place a row may open.
        #expect(Hints.known("yab://mail#thread=me@example.com|danny", among: ["example.com"]))
    }

    // A short look at new mail: half an hour apart, eight a day.
    @MainActor @Test func aGlanceWaitsHalfAnHourAndEightADay() {
        #expect(Agents.mayGlance(now: Self.now, last: .distantPast, today: 0))
        #expect(!Agents.mayGlance(now: Self.now, last: Self.now.addingTimeInterval(-20 * 60), today: 0))
        #expect(Agents.mayGlance(now: Self.now, last: Self.now.addingTimeInterval(-31 * 60), today: 7))
        #expect(!Agents.mayGlance(now: Self.now, last: .distantPast, today: 8))
        let prompt = Agents.glancePrompt(threads: "- me@example.com|danny: Danny · Re: Fixed", rules: "", now: Self.now)
        #expect(prompt.contains("me@example.com|danny"))
        #expect(prompt.contains("`quiet`"))
        #expect(prompt.contains("mark nothing read"))
    }

    // Any mail the user reads in a browser: left as unread as it was found,
    // and people waiting judged by the look too, with Yab's mail or without.
    @MainActor @Test func theLookLeavesMailUnreadAndJudgesPeople() {
        let web = Agents.lookPrompt(live: "", rules: "", now: Self.now)
        #expect(web.contains("mark it unread again"))
        #expect(web.contains("Superhuman"))
        #expect(web.contains("a person waiting on their answer"))
        let here = Agents.lookPrompt(live: "", rules: "", now: Self.now, mailbox: true)
        #expect(here.contains("`quiet`"))
        #expect(!here.contains("yab puts what is due and who is waiting"))
    }

    @Test func aMeetingAnAgentFoundTooIsOneRow() {
        // The same call: the agent's row stays, with the calendar's time and Join.
        let found = [Self.hint("prep", source: .found, title: "Prepare: Mira's notes")]
        var agent = found
        agent[0].join = URL(string: "https://meet.google.com/abc-defg-hij")
        let meeting = Self.hint("cal", source: .noticed, due: 8 * 60, join: "https://meet.google.com/abc-defg-hij", title: "Weekly with Mira")
        let merged = Hints.order(found: agent, noticed: [meeting], setup: [], now: Self.now)
        #expect(merged.map(\.id) == ["prep"])
        #expect(merged[0].due == Self.now.addingTimeInterval(8 * 60))

        // Much the same name within five minutes, no link on the agent's.
        let named = [Self.hint("f", source: .found, due: 32 * 60, title: "Design sync")]
        let same = Self.hint("cal", source: .noticed, due: 30 * 60, join: "https://zoom.us/j/123456789", title: "Design Sync")
        let one = Hints.order(found: named, noticed: [same], setup: [], now: Self.now)
        #expect(one.map(\.id) == ["f"])
        #expect(one[0].due == Self.now.addingTimeInterval(30 * 60))
        #expect(one[0].join?.host() == "zoom.us")

        // Another meeting at another time is its own row.
        let other = Self.hint("cal2", source: .noticed, due: 50 * 60, title: "Design sync")
        #expect(Hints.order(found: named, noticed: [other], setup: [], now: Self.now).count == 2)
    }

    @Test func aShortNameIsNotAnotherMeeting() {
        func agent(_ title: String, due: TimeInterval, join: String? = nil) -> Hint {
            Self.hint("f", source: .found, due: due, join: join, title: title)
        }
        func calendar(_ title: String, due: TimeInterval, join: String? = nil) -> Hint {
            Self.hint("c", source: .noticed, due: due, join: join, title: title)
        }
        // "Sync" is a word of "Design Sync w/ Legal", not that meeting.
        #expect(!Hints.sameMeeting(agent("Sync", due: 600), calendar("Design Sync w/ Legal", due: 600)))
        let order = Hints.order(found: [agent("Sync", due: 900)], noticed: [calendar("Design Sync w/ Legal", due: 600)], setup: [], now: Self.now)
        #expect(order.count == 2)
        #expect(order.first { $0.id == "f" }?.due == Self.now.addingTimeInterval(900))
        // The same words, or most of them, are.
        #expect(Hints.sameMeeting(agent("Design sync", due: 600), calendar("Design Sync", due: 800)))
        #expect(Hints.sameMeeting(agent("Prepare: Design sync", due: 600), calendar("Design Sync", due: 600)))
        #expect(Hints.sameMeeting(agent("Design sync with Legal", due: 600), calendar("Design Sync w/ Legal", due: 600)))
        // Not more than five minutes apart.
        #expect(!Hints.sameMeeting(agent("Design sync", due: 0), calendar("Design Sync", due: 360)))
        // Two calls known decide it, whatever the names.
        let meet = "https://meet.google.com/abc-defg-hij", other = "https://meet.google.com/xyz-wxyz-xyz"
        #expect(Hints.sameMeeting(agent("Prep", due: 0, join: meet), calendar("Weekly", due: 3000, join: meet)))
        #expect(!Hints.sameMeeting(agent("Design sync", due: 600, join: other), calendar("Design Sync", due: 600, join: meet)))
    }

    @Test func aCopiedLinkSaysHowLongAgo() {
        var copied = Self.hint("copy", source: .noticed, copied: -12)
        copied = Hint(id: copied.id, icon: copied.icon, title: "PR", detail: "Slack", source: .noticed, copied: copied.copied)
        #expect(HintList.detail(copied, now: Self.now) == "Copied 12s ago · Slack")
        #expect(Hints.ago(Self.now.addingTimeInterval(-75), now: Self.now) == "1m ago")
    }

    @Test func aLinkCopiedIsOfferedForAMinuteAndAHalf() {
        let url = URL(string: "https://linear.app/yab/issue/YAB-418/clipboard-history")!
        let copy = CopiedLink(url: url, at: Self.now, app: "Slack")
        let row = Noticing.copied(copy, now: Self.now.addingTimeInterval(12), front: nil, title: "Clipboard history")
        #expect(row?.title == "Clipboard history")
        #expect(row.map { HintList.detail($0, now: Self.now.addingTimeInterval(12)) } == "Copied 12s ago · Slack")
        #expect(row?.url == url)
        #expect(row?.source == .noticed)
        #expect(Noticing.copied(copy, now: Self.now.addingTimeInterval(89), front: nil, title: nil) != nil)
        #expect(Noticing.copied(copy, now: Self.now.addingTimeInterval(90), front: nil, title: nil) == nil)
        // Not the page already in front, however it is written.
        let front = URL(string: "https://www.linear.app/yab/issue/YAB-418/clipboard-history/?utm_source=slack")!
        #expect(Noticing.copied(copy, now: Self.now, front: front, title: nil) == nil)
        // Copied in yab, the site says where; unknown, the address says what.
        let mine = Noticing.copied(CopiedLink(url: url, at: Self.now, app: nil), now: Self.now, front: nil, title: nil)
        #expect(mine?.detail == "linear.app")
        #expect(mine?.title == Address.pretty(url))
    }

    @Test func aMeetingWithinTheHourCountsDownThenJoins() {
        func meeting(_ id: String, in minutes: Double, link: String? = "https://meet.google.com/abc-defg-hij") -> Meeting {
            Meeting(id: id, title: id, start: Self.now.addingTimeInterval(minutes * 60),
                    end: Self.now.addingTimeInterval((minutes + 30) * 60), link: link.flatMap(URL.init(string:)))
        }
        let list = [meeting("soon", in: 35), meeting("later", in: 75), meeting("begun", in: -5), meeting("long ago", in: -40)]
        let rows = Noticing.meetings(list, now: Self.now)
        #expect(rows.map(\.title) == ["soon", "begun"])
        let soon = rows[0]
        #expect(HintList.detail(soon, now: Self.now) == "in 35m · On your calendar")
        #expect(!HintList.joining(soon, now: Self.now))
        #expect(HintList.joining(soon, now: Self.now.addingTimeInterval(26 * 60)))
        #expect(HintList.detail(soon, now: Self.now.addingTimeInterval(27 * 60)) == "in 8m · On your calendar")
        // A link that is not a call is somewhere to go, never Join.
        let page = Noticing.meetings([meeting("doc", in: 5, link: "https://docs.google.com/document/d/1")], now: Self.now)
        #expect(page.first?.join == nil)
        #expect(page.first?.url != nil)
        #expect(!HintList.joining(page[0], now: Self.now))
        // Up next in the one queue, before a link copied.
        let copied = Self.hint("copy", source: .noticed, copied: -3)
        #expect(Hints.order(found: [], noticed: [copied] + rows, setup: [], now: Self.now).map(\.id)
            == ["noticed.meeting.begun", "noticed.meeting.soon", "copy"])
    }

    @Test func overAPageOnlyWhatCantWaitTwoAtMost() {
        let queue = Hints.order(found: [
            Self.hint("mail", source: .found),
            Self.hint("deadline", source: .found, due: 40 * 60),
        ], noticed: [
            Self.hint("meeting", source: .noticed, due: 8 * 60, join: "https://meet.google.com/abc-defg-hij"),
            Self.hint("copy", source: .noticed, copied: -5),
            Self.hint("habit", source: .habit),
        ], setup: [Self.hint("setup.cli", source: nil, setup: true)], now: Self.now)
        #expect(Hints.overPage(queue, now: Self.now).map(\.id) == ["meeting", "copy"])
        // Twenty minutes off, the meeting waits for a new tab.
        #expect(Hints.overPage(queue, now: Self.now.addingTimeInterval(-12 * 60)).map(\.id) == ["copy"])
        #expect(Hints.overPage([Self.hint("mail", source: .found)], now: Self.now).isEmpty)
    }

    @Test func aPasswordManagersCopyIsNotTaken() {
        #expect(Clips.concealed(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(Clips.concealed(["org.nspasteboard.TransientType"]))
        #expect(!Clips.concealed(["public.utf8-plain-text", "public.url"]))
    }

    @Test func rowsKeptBeforeTheSourceWasSaidStillRead() throws {
        let old = #"[{"id":"a","icon":{"symbol":{"_0":"x"}},"title":"A","detail":"","setup":false}]"#
        let rows = try JSONDecoder().decode([Hint].self, from: Data(old.utf8))
        #expect(rows.first?.source == nil)
        #expect(rows.first?.local == false)
    }

    // Don't Show Things Like This on a row of yab's own: its kind for
    // everyone, or its sender's mail, and the look told the same in words.
    @MainActor @Test func thingsLikeThisTurnOffAKindOrAPerson() {
        func notice(_ who: String, _ address: String, _ why: Noticing.MailNotice.Why) -> Noticing.MailNotice {
            Noticing.MailNotice(account: "me@example.com", thread: who.lowercased(), who: who, host: "example.com", subject: "About \(who)",
                                gist: "", last: Self.now.addingTimeInterval(-2 * 86_400), due: nil, why: why, address: address)
        }
        let rows = Noticing.mail([
            notice("Anna", "anna@acme.com", .waitingOnYou),
            notice("Anna", "anna@acme.com", .noAnswer),
            notice("Petr", "petr@example.com", .waitingOnYou),
        ].enumerated().map { var n = $1; n.thread += String($0); return n }, now: Self.now)
        #expect(rows.compactMap(\.kind).sorted() == ["mail.noAnswer", "mail.waiting", "mail.waiting"])
        #expect(Set(rows.compactMap(\.sender?.address)) == ["anna@acme.com", "petr@example.com"])

        var off = Noticing.Off()
        off.people = [Hint.Sender(address: "anna@acme.com", name: "Anna")]
        #expect(rows.filter { !off.hides($0) }.map(\.sender?.name) == ["Petr"])

        off = Noticing.Off(kinds: ["mail.waiting"])
        #expect(rows.filter { !off.hides($0) }.map(\.kind) == ["mail.noAnswer"])
        #expect(off.said == ["mail where someone is waiting on the user's reply"])

        // Mail as a whole, Settings' switch: every mail row, nothing else.
        off = Noticing.Off(kinds: [Noticing.Kind.mail])
        #expect(rows.allSatisfy(off.hides))
        #expect(off.hides(Self.hint("mail.skipped", source: .noticed)))
        #expect(!off.hides(Self.hint("noticed.meeting.1", source: .noticed)))

        // Kinds of rows without a kind written on them come from their id.
        #expect(Noticing.Kind.of(Self.hint("noticed.meeting.1", source: .noticed)) == .meeting)
        #expect(Noticing.Kind.of(Self.hint("noticed.copy.x", source: .noticed)) == .copied)
        #expect(Noticing.Kind.of(Self.hint("habit.stripe.com", source: .habit)) == nil)
    }

    @MainActor @Test func theLookHearsWhatWasTurnedOffAndPutAway() {
        let prompt = Agents.lookPrompt(live: "", rules: "- mail from anna@acme.com", removed: "- Acme wants an answer (acme.com)", now: Self.now)
        #expect(prompt.contains("leave out anything of their kind:\n- mail from anna@acme.com"))
        #expect(prompt.contains("don't bring them back, under another link either:\n- Acme wants an answer (acme.com)"))
        #expect(!Agents.lookPrompt(live: "", rules: "", now: Self.now).contains("put these away"))
    }
}
