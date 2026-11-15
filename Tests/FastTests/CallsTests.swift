import Foundation
import Testing
import WebKit
@testable import Fast
@testable import MailCore

// Calls: which links are meetings, what a pinned calendar says, and the dot.
struct CallsTests {
    static func key(_ address: String) -> String? { CallLink.key(URL(string: address)) }

    @Test func meetingLinks() {
        #expect(Self.key("https://meet.google.com/abc-defg-hij") == "meet:abc-defg-hij")
        #expect(Self.key("https://meet.google.com/ABC-DEFG-HIJ?authuser=1&pli=1") == "meet:abc-defg-hij")
        #expect(Self.key("https://meet.google.com/lookup/standup") == "meet:standup")
        #expect(Self.key("https://us02web.zoom.us/j/81234567890?pwd=x") == "zoom:81234567890")
        #expect(Self.key("https://app.zoom.us/wc/81234567890/join") == "zoom:81234567890")
        #expect(Self.key("https://app.zoom.us/wc/join/86150653073?pwd=x") == "zoom:86150653073")
        #expect(Self.key("https://teams.cloud.microsoft/l/meetup-join/19%3ameeting_x%40thread.v2/0") != nil)
        #expect(Self.key("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0") != nil)
        #expect(Self.key("https://teams.live.com/meet/9876") == "teams:9876")
        #expect(Self.key("https://app.slack.com/huddle/T01/C02") == "slack:T01/C02")
        #expect(Self.key("https://acme.webex.com/meet/jane") == "webex:acme.webex.com/jane")
    }

    @Test func notMeetings() {
        #expect(Self.key("https://meet.google.com/") == nil)
        #expect(Self.key("https://meet.google.com/landing") == nil)
        #expect(Self.key("https://zoom.us/pricing") == nil)
        #expect(Self.key("https://teams.microsoft.com/v2/") == nil)
        #expect(Self.key("https://teams.cloud.microsoft/v2/") == nil)
        #expect(Self.key("https://app.zoom.us/wc/home") == nil)
        #expect(Self.key("https://app.slack.com/client/T01/C02") == nil)
        #expect(Self.key("https://example.com/j/123") == nil)
        #expect(Self.key("mailto:meet.google.com") == nil)
    }

    /// Leave with no button of the page's own closes a tab only when it is
    /// the call: Slack's and Teams' apps stay open.
    @Test func leaveKeepsAppTabs() {
        #expect(Browser.closesOnLeave(URL(string: "https://meet.google.com/abc-defg-hij")))
        #expect(Browser.closesOnLeave(URL(string: "https://app.zoom.us/wc/86150653073/start")))
        #expect(!Browser.closesOnLeave(URL(string: "https://app.slack.com/client/T01/C02")))
        #expect(!Browser.closesOnLeave(URL(string: "https://teams.cloud.microsoft/v2/")))
        #expect(!Browser.closesOnLeave(URL(string: "https://example.com/room")))
        #expect(!Browser.closesOnLeave(nil))
    }

    /// Slack is told Chrome, for its huddles; every other site Yab's own agent.
    @Test func slackHearsChrome() {
        #expect(SiteAgent.agent(for: URL(string: "https://app.slack.com/client/T01/C02"))?.contains("Chrome/") == true)
        #expect(SiteAgent.agent(for: URL(string: "https://slack.com/")) == nil)
        #expect(SiteAgent.agent(for: URL(string: "http://app.slack.com/")) == nil)
        #expect(SiteAgent.agent(for: URL(string: "https://meet.google.com/abc-defg-hij")) == nil)
        let day = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        #expect(SiteAgent.chrome(on: day).contains("Chrome/154.0.0.0 "))
        #expect(SiteAgent.isOurs(SiteAgent.chrome()) && !SiteAgent.isOurs(DeviceMode.android))
    }

