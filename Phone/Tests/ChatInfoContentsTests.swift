import XCTest
@testable import YabPhone

/// Chat Info's tabs: what a chat touched, read once per change of the chat.
@MainActor
final class ChatInfoContentsTests: XCTestCase {
    override func setUp() async throws { ChatInfoMemo.reset() }
    override func tearDown() async throws { ChatInfoMemo.reset() }

    private func step(_ name: String, _ detail: String, at seconds: Double, kind: String = "tool") -> TurnWork.Step {
        TurnWork.Step(id: "\(name)-\(detail)-\(seconds)", kind: kind, name: name, detail: detail, state: "done",
                      began: Date(timeIntervalSince1970: seconds), ended: Date(timeIntervalSince1970: seconds + 5))
    }

    private func answer(_ text: String, steps: [TurnWork.Step]) -> Message {
        Message(role: .answer, text: text, by: .claude, work: TurnWork(kind: .actions, words: "Worked for 1m", steps: steps, text: text))
    }

    func testSitesAreTheHostsItsStepsWentToNewestFirstCountedAndNeverAMacTabOrAFile() throws {
        let contents = ChatInfoContents(messages: [
            Message(role: .you, text: "find a hotel"),
            answer("Done.", steps: [
                step("open", "booking.com", at: 100),
                step("snapshot", "tab:5213d2cb", at: 110),
                step("navigate", "https://www.timeout.com/lisbon/hotels", at: 120),
                step("open", "Package.swift", at: 125),
                step("close", "tab:5213d2cb", at: 128),
                step("ls", "/Users/me", at: 129, kind: "command"),
            ]),
            Message(role: .you, text: "and flights?"),
            answer("Here.", steps: [step("open", "booking.com", at: 200), step("fetch", "kayak.com, skyscanner.net", at: 210)]),
        ])
        XCTAssertEqual(contents.sites.map(\.host), ["skyscanner.net", "kayak.com", "booking.com", "timeout.com"])
        let booking = try XCTUnwrap(contents.sites.first { $0.host == "booking.com" })
        XCTAssertEqual(booking.visits, 2)
        XCTAssertEqual(booking.url.absoluteString, "https://booking.com")
        XCTAssertEqual(booking.last, Date(timeIntervalSince1970: 205))
        let timeout = try XCTUnwrap(contents.sites.first { $0.host == "timeout.com" })
        XCTAssertEqual(timeout.url.absoluteString, "https://www.timeout.com/lisbon/hotels", "the address the step named, not the bare site")
        XCTAssertFalse(contents.sites.contains { $0.host.contains("swift") || $0.host.contains("tab") })
        XCTAssertEqual(contents.steps, 8)
        XCTAssertEqual(contents.tabs, [.sites])
    }

    func testLinksAreTheWebLinksSaidInTheChatWithTheirWordsNewestFirst() {
        let contents = ChatInfoContents(messages: [
            Message(role: .you, text: "look at https://example.com/menu, please"),
            Message(role: .answer, text: "See [the **guide**](https://www.timeout.com/lisbon) and [a file](file:///etc/hosts), or javascript:alert(1).", by: .claude),
            Message(role: .note, text: "https://ignored.example.com"),
            Message(role: .answer, text: "Again: https://www.timeout.com/lisbon", by: .claude),
        ])
        XCTAssertEqual(contents.links.map(\.url.absoluteString), ["https://www.timeout.com/lisbon", "https://example.com/menu"])
        XCTAssertEqual(contents.links.first?.title, "the guide", "the words that named it first, without marks")
        XCTAssertEqual(contents.links.first?.host, "timeout.com")
        XCTAssertEqual(contents.links.last?.title, "example.com/menu", "a bare link reads as its address, the comma left out")
        XCTAssertEqual(contents.tabs, [.links])
    }

