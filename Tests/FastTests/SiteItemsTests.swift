import Foundation
import Testing
@testable import Fast

struct SiteItemsTests {
    private let slack = """
    ---
    name: slack
    description: Slack.
    sites: [app.slack.com]
    action: Catch me up | /client/*/* | Read the channel.
    item: Message | in: [data-qa="message_container"], [data-qa="virtual-list-item"] | anchor: [data-qa="message-actions"] button | style: class | name: [data-qa="message_sender_name"] | button: Do It
    action: Do What It Asks | @Message | draft: Reply drafted / Send | Do what it asks.
    action: Draft a reply | @Message | Reply to it.
    item: Orphan | anchor: button | button: Nothing
    item: NoButton | anchor: button
    ---
    # Slack
    """

    private func parsed() throws -> Skills.Skill {
        try #require(Skills.parse(slack, own: false, path: URL(fileURLWithPath: "/tmp/slack/SKILL.md")))
    }

    @Test func aPromptChangedInSettingsStandsInTheSkillsPlaceUntilReset() throws {
        let action = try #require(Skills.named("slack")?.actions.first { $0.pattern == "@Message" })
        defer { SkillPrompts.set("", for: action) }
        SkillPrompts.set("  Say thanks.  ", for: action)
        let changed = try #require(Skills.named("slack")?.actions.first { $0.title == action.title && $0.pattern == "@Message" })
        #expect(changed.prompt == "Say thanks.")
        #expect(changed.written == action.prompt)
        // The skill's own words again are no change at all.
        SkillPrompts.set(action.prompt, for: changed)
        let back = try #require(Skills.named("slack")?.actions.first { $0.title == action.title && $0.pattern == "@Message" })
        #expect(back.prompt == action.prompt)
        #expect(back.written == nil)
        #expect(SkillPrompts.all[SkillPrompts.key(action)] == nil)
    }

    @Test func anItemLineIsReadWithItsFields() throws {
        let skill = try parsed()
        // The one with no button is no item; the one with no actions is, but has none.
        #expect(skill.items.map(\.kind) == ["Message", "Orphan"])
        let message = skill.items[0]
        #expect(message.container == "[data-qa=\"message_container\"], [data-qa=\"virtual-list-item\"]")
        #expect(message.anchor == "[data-qa=\"message-actions\"] button")
        #expect(message.style == "class")
        #expect(message.place == "after")
        #expect(message.min == 1)
        #expect(message.button == "Do It")
        #expect(message.tag == "@Message")
    }

    @Test func itemActionsAreNotThePagesAndKeepTheirDraft() throws {
        let skill = try parsed()
        let url = try #require(URL(string: "https://app.slack.com/client/T1/C1"))
        let page = skill.actions.filter { $0.fits(url) }.map(\.title)
        #expect(page == ["Catch me up"])
        let about = skill.actions.filter { $0.pattern == "@Message" }
        #expect(about.map(\.title) == ["Do What It Asks", "Draft a reply"])
        #expect(about[0].draft?.verb == "Send")
    }

