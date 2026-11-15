import Foundation
import Testing
@testable import Fast

// What a tab's card says (TabGist.swift): the one line of now, the order
// it is chosen in, and the button that goes with it.
struct TabGistTests {
    static let pull = URL(string: "https://github.com/acme/yab/pull/412/commits")!
    static let pullTitle = "Keep the space by mira · Pull Request #412 · acme/yab · GitHub"

    @Test func plainPageSaysNothing() {
        let gist = TabGist.make(.init(address: URL(string: "https://webkit.org/blog")!, label: "Blog"))
        #expect(gist == TabGist())
    }

    @Test func pullRequestFacts() {
        let gist = TabGist.make(.init(address: Self.pull, label: Self.pullTitle))
        #expect(gist.title == "Keep the space")
        #expect(gist.person == "mira")
        #expect(gist.facts == "mira · #412")
        #expect(gist.now == nil)
        #expect(gist.action == nil)
    }

    /// A pinned calendar with nothing connected says so, with Connect; a
    /// draft typed on it still comes first.
    @Test func calendarWithNothingConnectedOffersConnect() {
        var s = TabGist.Signals(address: URL(string: "https://calendar.notion.so/")!, label: "Notion Calendar")
        s.noCalendar = true
        let gist = TabGist.make(s)
        #expect(gist.now == .init(word: nil, text: "No calendar connected", tone: .you))
        #expect(gist.action == .init(label: "Connect", kind: .connectCalendar))
        s.draft = true
        #expect(TabGist.make(s).now?.word == "Not sent")
    }

    @Test func failingGoesToChecks() {
        var s = TabGist.Signals(address: Self.pull, label: Self.pullTitle)
        s.words = .failing
        let gist = TabGist.make(s)
        #expect(gist.now?.word == "Failing")
        #expect(gist.action == .init(label: "Checks", kind: .open(URL(string: "https://github.com/acme/yab/pull/412/checks")!)))
    }

    @Test func reviewGoesToFiles() {
        var s = TabGist.Signals(address: Self.pull, label: Self.pullTitle)
        s.words = .review
        #expect(TabGist.make(s).action?.label == "Files")
        #expect(TabGist.make(s).action?.kind == .open(URL(string: "https://github.com/acme/yab/pull/412/files")!))
    }

    @Test func whatCouldBeLostComesFirst() {
        var s = TabGist.Signals(address: Self.pull, label: Self.pullTitle)
        s.words = .failing
        s.playing = true
        s.draft = true
        #expect(TabGist.make(s).now?.word == "Not sent")
        #expect(TabGist.make(s).action == nil)
        s.draft = false
        s.microphone = true
        #expect(TabGist.make(s).now == .init(word: "On a call", text: "mic on", tone: .you))
        s.microphone = false
        s.deaf = s.now.addingTimeInterval(-40)
        #expect(TabGist.make(s).now?.text == "40s")
        #expect(TabGist.make(s).action?.kind == .reload)
    }

    @Test func waitingBeatsPlaying() {
        var s = TabGist.Signals(address: Self.pull, label: Self.pullTitle)
        s.playing = true
        s.words = .review
        #expect(TabGist.make(s).now?.word == "Review")
        s.words = .ready
        // Ready only goes on: what is playing says more.
        #expect(TabGist.make(s).now?.text.hasPrefix("Playing") == true)
    }

    @Test func playing() {
        var s = TabGist.Signals(address: URL(string: "https://www.youtube.com/watch?v=abc")!, label: "Talk")
        s.playing = true
        s.position = 24 * 60 + 10
        s.duration = 41 * 60 + 2
        #expect(TabGist.make(s).now?.text == "Playing · 16m left")
        #expect(TabGist.make(s).action == .init(label: "Pause", kind: .pause))
        s.playing = false
        #expect(TabGist.make(s).action == .init(label: "Play", kind: .play))
        s.streaming = true
        #expect(TabGist.make(s).now?.text == "Paused")
    }

    @Test func heavyOffersSleep() {
        var s = TabGist.Signals(address: URL(string: "https://figma.com/x")!, label: "Board")
        s.weight = 2_469_606_195
        s.canSleep = true
        #expect(TabGist.make(s).now?.text == "Uses 2.3 GB")
        #expect(TabGist.make(s).action?.kind == .sleep)
        s.weight = 900 << 20
        #expect(TabGist.make(s).now == nil)
    }

    @Test func linearMentionAndComment() {
        var s = TabGist.Signals(address: URL(string: "https://linear.app/yab/issue/YAB-231/pointer")!, label: "YAB-231 Pointer")
        s.item = LiveItem(key: "linear/YAB-231", url: s.address!, title: "YAB-231 Pointer", group: "YAB", words: .mention,
                          updated: nil, list: "mentions", quote: "which one ships?", person: "mira")
        s.words = .mention
        var gist = TabGist.make(s)
        #expect(gist.facts == "mira · YAB-231 · YAB")
        #expect(gist.person == "mira")
        #expect(gist.now == .init(word: "Mention", text: "“which one ships?”", tone: .you))
        // No button: a click on the tab already opens the issue.
        #expect(gist.action == nil)
        s.item?.words = .comment
        s.item?.quote = "works on 26.1"
        s.words = .comment
        gist = TabGist.make(s)
        #expect(gist.now == .init(word: "Comment", text: "“works on 26.1”", tone: .you))
        #expect(gist.action == nil)
        // A mention in the description has no quote.
        s.item?.quote = nil
        s.words = .mention
        #expect(TabGist.make(s).now == .init(word: "Mention", text: "you’re named here", tone: .you))
    }

