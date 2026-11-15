import XCTest
import UIKit
@testable import YabPhone

/// Answers and chats: who answers, what new chats are called, where the one
/// sheet stands in every pose, and what the flow does to the chats. Archive
/// keeps a chat; only Delete Chat removes one.
@MainActor
final class ChatsTests: XCTestCase {
    private func app(_ world: String = "mira") throws -> AppModel {
        let app = AppModel(world: try World.load(named: world))
        app.chatSheet.answerers.mac.thinking = .milliseconds(1)
        return app
    }

    // MARK: - who began a chat

    func testTheChatsPageKeepsYourChatsAndFoldsTasksAndOneRowPerRoutine() {
        let yours = Chat(id: "a:yours", title: "GitHub org setup")
        let agent = Chat(id: "a:agent", title: "The user said yes", origin: "agent")
        let cli = Chat(id: "a:cli", title: "Open appstoreconnect", origin: "cli")
        let pinnedTask = Chat(id: "a:pinned", title: "Kept", pinned: true, origin: "agent")
        let rentToday = Chat(id: "a:rent-2", title: "Central rent", origin: "routine", routine: "13lyf")
        let rentYesterday = Chat(id: "a:rent-1", title: "Central rent", origin: "routine", routine: "13lyf")
        let groups = ChatGroup.split([yours, agent, rentToday, cli, pinnedTask, rentYesterday])
        XCTAssertEqual(groups.map(\.0), [.yours, .tasks, .routines])
        XCTAssertEqual(groups[0].1.map(\.id), ["a:yours", "a:pinned"], "a pinned task stays where it was kept")
        XCTAssertEqual(groups[1].1.map(\.id), ["a:agent", "a:cli"])
        XCTAssertEqual(groups[2].1.map(\.id), ["a:rent-2"], "a routine's latest run only")
        // Only your chats: no empty headings.
        XCTAssertEqual(ChatGroup.split([yours]).map(\.0), [.yours])
    }

    func testArchiveBelowSkipsPinnedAndWorkingChats() {
        var working = Chat(id: "a:working", title: "Working")
        working.messages = [Message(role: .typing, text: "")]
        let list = [Chat(id: "a:top", title: "Top"), Chat(id: "a:kept", title: "Kept", pinned: true), working, Chat(id: "a:old", title: "Old")]
        XCTAssertEqual(AppModel.archivableBelow("a:top", in: list).map(\.id), ["a:old"])
        XCTAssertEqual(AppModel.archivableBelow("a:old", in: list).map(\.id), [])
    }

    // MARK: - the stand-ins

    func testNewChatsAreNamedFromTheirFirstWords() {
        XCTAssertEqual(StandIns.name(for: "what does anna want?"), "Anna\u{2019}s hours picker")
        XCTAssertEqual(StandIns.name(for: "plan a calm saturday in stockholm"), "Saturday in Stockholm")
        XCTAssertEqual(StandIns.name(for: "Summarize this page"), "Onboarding v3, summed up")
        XCTAssertEqual(StandIns.name(for: "is it raining?"), "Is it raining")
        XCTAssertEqual(StandIns.name(for: "how long does a sourdough starter keep in the fridge"), "How long does a sourdough\u{2026}")
    }

    func testTheStandInsAnswerAsThePrototypeDoes() {
        XCTAssertTrue(StandIns.answer("what does anna want?").hasPrefix("Anna wants a \u{201C}same as last week\u{201D} button"))
        XCTAssertTrue(StandIns.answer("and the sprint?").hasPrefix("On Thursday in Slack"))
        XCTAssertEqual(StandIns.reply(to: "what does anna want?")?.aboutPage, true)
        XCTAssertEqual(StandIns.reply(to: "sprint")?.aboutPage, false)
        XCTAssertTrue(StandIns.answer("hello").hasPrefix("A stand-in answer to \u{201C}hello\u{201D}."))
        XCTAssertEqual(StandIns.ideas(forPage: "figma"), ["Summarize this page", "What does Anna want?", "Draft replies to Anna"])
        XCTAssertNil(StandIns.ideas(forPage: "hn"))
    }