    @Test func aPageItemNeedsItsRowOfSeveral() {
        let item = Skills.Item(#"Thread | in: page | anchor: span[role="link"] | min: 2 | style: copy | button: Do It"#)
        #expect(item?.container == "page")
        #expect(item?.min == 2)
        #expect(Skills.Item("Thread | in: page") == nil)
        #expect(Skills.Item("in: page | anchor: a | button: B") == nil)
    }

    @Test func aRowOfIconsGetsTheSitesOwnButtonAgain() {
        let x = Skills.Item(#"Post | in: [role="dialog"] | anchor: [data-testid="toolBar"] div | style: clone | hover: 10% | if: [data-testid="tweetButton"] ~ ^Reply$ | icon: 18 / 1.35 | button: Reply"#)
        #expect(x?.style == "clone")
        #expect(x?.hover == "10%")
        #expect(x?.gate == #"[data-testid="tweetButton"] ~ ^Reply$"#)
        #expect(x?.icon == 18)
        #expect(x?.stroke == 1.35)
        // A size alone leaves the line to the size; an unknown style is a copy.
        let sized = Skills.Item("Issue | anchor: button | icon: 14 | style: paint | button: Plan")
        #expect(sized?.icon == 14)
        #expect(sized?.stroke == 0)
        #expect(sized?.style == "copy")
    }

    @Test func theFaceSaysWhereTheTaskIs() {
        #expect(SiteItems.face(.running, asking: false) == "work")
        #expect(SiteItems.face(.starting, asking: false) == "work")
        #expect(SiteItems.face(.running, asking: true) == "hand")
        #expect(SiteItems.face(.done, asking: false) == "done")
        #expect(SiteItems.face(.failed, asking: false) == "")
        #expect(SiteItems.face(.stopped, asking: true) == "")
    }

    @Test func theItemsChipAndSentence() {
        let item = SiteItem(["kind": "Message", "key": "Message https://x/1", "name": "Mark Chen", "when": "10:42",
                             "link": "https://acme.slack.com/archives/C1/p1", "text": "Can you send the deck?"])
        #expect(item?.chip == "Message · Mark Chen")
        #expect(item?.sentence.contains("from Mark Chen at 10:42") == true)
        #expect(item?.sentence.contains("not the user's words") == true)
        #expect(SiteItem(["kind": "Message"]) == nil)
        let untitled = SiteItem(["kind": "Thread", "key": "k"])
        #expect(untitled?.chip == "Thread")
    }

    @MainActor @Test func neverQuietAndBack() throws {
        let store = try #require(UserDefaults(suiteName: "SiteItemsTests-\(UUID().uuidString)"))
        let items = SiteItems(store: store)
        #expect(items.state("slack") == .on)
        // Fourteen days shown, never pressed: quiet. One day twice counts once.
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for day in 0..<13 { items.seen("slack", on: start.addingTimeInterval(Double(day) * 86_400)) }
        items.seen("slack", on: start)
        #expect(items.state("slack") == .on)
        items.seen("slack", on: start.addingTimeInterval(13 * 86_400))
        #expect(items.state("slack") == .quiet)
        // On again from Settings starts the count over.
        items.set("slack", on: true)
        #expect(items.state("slack") == .on)
        // A press does too.
        for day in 0..<13 { items.seen("slack", on: start.addingTimeInterval(Double(day) * 86_400)) }
        items.pressed("slack")
        items.seen("slack", on: start)
        #expect(items.state("slack") == .on)
        // Never, kept across a relaunch, and everywhere off over it.
        items.set("slack", on: false)
        guard case .never = SiteItems(store: store).state("slack") else { Issue.record("never not kept"); return }
        items.everywhere(false, from: nil)
        #expect(SiteItems(store: store).state("gmail") == .everywhereOff)
        items.everywhere(true, from: nil)
        #expect(items.state("gmail") == .on)
    }

    @MainActor @Test func threeSkipsInAWeekQuietTheFootNotTheButtons() throws {
        let store = try #require(UserDefaults(suiteName: "SiteItemsTests-\(UUID().uuidString)"))
        let items = SiteItems(store: store)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        items.skipped("x-twitter", on: now.addingTimeInterval(-8 * 86_400))
        items.skipped("x-twitter", on: now.addingTimeInterval(-2 * 86_400))
        items.skipped("x-twitter", on: now.addingTimeInterval(-86_400))
        #expect(!items.footQuiet("x-twitter", now: now))
        items.skipped("x-twitter", on: now)
        #expect(items.footQuiet("x-twitter", now: now))
        #expect(items.state("x-twitter") == .on)
        #expect(!items.footQuiet("x-twitter", now: now.addingTimeInterval(8 * 86_400)))
        items.set("x-twitter", on: true)
        #expect(!items.footQuiet("x-twitter", now: now))
    }

    @MainActor @Test func whatAnOlderYabKeptStillReads() throws {
        let store = try #require(UserDefaults(suiteName: "SiteItemsTests-\(UUID().uuidString)"))
        store.set(Data(#"{"off":false,"never":{},"hidden":{"slack":["k"]},"days":{}}"#.utf8), forKey: SiteItems.key)
        let items = SiteItems(store: store)
        #expect(items.kept.hidden["slack"] == ["k"])
        #expect(items.kept.skips.isEmpty)
    }

    @Test func aMineLineIsRead() {
        let item = Skills.Item(#"Post | in: article | anchor: div | mine: path:/notifications/mentions* | button: Reply"#)
        #expect(item?.mine == "path:/notifications/mentions*")
    }

    @Test func theShippedSkillsHaveButtons() throws {
        for name in ["slack", "gmail", "github", "linear", "google-calendar", "amazon", "x-twitter"] {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Skills/\(name)/SKILL.md")
            let skill = try #require(Skills.parse(try String(contentsOf: url, encoding: .utf8), own: false, path: url))
            let item = try #require(skill.items.first)
            #expect(skill.actions.contains { $0.pattern == item.tag }, "\(name) has an item with no action")
        }
    }

    @Test func aButtonsWords() {
        #expect(SiteItems.label("Do It", agent: "Claude") == "Do It with Claude")
        #expect(SiteItems.label("Ask {agent} about this", agent: "ChatGPT") == "Ask ChatGPT about this")
        // On the button the verb alone; the agent is in its tooltip.
        #expect(SiteItems.words("Do It") == "Do It")
        #expect(SiteItems.words("Ask {agent} about this") == "Ask about this")
        let item = Skills.Item(#"Pull request | in: page | anchor: button | like: section button[data-variant="default"] | button: Review"#)
        #expect(item?.like == #"section button[data-variant="default"]"#)
        #expect(item?.tag == "@Pull request")
    }

    @Test func theScriptHasItsPlaceholders() throws {
        let source = PageScript.load("site-items")
        #expect(source.contains("__YAB_SPECS__"))
        #expect(source.contains("__YAB_HIDDEN__"))
        #expect(source.contains("yabItems"))
        #expect(ItemRelay.name == "yabItems")
    }
}