    /// An issue both lists name: the mention's tab keeps its quote, a
    /// to-do tab its due date.
    @MainActor @Test func linearSeenByList() {
        let url = URL(string: "https://linear.app/yab/issue/YAB-77/x")!
        LiveSeen.note([LiveItem(key: "linear/YAB-77", url: url, title: "YAB-77", group: "YAB", words: .mention, updated: nil,
                                list: "mentions", quote: "look", person: "mira"),
                       LiveItem(key: "linear/YAB-77", url: url, title: "YAB-77", group: "YAB", words: .late, updated: nil,
                                due: Date(), list: "assigned")], news: ["mentions"])
        #expect(LiveSeen.item("linear/YAB-77", news: true)?.quote == "look")
        #expect(LiveSeen.item("linear/YAB-77")?.due != nil)
        #expect(LiveSeen.item("linear/YAB-77")?.quote == nil)
    }

    @Test func linearLate() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        var s = TabGist.Signals(address: URL(string: "https://linear.app/yab/issue/YAB-212/search")!, label: "YAB-212 Search")
        s.item = LiveItem(key: "linear/YAB-212", url: s.address!, title: "YAB-212 Search", group: "YAB", words: .late,
                          updated: nil, due: now.addingTimeInterval(-2 * 86_400 - 60))
        s.words = .late
        s.now = now
        let gist = TabGist.make(s)
        #expect(gist.facts?.hasPrefix("YAB-212 · YAB · due ") == true)
        #expect(gist.now == .init(word: "Late", text: "by 2 days", tone: .wrong))
    }

    @Test func thingKeys() {
        #expect(LiveText.thing(URL(string: "https://linear.app/yab/issue/yab-212/search-like-arc")) == "linear/YAB-212")
        #expect(LiveText.thing(URL(string: "https://www.notion.so/acme/Launch-plan-1a2b3c4d5e6f47a8b9c0d1e2f3a4b5c6")) == "notion/1a2b3c4d-5e6f-47a8-b9c0-d1e2f3a4b5c6")
        #expect(LiveText.thing(URL(string: "https://docs.google.com/spreadsheets/d/AbC123/edit#gid=0")) == "drive/AbC123")
        #expect(LiveText.thing(URL(string: "https://www.figma.com/design/KEY42/Yab-iPhone?node-id=1")) == "figma/KEY42")
        #expect(LiveText.thing(URL(string: "https://www.youtube.com/watch?v=dQw&t=4")) == "youtube/dQw")
        #expect(LiveText.thing(URL(string: "https://github.com/acme/yab/pull/9/files")) == "github.com/acme/yab/pull/9")
        #expect(LiveText.thing(URL(string: "https://example.com/a")) == nil)
    }

    @Test func clock() {
        #expect(TabGist.clock(45) == "45s")
        #expect(TabGist.clock(17 * 60) == "17m")
        #expect(TabGist.clock(64 * 60) == "1h 4m")
        #expect(TabGist.span(130) == "2m")
    }

    // MARK: - a chat at work (ChatBusy)

    static let chat = URL(string: "https://claude.ai/chat/1b2c")!

    @Test func chatAnsweringIsMutedWithNoButton() {
        var s = TabGist.Signals(address: Self.chat, label: "Plan the Show HN launch")
        s.busy = s.now.addingTimeInterval(-75)
        s.busyWord = "Answering"
        #expect(TabGist.make(s).now == .init(word: nil, text: "Answering · 1m", tone: .going))
        #expect(TabGist.make(s).action == nil)
        s.busyWord = "Researching"
        s.busy = s.now.addingTimeInterval(-12 * 60)
        #expect(TabGist.make(s).now?.text == "Researching · 12m")
        s.busyWord = "Building"
        s.busy = s.now.addingTimeInterval(-40)
        #expect(TabGist.make(s).now?.text == "Building · 40s")
    }

    @Test func chatAnswerReadyIsInk() {
        var s = TabGist.Signals(address: Self.chat, label: "Plan the Show HN launch")
        s.done = s.now.addingTimeInterval(-130)
        s.doneWord = "Answer ready"
        #expect(TabGist.make(s).now == .init(word: "Answer ready", text: "2m ago", tone: .you))
        #expect(TabGist.make(s).action == nil)
        s.doneWord = "Done"
        s.done = s.now.addingTimeInterval(-70)
        #expect(TabGist.make(s).now == .init(word: "Done", text: "1m ago", tone: .you))
    }

    @Test func chatComesAfterNotRespondingBeforePlaying() {
        var s = TabGist.Signals(address: Self.chat, label: "Plan the Show HN launch")
        s.busy = s.now.addingTimeInterval(-60)
        s.busyWord = "Answering"
        s.playing = true
        #expect(TabGist.make(s).now?.text == "Answering · 1m")
        s.deaf = s.now.addingTimeInterval(-40)
        #expect(TabGist.make(s).now?.word == "Not responding")
        s.deaf = nil
        s.draft = true
        #expect(TabGist.make(s).now?.word == "Not sent")
    }

    @Test func chatOpenedSaysNothing() {
        // Read: the tab's done goes (Tab.chatDone nil), and the card is as before.
        let s = TabGist.Signals(address: Self.chat, label: "Plan the Show HN launch")
        #expect(TabGist.make(s).now == nil)
    }

    @MainActor @Test func chatSitesOnlyThoseSites() {
        for host in ["claude.ai", "chatgpt.com", "perplexity.ai", "v0.dev", "v0.app", "lovable.dev", "bolt.new"] {
            #expect(ChatBusy.site(host) != nil, "\(host)")
        }
        #expect(ChatBusy.site("example.com") == nil)
        #expect(ChatBusy.site("v0.dev")?.word == "Building")
        #expect(ChatBusy.site("chatgpt.com")?.longerWord == "Researching")
    }
}