    /// A site that hands out its Chrome extension only to Chrome is told
    /// Chrome, with and without "www.", including Superhuman's mail app.
    @Test func extensionPagesHearChrome() {
        #expect(SiteAgent.agent(for: URL(string: "https://superhuman.com/mail/download"))?.contains("Chrome/") == true)
        #expect(SiteAgent.agent(for: URL(string: "https://www.superhuman.com/mail/download"))?.contains("Chrome/") == true)
        #expect(SiteAgent.agent(for: URL(string: "https://mail.superhuman.com/"))?.contains("Chrome/") == true)
        #expect(SiteAgent.chromeLike("superhuman.com") && SiteAgent.chromeLike("joinhoney.com"))
        #expect(SiteAgent.chromeLike("mail.superhuman.com"))
        #expect(!SiteAgent.chromeLike("app.slack.com") && !SiteAgent.chromeLike(nil))
        #expect(SiteAgent.agent(for: URL(string: "http://mail.superhuman.com/")) == nil)
        #expect(SiteAgent.agent(for: URL(string: "https://mail.superhuman.com.example.org/")) == nil)
        #expect(SiteAgent.agent(for: URL(string: "https://accounts.google.com/")) == nil)
    }

    /// The call's own switches are read on Meet and on Zoom's every host.
    @Test func relayHosts() {
        #expect(CallRelay.serves("meet.google.com"))
        #expect(CallRelay.serves("app.zoom.us") && CallRelay.serves("us06web.zoom.us") && CallRelay.serves("zoom.us"))
        #expect(!CallRelay.serves("zoom.us.example.com") && !CallRelay.serves("notzoom.us"))
        #expect(CallRelay.serves("app.slack.com") && !CallRelay.serves("slack.com"))
    }