    /// The Chats page's rows (and Your Chats') read an answer's words, not
    /// its markdown: no #, ** or ` and the blocks on one line.
    func testARowPreviewsAnAnswersWordsWithoutItsMarkdown() throws {
        let app = try app()
        let text = "# Lisbon in March\n\n**Mild** days, `18°` at noon.\n\n- Pack a [light jacket](https://example.com/jacket)\n\n```\nrain: 9 days\n```"
        let chat = Chat(id: "markdown", title: "Lisbon", messages: [Message(role: .you, text: "weather?"),
                                                                       Message(role: .answer, text: text, by: .claude)])
        let expected = "Lisbon in March Mild days, 18° at noon. Pack a light jacket rain: 9 days"
        XCTAssertEqual(ChatWords.preview(chat, app: app), expected)
        XCTAssertEqual(ChatWords.status(chat, app: app).text, expected)
        let legacy = Chat(id: "legacy", title: "Old", messages: [Message(role: .answer, text: "<b>Bold</b> words", by: .claude)])
        XCTAssertEqual(ChatWords.preview(legacy, app: app), "Bold words")
    }

    func testIdeasAreThreePlainLines() {
        XCTAssertEqual(Ideas.lines("1. Summarize the thread.\n2. \u{201C}Find more like this\u{201D}\n- Draft a reply"),
                       ["Summarize the thread", "Find more like this", "Draft a reply"])
        XCTAssertNil(Ideas.lines("# Ideas:\nOnly one"))
        XCTAssertEqual(Ideas.plain("Top 10 lists."), "Top 10 lists")
    }

    // MARK: - who answers

    func testAPageQuestionIsAnsweredOnThisIPhoneUntilClaudeJoins() {
        let answerers = Answerers(device: StandInDevice(), mac: ClaudeOnMac())
        var chat = Chat(id: "x", title: "x", messages: [Message(role: .you, text: "what does anna want?")])
        XCTAssertEqual(answerers.who(for: "what does anna want?", in: chat, aboutPage: true), .iphone)
        XCTAssertEqual(answerers.who(for: "what does anna want?", in: chat, aboutPage: false), .claude)
        // A stand-in reply that isn't about the page goes to Claude.
        XCTAssertEqual(answerers.who(for: "and the sprint?", in: chat, aboutPage: true), .claude)
        // Once Claude has answered, Claude carries on.
        chat.messages.append(Message(role: .answer, text: "…", by: .claude))
        XCTAssertEqual(answerers.who(for: "summarize it", in: chat, aboutPage: true), .claude)
    }

    func testWithoutAppleIntelligenceThePageQuestionGoesToTheMac() {
        let answerers = Answerers(device: NoDeviceModel(), mac: ClaudeOnMac())
        let chat = Chat(id: "x", title: "x")
        XCTAssertEqual(answerers.who(for: "what does anna want?", in: chat, aboutPage: true), .claude)
    }

    func testClaudeOnTheMacAnswersAfterThinkingAndLandsOnRequest() async throws {
        let mac = ClaudeOnMac(usesStandIn: true)
        mac.paused = true
        let answer = Task { try await mac.answer(AskContext(question: "plan a calm saturday", page: nil, history: [])) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(mac.isThinking)
        mac.landNow()
        let text = try await answer.value
        XCTAssertTrue(text.hasPrefix("Coffee at Kaffe S\u{F6}der at 9"))
    }

    func testRealMacBackendCannotManufactureAStandInAnswer() async {
        let mac = ClaudeOnMac()
        do {
            _ = try await mac.answer(AskContext(question: "plan a calm saturday", page: nil, history: []))
            XCTFail("real launches must answer through sync")
        } catch {
            XCTAssertTrue(error is ClaudeOnMac.Failure)
        }
        XCTAssertFalse(mac.isThinking)
    }

    func testRealQuestionWithoutSyncExplainsJoining() async throws {
        let app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false)
        app.ask("plan a calm saturday", page: nil)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        try await Task.sleep(for: .milliseconds(100))
        let chat = try XCTUnwrap(app.chats.chat(id))
        XCTAssertEqual(chat.messages.map(\.role), [.you, .failed])
        XCTAssertEqual(chat.messages.last?.text, "Join your Mac in Settings to ask Claude.")
        XCTAssertFalse(chat.title.contains("Stockholm"), "a real question gets no fixture-specific title")
        XCTAssertFalse(app.chatSheet.answerers.device is StandInDevice)
    }