    func testPhotosAndFilesAreSplitOnceEachNewestFirst() {
        let photo = Message.File(name: "IMG_1.HEIC", type: "image/jpeg", size: 1000, digest: "p1")
        let pdf = Message.File(name: "Menu.pdf", type: "application/pdf", size: 2000, digest: "f1")
        let later = Message.File(name: "IMG_2.HEIC", type: "image/jpeg", size: 1000, digest: "p2")
        let contents = ChatInfoContents(messages: [
            Message(role: .you, text: "these", files: [photo, pdf]),
            Message(role: .you, text: "and this", files: [later, photo]),
        ])
        XCTAssertEqual(contents.media.map(\.file.digest), ["p2", "p1"])
        XCTAssertEqual(contents.files.map(\.file.name), ["Menu.pdf"])
        XCTAssertEqual(contents.tabs, [.media, .files])
    }

    func testAChatThatTouchedNothingHasNoTabs() {
        let contents = ChatInfoContents(messages: [Message(role: .you, text: "hi"), Message(role: .answer, text: "Hello!", by: .claude)])
        XCTAssertTrue(contents.isEmpty)
        XCTAssertEqual(contents.tabs, [])
        XCTAssertNil(contents.workLine)
    }

    func testTheLongStateChatTouchedThirtySitesAndItsLinksPhotosAndFiles() {
        let contents = ChatInfoContents(messages: StateCatalog.longChat().messages)
        XCTAssertEqual(contents.sites.count, 30)
        XCTAssertEqual(contents.links.count, 22)
        XCTAssertEqual(contents.media.count, 14)
        XCTAssertEqual(contents.files.count, 8)
        XCTAssertEqual(contents.tabs, [.sites, .links, .media, .files])
        XCTAssertTrue(contents.workLine?.hasPrefix("750 steps") == true, contents.workLine ?? "")
    }

    func testTheMemoKeepsAnUnchangedChatAndReadsAgainAfterANewMessage() async {
        var chat = Chat(id: "memo", title: "Memo", messages: [answer("See https://a.example.com", steps: [step("open", "a.example.com", at: 1)])])
        XCTAssertNil(ChatInfoMemo.cached(chat))
        let first = await ChatInfoMemo.contents(of: chat)
        XCTAssertEqual(first.links.count, 1)
        XCTAssertEqual(ChatInfoMemo.cached(chat), first, "unchanged, it opens with what was read")
        chat.title = "Renamed"
        XCTAssertEqual(ChatInfoMemo.cached(chat), first, "a new name changes nothing it lists")
        chat.messages.append(Message(role: .answer, text: "And https://b.example.com", by: .claude))
        XCTAssertNil(ChatInfoMemo.cached(chat), "a new message is read again")
        let second = await ChatInfoMemo.contents(of: chat)
        XCTAssertEqual(second.links.map(\.host), ["b.example.com", "a.example.com"])
        chat.messages[chat.messages.count - 1].text = "Changed: https://c.example.com"
        XCTAssertNil(ChatInfoMemo.cached(chat), "an edited last turn is read again")
        for n in 0..<(ChatInfoMemo.limit + 2) { _ = await ChatInfoMemo.contents(of: Chat(id: "other-\(n)", title: "")) }
        XCTAssertNil(ChatInfoMemo.cached(chat), "only the newest chats are kept")
    }

    func testASiteOrLinkFromInfoOpensANewTabAndPutsInfoAway() throws {
        let motion = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = motion }
        let app = AppModel(world: try World.load(named: "mira"))
        app.openChat("cafe")
        app.openChatInfo()
        XCTAssertTrue(app.chatSheet.info)
        let url = try XCTUnwrap(URL(string: "https://www.timeout.com/lisbon"))
        XCTAssertFalse(ChatMarkdown.openInNewTab(try XCTUnwrap(URL(string: "file:///etc/hosts")), from: "cafe", app: app))
        XCTAssertTrue(ChatMarkdown.openInNewTab(url, from: "cafe", app: app))
        XCTAssertFalse(app.chatSheet.info)
        XCTAssertFalse(app.chatSheet.shown)
        XCTAssertEqual(app.browser.tab?.url, url.absoluteString)
    }
}