    @Test func linkInNotes() {
        let notes = "Agenda: roadmap\nJoin: https://meet.google.com/abc-defg-hij\nOr dial +1 555"
        #expect(CallLink.find(in: notes)?.absoluteString == "https://meet.google.com/abc-defg-hij")
        #expect(CallLink.find(in: "See https://example.com and https://zoom.us/j/123")?.absoluteString == "https://zoom.us/j/123")
        #expect(CallLink.find(in: "No call here, https://example.com") == nil)
        #expect(CallLink.find(in: nil) == nil)
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func meeting(_ minutes: Double, for length: Double = 30, link: String? = "https://meet.google.com/abc-defg-hij") -> Meeting {
        let start = now.addingTimeInterval(minutes * 60)
        return Meeting(id: "\(minutes)", title: "M", start: start, end: start.addingTimeInterval(length * 60),
                       link: link.flatMap(URL.init(string:)))
    }

    @Test @MainActor func pinCountsDown() {
        #expect(Meetings.badge(in: [Self.meeting(12)], at: Self.now) == .minutes(12))
        #expect(Meetings.badge(in: [Self.meeting(11.2)], at: Self.now) == .minutes(12))
        #expect(Meetings.badge(in: [Self.meeting(59)], at: Self.now) == .minutes(59))
        // More than an hour off: nothing.
        #expect(Meetings.badge(in: [Self.meeting(61)], at: Self.now) == nil)
        #expect(Meetings.badge(in: [], at: Self.now) == nil)
    }

    @Test @MainActor func pinJoins() {
        #expect(Meetings.badge(in: [Self.meeting(0.5)], at: Self.now) == .join)
        #expect(Meetings.badge(in: [Self.meeting(-9)], at: Self.now) == .join)
        // Ten minutes in, it is let go; already in it, nothing to join.
        #expect(Meetings.badge(in: [Self.meeting(-11)], at: Self.now) == nil)
        #expect(Meetings.badge(in: [Self.meeting(0.5)], at: Self.now, inCall: { $0 == "meet:abc-defg-hij" }) == nil)
        // No link: a countdown, never Join.
        #expect(Meetings.badge(in: [Self.meeting(0.5, link: nil)], at: Self.now) == nil)
        #expect(Meetings.badge(in: [Self.meeting(5, link: nil)], at: Self.now) == .minutes(5))
        // The sooner of two.
        #expect(Meetings.badge(in: [Self.meeting(0.5), Self.meeting(20)], at: Self.now) == .join)
    }

    @Test @MainActor func lastFiveMinutes() {
        let key = "meet:abc-defg-hij"
        #expect(Meetings.minutesLeft(in: [Self.meeting(-25, for: 30)], for: key, at: Self.now) == 5)
        #expect(Meetings.minutesLeft(in: [Self.meeting(-28.5, for: 30)], for: key, at: Self.now) == 2)
        #expect(Meetings.minutesLeft(in: [Self.meeting(-10, for: 30)], for: key, at: Self.now) == nil)
        #expect(Meetings.minutesLeft(in: [Self.meeting(-25, for: 30)], for: "meet:other-call-xyz", at: Self.now) == nil)
        #expect(Meetings.minutesLeft(in: [Self.meeting(-31, for: 30)], for: key, at: Self.now) == nil)
    }

    @Test @MainActor func calendars() {
        #expect(Meetings.isCalendar(URL(string: "https://calendar.google.com/calendar/u/0/r")))
        #expect(Meetings.isCalendar(URL(string: "https://outlook.office.com/calendar/view/week")))
        #expect(!Meetings.isCalendar(URL(string: "https://outlook.office.com/mail/inbox")))
        #expect(!Meetings.isCalendar(URL(string: "https://google.com/calendar")))
        for page in ["https://calendar.proton.me/u/0/week", "https://calendar.amie.so/", "https://calendar.vimcal.com/home",
                     "https://web.morgen.so/", "https://calendar.zoho.com/zc/", "https://calendar.zoho.eu/zc/"] {
            #expect(Meetings.isCalendar(URL(string: page)), "\(page)")
        }
        #expect(!Meetings.isCalendar(URL(string: "https://www.zoho.com/calendar/")))
    }

    @Test @MainActor func dot() {
        #expect(CaptureDot.look(.active, .active) == (filled: true, red: true))
        #expect(CaptureDot.look(.active, .muted) == (filled: false, red: true))
        #expect(CaptureDot.look(.none, .muted) == (filled: false, red: true))
        #expect(CaptureDot.look(.muted, .muted) == (filled: false, red: false))
        #expect(CaptureDot.look(.active, .none) == (filled: true, red: true))
        #expect(CaptureDot.look(.muted, .none) == (filled: false, red: false))
        #expect(CaptureDot.help(.active, .muted) == "Muted, click to unmute")
        #expect(CaptureDot.help(.active, .none) == "Camera on, click to turn off")
    }

    /// The call window's microphone and camera wear one mark at a time,
    /// the slashed one when off, and set as they are on the first word.
    @MainActor @Test func marksTurnOver() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        controls.layout()
        func marks(_ help: String) -> [Float] {
            let button = controls.pressable.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == help }
            // The two marks, over the hover wash.
            return Array(button?.layer?.sublayers?.suffix(2).map(\.opacity) ?? [])
        }
        #expect(marks("Mute") == [1, 0])
        #expect(marks("Turn camera off") == [1, 0])
        controls.show(mic: .muted, camera: .none)
        #expect(marks("Unmute") == [0, 1])
        #expect(marks("Turn camera off") == [0, 1])
        controls.show(mic: .active, camera: .active)
        #expect(marks("Mute") == [1, 0])
        #expect(marks("Turn camera off") == [1, 0])
    }

    /// The row: an arrow by the microphone or the camera only where its
    /// menu has a choice and the window has room, Share while the page has
    /// one of its own or your screen is out, and its mark in the corner
    /// while the buttons are away.
    @MainActor @Test func row() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        controls.show(presenting: false, sharable: true, choice: (mic: true, camera: false))
        controls.layout()
        #expect(controls.benchState()["arrows"] as? [String] == ["mic"])
        #expect(controls.benchState()["share"] as? String == "Share screen")
        #expect(controls.benchState()["showing_badge"] as? Bool == false)
        controls.show(presenting: true, sharable: true, choice: (mic: true, camera: false))
        controls.layout()
        #expect(controls.benchState()["share"] as? String == "Stop sharing")
        #expect(controls.benchState()["showing_badge"] as? Bool == true)

        let narrow = CallControls(frame: NSRect(x: 0, y: 0, width: 260, height: 146))
        narrow.show(presenting: false, sharable: false, choice: (mic: true, camera: true))
        narrow.layout()
        #expect((narrow.benchState()["arrows"] as? [String])?.isEmpty == true)
        #expect(narrow.benchState()["share"] as? String == "")
    }

    /// A word stands in the row's place while the buttons are away, clear
    /// of the marks in the corner, and over the row while they show; the
    /// band it or the row takes lifts your picture, and frees it after.
    @MainActor @Test func noteTakesTheRowsPlace() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        var bands: [CGFloat] = []
        controls.onBand = { bands.append($0) }
        func spot() -> NSRect { NSRectFromString(controls.benchState()["note_frame"] as? String ?? "") }
        controls.say("AirPods Pro connected", use: {}, for: 6)
        controls.layout()
        #expect(spot().minY == 19)
        #expect(bands == [60])
        controls.fade(to: 1, over: 0)
        controls.layout()
        #expect(spot().minY == 60)
        controls.fade(to: 0, over: 0)
        controls.show(mic: .muted, camera: .active)
        controls.layout()
        #expect(spot().minY == 19)
        #expect(spot().minX >= 14 + 28 + 4)
        controls.hush()
        #expect(bands == [60, 0])
    }

    /// Glass nesting must preserve every hit target, capsule tint and fade
    /// at the call window's minimum size as well as with device arrows.
    @MainActor @Test(arguments: [CGFloat(240), 260, 352]) func glassTargets(width: CGFloat) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let controls = CallControls(frame: NSRect(x: 20, y: 30, width: width, height: width * 9 / 16))
        host.addSubview(controls)
        controls.show(mic: .active, camera: .active)
        controls.show(presenting: false, sharable: true, choice: (mic: true, camera: true))
        controls.layoutSubtreeIfNeeded()
        controls.fade(to: 1, over: 0)
        controls.layoutSubtreeIfNeeded()

        func plate(_ view: NSView) -> FloatGlass? {
            var parent = view.superview
            while let current = parent {
                if let glass = current as? FloatGlass { return glass }
                parent = current.superview
            }
            return nil
        }
        let buttons = controls.pressable.compactMap { $0 as? NSButton }
        for button in buttons where !button.isHiddenOrHasHiddenAncestor && button.isEnabled {
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
            #expect(controls.hitTest(point) === button)
            let frame = controls.convert(button.bounds, from: button)
            #expect(controls.bounds.contains(frame))
            #expect(plate(button) != nil)
        }
        let mic = buttons.first { $0.accessibilityLabel() == "Mute" }!
        let more = buttons.first { $0.accessibilityLabel() == "Microphone and speaker" }!
        #expect(plate(mic) === plate(more))
        #expect(more.isHidden == (width < 300))
        if #available(macOS 26.0, *) {
            #expect(controls.benchState()["glass_native"] as? Bool == true)
        } else {
            #expect(controls.benchState()["glass_native"] as? Bool == false)
        }
        controls.show(mic: .muted, camera: .muted)
        controls.layoutSubtreeIfNeeded()
        #expect(plate(mic)?.tintColor == CallControls.red)
        controls.show(mic: .active, camera: .active)
        controls.layoutSubtreeIfNeeded()
        #expect(plate(mic)?.tintColor == nil)

        controls.say("AirPods Pro connected", use: {}, for: 6)
        controls.layoutSubtreeIfNeeded()
        let use = buttons.first { $0.title == "Use" }!
        #expect(controls.hitTest(use.convert(NSPoint(x: use.bounds.midX, y: use.bounds.midY), to: host)) === use)
        controls.hush()
        controls.fade(to: 0, over: 0)
        #expect(controls.faded.allSatisfy { $0.alphaValue == 0 })
        #expect(controls.hitTest(mic.convert(NSPoint(x: 19, y: 19), to: host)) === controls)
        controls.stopWatching()
    }

    /// What the page says beyond its people, as the stage answers it.
    @Test func news() {
        let news = CallNews([
            "waiting": [["name": "Alex Morgan", "face": "https://lh3.googleusercontent.com/a"], ["name": ""]],
            "unread": 2, "recording": true, "hand": true, "captions": false,
            "canHand": true, "canCaptions": true, "canReact": false, "canChat": true,
            "talking": true, "handsUp": false,
            "events": [["kind": "message", "name": "Karen Taylor", "text": "Hi"], ["kind": "react", "name": "Eric", "emoji": "🎉"],
                       ["kind": "nonsense"]],
        ] as [String: Any])
        #expect(news.waiting.map(\.name) == ["Alex Morgan"])
        #expect(news.waiting.first?.face?.host == "lh3.googleusercontent.com")
        #expect(news.unread == 2 && news.recording && news.myHand && !news.captions)
        #expect(news.hasMore && !news.canReact)
        #expect(news.events == [.message(name: "Karen Taylor", words: "Hi", face: nil), .react(name: "Eric", emoji: "🎉")])
        #expect(CallNews(nil) == CallNews())
        #expect(!CallNews().hasMore)
    }

    /// ⋯ turns the row over and back: every row in the middle of the
    /// window, ‹ and Leave at its right end; your hand up stands in the main
    /// row, light, to be put down in one press.
    @MainActor @Test func secondRow() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        var news = CallNews()
        (news.canHand, news.canCaptions, news.canReact, news.canChat) = (true, true, true, true)
        controls.show(presenting: false, sharable: true, choice: (mic: true, camera: true))
        controls.show(news: news)
        controls.layout()
        func frame(_ name: String) -> NSRect {
            let button = controls.pressable.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == name && !$0.isHiddenOrHasHiddenAncestor }
            return button.map { controls.convert($0.bounds, from: $0) } ?? .zero
        }
        let leave = frame("Leave the call"), more = frame("More")
        #expect(more.width == 38)
        func centered() -> Bool {
            let shown = controls.pressable.compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height == 38 }
                .map { controls.convert($0.bounds, from: $0) }.filter { $0.minY == 14 }
            guard let left = shown.map(\.minX).min(), let right = shown.map(\.maxX).max() else { return false }
            return abs((left + right) / 2 - 176) <= 1
        }
        #expect(centered())
        controls.press("more")
        controls.layout()
        #expect(controls.row == .more)
        #expect(centered())
        #expect(frame("Back").maxX + 8 == frame("Leave the call").minX)
        #expect(frame("Raise hand").width == 38 && frame("Captions").width == 38 && frame("Message everyone").width == 38)
        #expect(frame("Mute") == .zero)
        controls.press("react")
        controls.layout()
        #expect(controls.row == .faces)
        #expect(frame("Back").maxX + 8 == frame("Leave the call").minX)
        #expect(frame("Leave the call").maxX > leave.minX)
        var asked: [CallAsk] = []
        controls.onAsk = { asked.append($0) }
        controls.press("👍")
        #expect(asked == [.react("👍")])
        #expect(controls.row == .main)

        news.myHand = true
        controls.show(news: news)
        controls.layout()
        #expect(frame("Lower hand").width == 38)
        #expect(frame("Leave the call").minX > leave.minX)
        controls.stopWatching()
    }

    /// Under 300 points the buttons keep their size (38, Leave 52, 8
    /// apart), the arrows go and Share goes behind ⋯; the ribbon of faces
    /// is four in 140 there, seven in 178 otherwise.
    @MainActor @Test func narrowRow() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 260, height: 146))
        var news = CallNews()
        (news.canHand, news.canCaptions, news.canReact, news.canChat) = (true, true, true, true)
        controls.show(presenting: false, sharable: true, choice: (mic: true, camera: true))
        controls.show(news: news)
        controls.layout()
        func frame(_ name: String) -> NSRect {
            let button = controls.pressable.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == name && !$0.isHiddenOrHasHiddenAncestor }
            return button.map { controls.convert($0.bounds, from: $0) } ?? .zero
        }
        let mute = frame("Mute"), camera = frame("Turn camera off"), more = frame("More"), leave = frame("Leave the call")
        #expect(mute.width == 38 && camera.width == 38 && more.width == 38 && leave.width == 52)
        #expect(camera.minX - mute.maxX == 8 && leave.minX - more.maxX == 8)
        #expect(frame("Share screen") == .zero)
        #expect(controls.benchState()["arrows"] as? [String] == [])
        controls.press("more")
        controls.layout()
        let share = frame("Share screen"), back = frame("Back")
        #expect(share.width == 38)
        #expect(share.minX >= 6 && back.maxX <= 254)
        controls.press("react")
        controls.layout()
        let faces = NSRectFromString((controls.benchState()["frames"] as? [String: String])?["faces"] ?? "")
        #expect(faces.width == 140)
        #expect(faces.minX >= 6 && frame("Back").maxX <= 254 && !faces.intersects(frame("Back")))
        controls.stopWatching()

        let wide = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        wide.show(presenting: false, sharable: true, choice: (mic: false, camera: false))
        wide.show(news: news)
        wide.layout()
        wide.press("more")
        wide.press("react")
        wide.layout()
        #expect(NSRectFromString((wide.benchState()["frames"] as? [String: String])?["faces"] ?? "").width == 178)
        wide.stopWatching()
    }

    /// With the buttons away: the marks along the bottom left, 24 at 14 in,
    /// 28 apart, your hand among them; a message never brings the buttons up.
    @MainActor @Test func marksAndQuiet() {
        let controls = CallControls(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        var asked: [CallAsk] = []
        controls.onAsk = { asked.append($0) }
        controls.show(mic: .muted, camera: .active)
        var news = CallNews()
        news.myHand = true
        news.unread = 1
        controls.show(news: news)
        controls.layout()
        #expect(!controls.near)
        #expect(controls.benchState()["hand_badge"] as? Bool == true)
        let frames = controls.benchState()["frames"] as? [String: String] ?? [:]
        #expect(NSRectFromString(frames["hand_mark"] ?? "") == NSRect(x: 42, y: 14, width: 24, height: 24))
        news.unread = 2
        controls.show(news: news)
        #expect(!controls.near)
        // The stage is told where the marks stand, for bubbles to keep clear.
        #expect(asked.contains(.overlay(island: .zero, marks: 44)))
        controls.stopWatching()
    }

    /// The island's spring starts at 0, passes 1 a little, and settles.
    @Test func spring() {
        let spring = CallSpring()
        #expect(spring.at(0) == 0)
        #expect(abs(spring.at(spring.settles) - 1) < 0.002)
        #expect(stride(from: 0.0, to: spring.settles, by: 0.01).contains { spring.at($0) > 1 })
    }

    /// The island: Rec while recorded, a card for someone asking to come
    /// in, the list behind View for several, nothing otherwise.
    @MainActor @Test func island() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 352, height: 198))
        let island = CallIsland()
        host.addSubview(island)
        var news = CallNews()
        island.show(news, narrow: false)
        #expect(island.shape == .none && island.isHidden)
        news.recording = true
        island.show(news, narrow: false)
        #expect(island.shape == .rec)
        news.waiting = [.init(name: "Alex Morgan", face: nil)]
        island.show(news, narrow: false)
        #expect(island.shape == .card)
        #expect(island.benchState["buttons"] as? [String] == ["Deny", "Admit"])
        #expect(island.size(in: 352) == NSSize(width: 250, height: 84))
        #expect(island.benchState["radius"] as? CGFloat == Floater.corner) // the window's corner, 18 since bb1c8dd4
        var asked: [CallAsk] = []
        island.onAsk = { asked.append($0) }
        island.press("admit")
        #expect(asked == [.admit("Alex Morgan")])
        news.waiting += [.init(name: "Jo Lee", face: nil), .init(name: "Dana Scott", face: nil)]
        island.show(news, narrow: false)
        #expect(island.benchState["buttons"] as? [String] == ["View", "Admit All"])
        island.press("view")
        #expect(island.shape == .list)
        #expect(island.benchState["rows"] as? [String] == ["Alex Morgan", "Jo Lee", "Dana Scott"])
        #expect(island.benchState["buttons"] as? [String] == ["Deny All", "Admit All"])
        #expect(island.size(in: 352) == NSSize(width: 250, height: 132))
        island.press("admit")
        #expect(asked.last == .admit(nil))
        island.press("deny-all")
        #expect(asked.last == .deny(nil))
        // Four rows at most, and only as many as stop clear of the row.
        news.waiting.append(.init(name: "Sam Wu", face: nil))
        island.room = 200
        island.show(news, narrow: false)
        #expect(island.shape == .card)
        island.press("view")
        #expect((island.benchState["rows"] as? [String])?.count == 4)
        island.room = 132
        // A narrow window's card has only Admit; Deny is in its right-click.
        news.waiting = [.init(name: "Alex Morgan", face: nil)]
        island.show(news, narrow: true)
        island.press("admit")
        news.waiting = [.init(name: "Jo Lee", face: nil)]
        island.show(news, narrow: true)
        #expect(island.shape == .card)
        #expect(island.benchState["buttons"] as? [String] == ["Admit"])
        #expect(island.benchState["menu"] as? [String] == ["Admit", "Deny"])
        news.waiting = []
        island.show(news, narrow: true)
        #expect(island.shape == .rec)
        #expect(island.size(in: 352) == NSSize(width: 54, height: 24))
        #expect(island.benchState["radius"] as? CGFloat == 12)
    }

    /// A call's devices as its page's menus list them: the ids kept, the
    /// Mac's own choice named so, a choice only where there are two.
    @Test func devices() {
        let read = CallDevices([
            "mics": [["label": "MacBook Pro Microphone", "id": "a1", "on": true], ["label": "AirPods Pro", "id": "a2", "on": false]],
            "speakers": [["label": "MacBook Pro Speakers", "id": "default", "on": true], ["label": "AirPods Pro", "id": "o2"]],
            "cameras": [["label": "FaceTime HD Camera", "id": "c1", "on": true]],
            "sharable": true,
        ] as [String: Any])
        #expect(read.mics.map(\.label) == ["MacBook Pro Microphone", "AirPods Pro"])
        #expect(read.mics.first?.on == true)
        #expect(read.speakers.first?.title == "System Default (MacBook Pro Speakers)")
        #expect(read.speakers.last?.id == "o2")
        #expect(read.choice.mic && !read.choice.camera)
        #expect(read.sharable)
        #expect(CallDevices(nil).mics.isEmpty)
    }

    /// Two speakers are a choice with one microphone (#257): the arrow and
    /// the Speaker list come; the Mac's own choice beside the very device
    /// it is now is none.
    @Test func speakersAlone() {
        let one = ["label": "MacBook Pro Microphone", "id": "a1", "on": true] as [String: Any]
        let two = CallDevices([
            "mics": [one],
            "speakers": [["label": "MacBook Pro Speakers", "id": "default", "on": true],
                         ["label": "MacBook Pro Speakers", "id": "o1"], ["label": "Studio Display Speakers", "id": "o2"]],
        ] as [String: Any])
        #expect(two.choice.mic && !two.choice.camera)
        let same = CallDevices([
            "mics": [one],
            "speakers": [["label": "MacBook Pro Speakers", "id": "default", "on": true], ["label": "MacBook Pro Speakers", "id": "o1"]],
        ] as [String: Any])
        #expect(!same.choice.mic)
        #expect(same.speakers.first?.title == "System Default (MacBook Pro Speakers)")
    }

    /// WebKit's speaker flags for every tab's page (#257): speakers listed,
    /// setSinkId there, and no gesture asked for each element.
    @MainActor @Test func speakerFlags() {
        let preferences = WKPreferences()
        Web.speakers(preferences)
        for (key, want) in Web.speakerFlags {
            // A WebKit without the flag leaves nothing to set.
            if let on = WebFeature.isOn(key, in: preferences) { #expect(on == want, "\(key)") }
        }
    }

    /// The Mac's name for a device and the page's are one device.
    @Test func deviceNames() {
        #expect(CallDevices.plain("Default - MacBook Pro Microphone (Built-in)") == "MacBook Pro Microphone")
        #expect(CallDevices.same("AirPods Pro (Bluetooth)", "AirPods Pro"))
        #expect(!CallDevices.same("AirPods Pro", "Studio Display Microphone"))
        #expect(!CallDevices.same("", "AirPods Pro"))
    }

    /// A call's window takes any shape within its limits: the shorter side
    /// 146 at least, no wider than 3:1, no taller than 1:2.2, the corner held
    /// where it was, and on the screen.
    @MainActor @Test func anyShape() {
        let area = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let corner = NSPoint(x: 1600, y: 1000)
        let tall = FloatHand.freely(NSSize(width: 200, height: 420), around: corner, in: area)
        #expect(tall.size == NSSize(width: 200, height: 420) && tall.maxX == 1600 && tall.maxY == 1000)
        let thin = FloatHand.freely(NSSize(width: 100, height: 600), around: corner, in: area)
        #expect(thin.width >= 146 && thin.width / thin.height >= 1 / 2.2 - 0.001)
        let strip = FloatHand.freely(NSSize(width: 900, height: 100), around: corner, in: area)
        #expect(strip.height >= 146 && strip.width / strip.height <= 3.001)
        let low = FloatHand.freely(NSSize(width: 300, height: 300), around: NSPoint(x: 10, y: 10), in: area)
        #expect(low.minX == 10 && low.minY == 10)
    }
}
