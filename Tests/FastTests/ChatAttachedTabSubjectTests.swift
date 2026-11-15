import AppKit
import Foundation
import Testing
@testable import Fast

/// A tab attached to a chat message is what the message is about (reported
/// 2026-11-14: a Figma members page attached with "give them Full Access",
/// and the agent went to the Notion page its chat had begun on, then asked
/// where to do it). Loopback addresses only; no CLI is launched.
@MainActor
@Suite(.serialized)
struct ChatAttachedTabSubjectTests {
    @MainActor private final class World {
        let browser = Browser(windowID: UUID())
        let agents = Agents()
        let members = Tab()
        let notion = Tab()
        let previousFeed = AgentFeed.shared.browser
        let previousFolders = Folders.shared.browser

        init() {
            _ = NSApplication.shared
            members.restore(url: URL(string: "http://127.0.0.1:9/files/team/members")!, title: "Members – Northwind, Inc. Admin")
            notion.restore(url: URL(string: "http://127.0.0.1:9/notion/refunds")!, title: "New refund policy")
            browser.lay([notion, members])
            // The Notion page is in front, as the chat's first page was.
            browser.activeID = notion.id
            agents.browser = browser
        }

        func dispose() {
            agents.browser = nil
            AgentFeed.shared.browser = previousFeed
            Folders.shared.browser = previousFolders
            for tab in browser.everyTab { tab.close() }
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
    }

    @Test func aFollowUpWithATabMakesThatTabTheTarget() {
        let world = World()
        defer { world.dispose() }
        // A chat already going, begun on the Notion page.
        let session = world.agents.attach(name: "Subject fixture")
        session.nativeOriginTab = world.notion.id
        world.agents.followUp(session.id, "sam@mail.example\nPlease give them Full Access.",
                              with: [.tab(world.members.id)])
        #expect(session.nativeOriginTab == world.members.id,
                "native_context's taskTargets must name the attached tab, not the page the chat began on")
        #expect(world.members.allowed.contains(session.id),
                "the attached tab is the agent's to work in without a separate yes, as a new chat's is")
        #expect(!world.notion.allowed.contains(session.id))
        _ = world.agents.stop(session.id)
    }

    @Test func theAttachedTabIsSaidToBeTheSubject() {
        let world = World()
        defer { world.dispose() }
        let said = ChatAttachment.said(tabs: [world.members], files: [], in: world.browser)
        #expect(said.contains("The user points you at their tab \(Bench.short(world.members))"))
        #expect(said.contains("This message is about that tab (\(Bench.short(world.members)))"))
        #expect(said.contains("don't look for another page"))
        // The boosts page still shows only the person's own words.
        #expect(BoostWords.request(said + "Hide the banner") == "Hide the banner")
    }

    @Test func aTaskFollowUpWithATabIsNotSentBackToItsOldTabs() {
        let given = "The user points you at their tab abcd1234 (http://127.0.0.1:9/m), \"Members\". "
            + ChatAttachment.subject([])
        let prompt = Agents.aboutTabsPrompt("Please give them Full Access.", given: given, bypass: false)
        #expect(prompt.contains("«Please give them Full Access.»"), "the quote holds only their words")
        #expect(!prompt.contains("«The user points you"), "what went with the words stays out of their quote")
        #expect(prompt.contains("Work in the tab they attached"))
        #expect(!prompt.contains("tabs you already have open"),
                "the refine brief sent a chat's new request back to the tabs of its earlier work")
        #expect(prompt.contains(Agents.askFirstLine))
    }

    @Test func aNewChatAboutAnotherTabTargetsIt() {
        let world = World()
        defer { world.dispose() }
        let line = Agents.given([.tab(world.members)], browser: world.browser)
        #expect(line.contains("what they ask is about it"))
        #expect(!line.contains("to read ("), "a tab given only \"to read\" read as material, not the target")
    }
}