    func testMacContextPreservesTheActualPageURLAndConversation() {
        let plain = AskContext(question: "hello", page: nil, history: [])
        XCTAssertEqual(plain.macPrompt, "hello")
        let context = AskContext(question: "summarize it", page: PageContext(title: "Live page", address: "http://example.org/a?b=1#c", text: "Actual page text"),
                                 history: [Message(role: .you, text: "Earlier question"), Message(role: .answer, text: "Earlier answer", by: .iphone), Message(role: .note, text: "UI note")])
        XCTAssertTrue(context.macPrompt.contains("http://example.org/a?b=1#c"))
        XCTAssertTrue(context.macPrompt.contains("Actual page text"))
        XCTAssertTrue(context.macPrompt.contains("Earlier question"))
        XCTAssertTrue(context.macPrompt.contains("Earlier answer"))
        XCTAssertFalse(context.macPrompt.contains("UI note"))
        XCTAssertTrue(context.macPrompt.hasPrefix("Question: summarize it"))
    }

    func testRealTasksCannotUseTheVirtualMac() throws {
        let app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false)
        let before = app.tasks.runs
        XCTAssertNil(app.taskDesk.virtualMac)
        XCTAssertTrue(app.taskDesk.signer is UnavailableYesSigner)
        XCTAssertFalse(app.taskDesk.canRun)
        XCTAssertNil(app.taskDesk.send(words: "book a flight to Lisbon"))
        app.taskDesk.send("lisbon", words: "book a flight to Lisbon")
        XCTAssertEqual(app.tasks.runs, before)
        XCTAssertEqual(app.surfaces.toast?.text, "No ready Mac is available for this task")
    }

    // MARK: - the sheet's geometry

    func testTheAnswerStandsAtItsOwnHeightAndTheChatAtFull() {
        let screen = Metrics.screen
        let now = SheetGeometry.nowShape(screen: screen)
        XCTAssertEqual(now.rect, CGRect(x: 12, y: 736, width: 378, height: 52))
        let answer = SheetGeometry(screen: screen, pose: SheetPose(t: 0, h: 343), origin: nil, now: now)
        XCTAssertEqual(answer.rest.rect, CGRect(x: 8, y: 523, width: 386, height: 343))
        XCTAssertEqual(answer.rest.bottom, 38)
        XCTAssertEqual(answer.gutter, 12)
        let chat = SheetGeometry(screen: screen, pose: SheetPose(t: 1, h: 343), origin: nil, now: now)
        XCTAssertEqual(chat.rest.rect, CGRect(x: 0, y: 60, width: 402, height: 814))
        XCTAssertEqual(chat.rest.bottom, 0)
        XCTAssertEqual(chat.gutter, 20)
        XCTAssertEqual(chat.headHeight, 92)
        XCTAssertEqual(chat.recede, 1)
        XCTAssertEqual(chat.scrim, 0.32, accuracy: 0.001)
        // The keyboard carries its foot: 302 high, the sheet ends at 572.
        let typing = SheetGeometry(screen: screen, pose: SheetPose(t: 1, k: 302, h: 343), origin: nil, now: now)
        XCTAssertEqual(typing.rest.rect, CGRect(x: 0, y: 60, width: 402, height: 512))
    }

    func testHiddenTheSheetIsTheNowLineAndItsWordsWentFirst() {
        let now = SheetGeometry.nowShape(screen: Metrics.screen)
        let parked = SheetGeometry(screen: Metrics.screen, pose: SheetPose(t: 1, p: 1, h: 343), origin: nil, now: now)
        XCTAssertEqual(parked.current.rect, now.rect)
        XCTAssertEqual(parked.current.top, 26)
        XCTAssertEqual(parked.words, 0)
        XCTAssertEqual(parked.sheetOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(parked.nowOpacity, 1)
        let half = SheetGeometry(screen: Metrics.screen, pose: SheetPose(t: 1, p: 0.4, h: 343), origin: nil, now: now)
        XCTAssertEqual(half.words, 0.04, accuracy: 0.001)
        XCTAssertEqual(half.nowOpacity, 0)
    }

    func testReduceMotionMorphsNothing() {
        var still = SheetGeometry(screen: Metrics.screen, pose: SheetPose(t: 1, h: 343), origin: nil,
                                  now: SheetGeometry.nowShape(screen: Metrics.screen))
        still.still = true
        still.pose.p = 0.5
        XCTAssertEqual(still.current.rect, still.rest.rect, "Reduce Motion: nothing morphs")
        XCTAssertEqual(still.sheetOpacity, 0.5, accuracy: 0.001)
    }

    func testTheAnswerGrowsOutOfTheField() {
        let field = SheetShape(rect: CGRect(x: 20, y: 512, width: 362, height: 46), top: 23, bottom: 23)
        let start = SheetGeometry(screen: Metrics.screen, pose: SheetPose(t: 0, o: 1, h: 343), origin: field, now: SheetGeometry.nowShape(screen: Metrics.screen))
        XCTAssertEqual(start.current.rect, field.rect)
        XCTAssertEqual(start.words, 0)
        let grown = SheetGeometry(screen: Metrics.screen, pose: SheetPose(t: 0, o: 0.1, h: 343), origin: field, now: SheetGeometry.nowShape(screen: Metrics.screen))
        XCTAssertEqual(grown.words, 1)
    }

    // MARK: - the flow

    func testAskingAboutThePageAnswersOnThisIPhoneAndLettingGoLeavesNothing() throws {
        let app = try app()
        let before = app.chats.chats.count
        app.ask("what does anna want?", page: app.browser.tab)
        let sheet = app.chatSheet
        let id = try XCTUnwrap(sheet.chatID)
        let chat = try XCTUnwrap(app.chats.chat(id))
        XCTAssertEqual(chat.by, .iphone)
        XCTAssertEqual(chat.title, "Anna\u{2019}s hours picker")
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer])
        XCTAssertEqual(chat.messages.last?.by, .iphone)
        XCTAssertEqual(chat.ephemeral, true, "a quick answer isn't in Your Chats")
        XCTAssertFalse(ChatSectioning.sections(app.chats.chats, sheet: sheet).flatMap(\.chats).contains { $0.id == id })
        XCTAssertFalse(app.chats.listed.contains { $0.id == id }, "nor in the store's list, its count or search")
        XCTAssertTrue(app.chats.search("anna").allSatisfy { $0.id != id })
        XCTAssertNotEqual(id, "c1", "ids are unique across launches and devices")
        XCTAssertEqual(app.surfaces.chat, .answer(question: "what does anna want?", aboutPage: true))
        // Hidden, then let go: nothing stays.
        app.chats.parked = .init(chat: id, mode: .answer)
        app.hideSheet()
        XCTAssertEqual(app.nowItem?.kind, .parked)
        XCTAssertEqual(app.nowItem?.title, "Answer")
        let gone = expectation(description: "let go")
        app.letGoParked(direction: 1)
        Task { try? await Task.sleep(for: .milliseconds(500)); gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertNil(app.chats.parked)
        XCTAssertNil(app.chats.chat(id))
        XCTAssertEqual(app.chats.chats.count, before)
    }

    func testAFollowUpGoesToClaudeWhoCarriesOn() async throws {
        let app = try app()
        app.ask("what does anna want?", page: app.browser.tab)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.send("and what did she say about the sprint?")
        XCTAssertEqual(app.chatSheet.mode, .chat, "a follow-up stands the answer up into the chat")
        XCTAssertEqual(app.chats.chat(id)?.ephemeral, false)
        XCTAssertEqual(app.chats.chat(id)?.messages.map(\.role), [.you, .answer, .you, .note, .typing])
        XCTAssertEqual(ChatWords.line(app.chats.chat(id)!, app: app), "Thinking")
        try await Task.sleep(for: .milliseconds(200))
        let chat = try XCTUnwrap(app.chats.chat(id))
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer, .you, .note, .answer])
        XCTAssertEqual(chat.messages.last?.by, .claude)
        XCTAssertEqual(chat.messages[3].text, "Claude carries on, on your Mac")
        XCTAssertEqual(ChatWords.line(chat, app: app), "Claude Opus \u{00B7} on your Mac")
        XCTAssertTrue(ChatSectioning.sections(app.chats.chats, sheet: app.chatSheet).flatMap(\.chats).contains { $0.id == id })
    }

    func testWhileTheMacSleepsTheAnswerWaitsAndComesWhenItWakes() async throws {
        let app = try app()
        app.browser.macAsleep = true
        app.ask("plan a calm saturday", page: nil)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.role, .wait)
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.text, "\(app.macName) is asleep \u{00B7} since 18:52\nIt starts when it wakes.")
        XCTAssertEqual(ChatWords.line(app.chats.chat(id)!, app: app), "Waits for \(app.macName)")
        app.macWoke()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.role, .answer)
        XCTAssertTrue(app.chats.chat(id)?.messages.last?.text.hasPrefix("Coffee at Kaffe") ?? false)
    }

    func testAnAnswerThatLandsOffScreenIsNew() async throws {
        let app = try app()
        app.ask("plan a calm saturday", page: nil)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.expand()
        app.chats.parked = .init(chat: id, mode: .chat)
        app.hideSheet()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.chats.chat(id)?.unread, true)
        XCTAssertEqual(app.chats.unreadCount, 2, "Design Systems Night and this one")
    }

    func testPinUnreadAndArchiveKeepTheChat() throws {
        let app = try app()
        let count = app.chats.chats.count
        app.setPinned("cafe", true)
        XCTAssertEqual(app.chats.chat("cafe")?.pinned, true)
        XCTAssertEqual(ChatSectioning.sections(app.chats.chats, sheet: app.chatSheet).first?.chats.map(\.id), ["plan", "cafe"])
        app.setUnread("cafe", true)
        XCTAssertEqual(app.chats.chat("cafe")?.unread, true)
        app.archive("cafe")
        XCTAssertEqual(app.chats.chat("cafe")?.archived, true)
        XCTAssertFalse(ChatSectioning.sections(app.chats.chats, sheet: app.chatSheet).flatMap(\.chats).contains { $0.id == "cafe" })
        // Search still finds it, marked archived.
        let found = ChatSectioning.search("mariatorget", in: app.chats.chats, sheet: app.chatSheet, app: app)
        XCTAssertEqual(found.map(\.id), ["cafe"])
        XCTAssertEqual(found.first?.archived, true)
        app.unarchive("cafe")
        XCTAssertEqual(app.chats.chat("cafe")?.archived, false)
        XCTAssertEqual(app.chats.chats.count, count, "archive deletes nothing")
        let haptics = Haptics.played.suffix(4).map { "\($0.kind.rawValue) \($0.reason)" }
        XCTAssertEqual(haptics, ["light pin", "light unread", "light archive", "light archive"])
    }

    func testDeleteChatAsksThenRemovesItAndClosesIt() throws {
        let previous = Motion.disabled; Motion.disabled = true; defer { Motion.disabled = previous }
        let app = try app()
        app.openChat("cafe")
        XCTAssertTrue(app.canDelete("cafe"))
        app.pickMore(.delete)
        XCTAssertEqual(app.chatSheet.deleting, "cafe", "⋯'s Delete Chat asks first")
        XCTAssertNotNil(app.chats.chat("cafe"))
        XCTAssertEqual(app.deleteQuestion("cafe").title, "Delete this chat?", "a chat with no Mac to take Delete goes from here")
        app.deleteChat("cafe")
        XCTAssertNil(app.chats.chat("cafe"))
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertNil(app.chatSheet.chatID)
        XCTAssertTrue(ChatSectioning.search("mariatorget", in: app.chats.chats, sheet: app.chatSheet, app: app).isEmpty, "search doesn't find it")
        XCTAssertTrue(ChatNativeMenu.menu(chat: "grinder", app: app).children.contains { ($0 as? UIMenu)?.children.contains { $0.title == "Delete Chat\u{2026}" } == true })
        // A chat still working stays: stop it first, as on the Mac.
        app.chats.update("grinder") { $0.messages.append(Message(role: .typing, text: "")) }
        XCTAssertFalse(app.canDelete("grinder"))
        app.deleteChat("grinder")
        XCTAssertNotNil(app.chats.chat("grinder"))
        XCTAssertFalse(ChatNativeMenu.menu(chat: "grinder", app: app).children.contains { $0 is UIMenu })
    }

    func testYourChatsAreInTheirSections() throws {
        let app = try app()
        let sections = ChatSectioning.sections(app.chats.chats, sheet: app.chatSheet)
        XCTAssertEqual(sections.map(\.title), ["Pinned", "Today", "Yesterday", "Earlier"])
        XCTAssertEqual(sections.map { $0.chats.map(\.id) }, [["plan"], ["lisbon", "lumen", "cafe"], ["grinder", "crdt"], ["export", "weekend"]])
        XCTAssertEqual(ChatWords.status(app.chats.chat("grinder")!, app: app).text, "Baratza Encore ESP \u{00B7} $199")
        XCTAssertEqual(ChatWords.status(app.chats.chat("lisbon")!, app: app).text, "Booked \u{00B7} TAP, Oct 13 18:35, seat 14A")
        // Titles, status words and every message: "lis" is Lisbon, and the waitlist and a list.
        XCTAssertEqual(ChatSectioning.search("lis", in: app.chats.chats, sheet: app.chatSheet, app: app).map(\.id), ["plan", "lisbon", "crdt"])
        XCTAssertEqual(ChatSectioning.search("kitchen", in: app.chats.chats, sheet: app.chatSheet, app: app).map(\.id), ["arch-kitchen"])
        XCTAssertTrue(ChatSectioning.search("zzz", in: app.chats.chats, sheet: app.chatSheet, app: app).isEmpty)
    }

    func testANewChatIsNamedByItsFirstWords() throws {
        let app = try app()
        app.newChat(focus: false)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertTrue(app.chatSheet.fresh.contains(id))
        XCTAssertEqual(app.surfaces.chat, .newChat)
        XCTAssertEqual(app.chatSheet.ideas[app.browser.tab!.id], ["Summarize this page", "What does Anna want?", "Draft replies to Anna"])
        app.send("plan a calm saturday in stockholm")
        XCTAssertEqual(app.chats.chat(id)?.title, "Saturday in Stockholm")
        XCTAssertFalse(app.chatSheet.fresh.contains(id))
    }

    func testWhenTheModelOnThisIPhoneCantClaudeAnswersAndTheHeadSaysSo() async throws {
        let app = try app()
        app.chatSheet.answerers.device = FailingDevice()
        app.ask("what does anna want?", page: app.browser.tab)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        XCTAssertEqual(app.chats.chat(id)?.by, .iphone)
        XCTAssertEqual(ChatWords.status(app.chats.chat(id)!, app: app).text, "Apple Intelligence is answering")
        try await Task.sleep(for: .milliseconds(300))
        let chat = try XCTUnwrap(app.chats.chat(id))
        XCTAssertEqual(chat.by, .claude, "the head says Claude, on your Mac")
        XCTAssertEqual(chat.messages.map(\.role), [.you, .answer])
        XCTAssertEqual(chat.messages.last?.by, .claude)
    }

    func testSearchReadsAnAnswerThatLandedInPlaceOfItsTypingDots() async throws {
        let app = try app()
        app.ask("plan a calm saturday", page: nil)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.expand()
        XCTAssertEqual(app.chats.chat(id)?.messages.last?.role, .typing)
        XCTAssertTrue(ChatSectioning.search("nook has a table", in: app.chats.chats, sheet: app.chatSheet, app: app).isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(app.chats.chat(id)?.messages.map(\.role), [.you, .answer], "the same count of turns")
        XCTAssertEqual(ChatSectioning.search("nook has a table", in: app.chats.chats, sheet: app.chatSheet, app: app).map(\.id), [id])
    }

    func testANewQuestionLetsAHiddenQuickAnswerGo() throws {
        let app = try app()
        let before = app.chats.chats.count
        app.ask("what does anna want?", page: app.browser.tab)
        let first = try XCTUnwrap(app.chatSheet.chatID)
        app.chats.parked = .init(chat: first, mode: .answer)
        app.hideSheet()
        app.ask("summarize this page", page: app.browser.tab)
        XCTAssertNil(app.chats.chat(first), "the hidden answer gave way")
        XCTAssertEqual(app.chats.chats.count, before + 1)
    }

    func testEscapeClosesTheInnermostThingThenReturnsToTheChatsPage() throws {
        let previousMotion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = previousMotion }
        let app = try app()
        app.openChat("cafe")
        let sheet = app.chatSheet
        sheet.moreMenu = true
        app.escapeSheet()
        XCTAssertFalse(sheet.moreMenu, "the menu closed first")
        XCTAssertTrue(sheet.shown)
        app.escapeSheet()
        XCTAssertFalse(sheet.shown, "a conversation returns to New Tab's Chats page")
        XCTAssertEqual(app.surfaces.field, .newTab)
        XCTAssertEqual(NewTabPager.shared.startAt, NewTabPager.chatsPage)
        XCTAssertNil(app.chats.parked, "ordinary chats do not reopen from a parked line")
    }

    func testHistoryExitNeverReopensARetainedChatAndPreservesPublicOrPrivateBrowser() throws {
        let previousMotion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = previousMotion }
        for isPrivate in [false, true] {
            // This route test explicitly disables its own injected biometric gate.
            let app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false, privateLockEnabled: { false })
            if isPrivate {
                app.browser.open(Tab(id: "private-exit", title: "Private", site: "Private", icon: "globe", url: "about:blank", isPrivate: true))
            }
            let tab = try XCTUnwrap(app.browser.tab)
            let space = app.browser.spaceID
            let count = app.chats.chats.count
            app.openChat("cafe")
            app.openHistory()
            // ‹ lands on New Tab's Chats page; the conversation is not kept up.
            XCTAssertFalse(app.chatSheet.shown)
            XCTAssertNil(app.surfaces.chat)
            XCTAssertNil(app.chatSheet.chatID)
            XCTAssertEqual(app.surfaces.field, .newTab)
            XCTAssertEqual(NewTabPager.shared.startAt, NewTabPager.chatsPage)
            XCTAssertEqual(app.browser.tab, tab)
            XCTAssertEqual(app.browser.spaceID, space)
            XCTAssertEqual(app.browser.tab?.isPrivate, isPrivate)
            XCTAssertEqual(app.chats.chats.count, count)
            XCTAssertNil(app.chats.parked)
            XCTAssertEqual(app.surfaces.recede, 0)
            XCTAssertEqual(app.surfaces.scrim, 0)
            for _ in 0..<2 {
                app.openChats()
                XCTAssertNil(app.surfaces.chat, "Chats is a page of New Tab, not the sheet")
                XCTAssertNil(app.chatSheet.chatID)
                XCTAssertFalse(app.chatSheet.shown)
                XCTAssertEqual(app.surfaces.field, .newTab)
            }
        }
    }

    func testNewChatIsAlreadyAFullPageAndQuickAnswersKeepNow() throws {
        let previousMotion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = previousMotion }
        let app = try app()
        app.newChat(focus: false)
        XCTAssertEqual(app.chatSheet.pose.t, 1)
        XCTAssertEqual(app.chatSheet.pose.h, Double(Metrics.Chats.newTrayHeight))
        app.send("a small local fixture question")
        XCTAssertEqual(app.chatSheet.pose.t, 1)
        app.closeSheet()
        app.ask("what does anna want?", page: app.browser.tab)
        let id = try XCTUnwrap(app.chatSheet.chatID)
        app.escapeSheet()
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.chats.parked, ChatStore.Parked(chat: id, mode: .answer))
    }

    func testAQuestionsBubbleBreaksItsLinesAsTheBrowserDoes() {
        let one = BubbleLayout("what does anna want?")
        XCTAssertEqual(one.lines, ["what does anna want?"])
        XCTAssertFalse(one.wraps)
        XCTAssertLessThan(one.width, Metrics.Chat.bubbleMaxWidth)
        XCTAssertEqual(one.size.height, 17 * 1.3 + 16, accuracy: 0.01)
        let two = BubbleLayout("and what did she say about the sprint?")
        XCTAssertEqual(two.lines, ["and what did she say about the", "sprint?"], "each word on the first line it fits")
        XCTAssertEqual(two.width, 290, "wrapped, it takes the whole 290")
        XCTAssertEqual(two.size.height, 2 * 17 * 1.3 + 16, accuracy: 0.01)
    }

    func testTheGutterFollowsTheSheetAsItMoves() {
        let screen = Metrics.screen
        let now = SheetGeometry.nowShape(screen: screen)
        let field = SheetShape(rect: CGRect(x: 20, y: 512, width: 362, height: 46), top: 23, bottom: 23)
        let growing = SheetGeometry(screen: screen, pose: SheetPose(t: 0, o: 0.5, h: 343), origin: field, now: now)
        XCTAssertEqual(growing.gutter, 12)
        XCTAssertEqual(growing.restTurnsWidth, 386 - 24)
        let parking = SheetGeometry(screen: screen, pose: SheetPose(t: 1, p: 0.5, h: 343), origin: nil, now: now)
        XCTAssertEqual(parking.gutter, 14, accuracy: 0.001, "20 less the sheet's inset, 6, on its way to the Now line")
        XCTAssertEqual(TaskTurnsView.waitWords(since: nil), "Waits for your Mac \u{00B7} asleep. It starts when the Mac wakes.")
    }

    func testTwoThousandChatsSectionAndSearchQuickly() throws {
        let app = try app("chats-2000")
        XCTAssertEqual(app.chats.chats.count, 2000)
        XCTAssertEqual(app.chats.archived.count, 30)
        let sheet = app.chatSheet
        var start = Date()
        let sections = ChatSectioning.sections(app.chats.chats, sheet: sheet)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05, "sectioning 2000 chats")
        XCTAssertEqual(sections.map(\.title), ["Pinned", "Today", "Yesterday", "Earlier"])
        XCTAssertEqual(sections.reduce(0) { $0 + $1.chats.count }, 1970)
        _ = ChatSectioning.search("warm-up", in: app.chats.chats, sheet: sheet, app: app)
        start = Date()
        let hits = ChatSectioning.search("lisbon", in: app.chats.chats, sheet: sheet, app: app)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "searching 2000 chats, warmed up")
        XCTAssertFalse(hits.isEmpty)
        let archivedWord = try XCTUnwrap(app.chats.archived.first?.title.components(separatedBy: " ").first?.lowercased())
        XCTAssertTrue(ChatSectioning.search(archivedWord, in: app.chats.chats, sheet: sheet, app: app).contains { $0.archived })
    }
}

/// The model on this iPhone failing: a guardrail, a full context, not ready.
@MainActor
private final class FailingDevice: ChatBackend {
    let who = Chat.Answerer.iphone
    var isAvailable: Bool { true }
    func answer(_ context: AskContext) async throws -> String { throw CancellationError() }
}
