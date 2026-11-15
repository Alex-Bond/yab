import XCTest
@testable import YabPhone

/// Voice search from New Tab's field: what heard words become in the field,
/// the words coming in live, Return when they end (a tap or a pause), the
/// field as it was when nothing was said, typing taking over, the
/// permissions' answers, and where the microphone shows at all.
@MainActor
final class VoiceSearchTests: XCTestCase {
    private var app: AppModel!
    private var voice: ManualVoice!

    override func setUp() async throws {
        Motion.disabled = true
        app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.toastsStay = true
        voice = ManualVoice()
        app.voice.use(voice)
    }

    // MARK: - what goes into the field

    func testHeardWordsAreWrittenAsTypedWordsWouldBe() {
        XCTAssertEqual(VoiceSearch.route("lisbon weather october"), "lisbon weather october")
        XCTAssertEqual(VoiceSearch.route("  lisbon   weather \n october "), "lisbon weather october")
        XCTAssertEqual(VoiceSearch.route("Lisbon weather in October."), "Lisbon weather in October", "dictation's full stop goes")
        XCTAssertEqual(VoiceSearch.route("What does Anna want?"), "What does Anna want?", "a question stays one: it asks")
        XCTAssertEqual(VoiceSearch.route("apple dot com"), "apple.com")
        XCTAssertEqual(VoiceSearch.route("w w w dot apple dot com"), "www.apple.com")
        XCTAssertEqual(VoiceSearch.route("Apple dot com slash store"), "apple.com/store")
        XCTAssertEqual(VoiceSearch.route("dot com bubble"), "dot com bubble", "words with dot in them stay words")
        XCTAssertNil(VoiceSearch.route(""))
        XCTAssertNil(VoiceSearch.route(" . "))
    }

    // MARK: - listening

    func testWordsComeLiveAndATapIsReturn() async throws {
        app.surfaces.openField(.newTab)
        let tabs = app.browser.allTabs.count
        app.voice.toggle()
        try await waitFor { self.app.voice.phase == .listening }
        XCTAssertEqual(Haptics.played.last?.reason, Haptics.Reason.voice)
        voice.say("lisbon", final: false)
        XCTAssertEqual(app.field.text, "lisbon", "the field takes the words as they come")
        voice.say("lisbon weather october", final: false)
        XCTAssertEqual(app.field.text, "lisbon weather october")
        XCTAssertEqual(app.fieldRows.first?.action, .search, "the rows follow them as they follow typing")
        app.voice.toggle()
        XCTAssertEqual(app.voice.phase, .idle)
        XCTAssertTrue(voice.cancelled)
        XCTAssertEqual(app.browser.allTabs.count, tabs + 1, "Return opened a new tab")
        XCTAssertEqual(app.browser.tab?.title, "lisbon weather october · Google Search")
        XCTAssertNil(app.surfaces.field)
    }

    func testAPauseAfterTheWordsIsReturnAndASpokenAddressOpensTheSite() async throws {
        app.voice.pause = .milliseconds(80)
        app.surfaces.openField(.newTab)
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        voice.say("lumen dot events", final: false)
        try await waitFor { self.app.voice.phase == .idle }
        XCTAssertEqual(app.browser.tab?.page, "lumen", "lumen.events opened as typed")
    }

    func testFinalWordsGoAtOnce() async throws {
        app.surfaces.openField(.newTab)
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        voice.say("what does anna want?", final: true)
        XCTAssertEqual(app.voice.phase, .idle)
        XCTAssertNotNil(app.surfaces.chat, "a question is an ask, as typed")
    }

    func testNothingSaidLeavesTheFieldAsItWas() async throws {
        app.voice.firstWords = .milliseconds(80)
        app.surfaces.openField(.newTab)
        app.field.typed("")
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        try await waitFor { self.app.voice.phase == .idle }
        XCTAssertEqual(app.field.text, "")
        XCTAssertEqual(app.surfaces.field, .newTab, "the field stays open, nothing chosen")
    }

    func testTypingTakesOver() async throws {
        app.surfaces.openField(.newTab)
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        voice.say("lis", final: false)
        app.voice.interrupted()
        app.field.typed("lisbon")
        XCTAssertEqual(app.voice.phase, .idle)
        XCTAssertEqual(app.field.text, "lisbon")
        voice.say("late words", final: true)
        XCTAssertEqual(app.field.text, "lisbon", "nothing heard after counts")
        XCTAssertEqual(app.surfaces.field, .newTab)
    }

    func testTheFieldGoingStopsListening() async throws {
        app.surfaces.openField(.newTab)
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        app.voice.cancel()
        XCTAssertEqual(app.voice.phase, .idle)
        XCTAssertTrue(voice.cancelled)
    }

    func testPermissionsAreAskedOnTheTapAndANoIsSaid() async throws {
        app.surfaces.openField(.newTab)
        voice.permission = .microphoneOff
        XCTAssertEqual(voice.asked, 0, "nothing asked before the tap")
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .idle }
        XCTAssertEqual(voice.asked, 1)
        XCTAssertEqual(app.surfaces.toast?.text, "Microphone is off for Yab in Settings")
        voice.permission = .speechOff
        app.voice.begin()
        try await waitFor { self.app.surfaces.toast?.text == "Speech Recognition is off for Yab in Settings" }
        XCTAssertFalse(voice.started)
    }

    // MARK: - where it shows

    func testTheRightButtonsVoiceSearchOpensNewTabListening() async throws {
        app.openVoiceSearch()
        XCTAssertEqual(app.surfaces.field, .newTab)
        try await waitFor { self.app.voice.phase == .listening }
        voice.say("lisbon weather october", final: true)
        XCTAssertEqual(app.browser.tab?.title, "lisbon weather october · Google Search", "the same Return as the field's")
    }

    func testTheFieldKeepsItsLookUntilItListens() async throws {
        app.surfaces.openField(.newTab)
        XCTAssertFalse(app.voice.shows(in: app.field), "no microphone in the field at rest")
        app.voice.begin()
        try await waitFor { self.app.voice.phase == .listening }
        XCTAssertTrue(app.voice.shows(in: app.field), "lit while it listens, a tap on it is Return")
        app.voice.cancel()
        XCTAssertFalse(app.voice.shows(in: app.field))
    }

    func testOfferedWhereSpeechIsRecognizedAndInPrivateOnlyOnThisIPhone() {
        XCTAssertTrue(app.voice.offers(privately: false))
        XCTAssertTrue(app.voice.offers(privately: true))
        voice.onDevice = false
        XCTAssertTrue(app.voice.offers(privately: false))
        XCTAssertFalse(app.voice.offers(privately: true), "a private page's words never go to a server")
        app.voice.use(NoVoice())
        XCTAssertFalse(app.voice.offers(privately: false), "where speech can't be recognized, no Voice Search")
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end, !condition() { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}

/// A recognizer the test speaks for.
@MainActor
final class ManualVoice: VoiceEngine {
    var permission: VoiceSearch.Permission = .granted
    var onDevice = true
    private(set) var asked = 0
    private(set) var started = false
    private(set) var cancelled = false
    private var heard: (@MainActor (String, Bool) -> Void)?

    var isAvailable: Bool { true }

    func authorize() async -> VoiceSearch.Permission {
        asked += 1
        return permission
    }

    func start(heard: @escaping @MainActor (String, Bool) -> Void, ended: @escaping @MainActor (Error?) -> Void) throws {
        started = true
        cancelled = false
        self.heard = heard
    }

    func say(_ words: String, final: Bool) { heard?(words, final) }

    func cancel() {
        cancelled = true
    }
}
