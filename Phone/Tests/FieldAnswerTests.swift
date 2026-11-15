import UIKit
import WebKit
import XCTest
@testable import YabPhone

@MainActor
final class FieldAnswerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_334_000)
    private var oldMotion = false
    private var oldChats = false
    private var oldActiveMode: Surfaces.FieldMode?

    override func setUp() {
        oldMotion = Motion.disabled; Motion.disabled = true
        oldChats = NewTabPager.shared.onChats; NewTabPager.shared.onChats = false
        oldActiveMode = NewTabPager.shared.activeFieldMode; NewTabPager.shared.activeFieldMode = nil
        FieldAnswers.shared.clear()
    }

    override func tearDown() {
        FieldAnswers.shared.clear()
        NewTabPager.shared.onChats = oldChats
        NewTabPager.shared.activeFieldMode = oldActiveMode
        Motion.disabled = oldMotion
    }

    private func rates() -> Rates {
        let rates = Rates(kept: false)
        rates.set(["EUR": 0.9, "GBP": 0.8, "JPY": 150, "BTC": 0.00001])
        return rates
    }

    func testSharedParserCoversThePhonesAnswersAndPlainClipboardValues() throws {
        let rates = rates()
        for (words, copy) in [("2400*12", "28800"), ("20% of 80", "16"),
                              ("5 km to mi", "3.1069 mi"), ("100 usd in eur", "90"),
                              ("255 in hex", "0xFF"), ("0xff in decimal", "255")] {
            let answer = try XCTUnwrap(Calc.answer(words, now: now, rates: rates), words)
            XCTAssertEqual(answer.copy, copy, words)
            XCTAssertTrue(FieldAnswerPolicy.takesKey(words, answer: answer, now: now), words)
        }
    }

    func testURLsSearchesAndIncompleteSumsNeverTakeTheCopyKey() {
        for words in ["https://example.com/2+2", "127.0.0.1", "localhost:3000", "2+", "1/0",
                      "2026", "iphone 15 to 16", "top 10", "5 km to kg", "lisbon weather october"] {
            let answer = Calc.answer(words, now: now, rates: rates())
            XCTAssertNil(answer, words)
            XCTAssertFalse(FieldAnswerPolicy.takesKey(words, answer: answer, now: now), words)
        }
        // Defense in depth: even a stale visible answer never turns a URL
        // into a clipboard action.
        XCTAssertFalse(FieldAnswerPolicy.takesKey("https://example.com/2+2", answer: Calc.math("2+2"), now: now))
    }

    func testTimeAndDateCanBeCopiedByTapButReturnStillSearches() throws {
        for words in ["time in tokyo", "3pm london in sf", "days until christmas", "in 3 weeks"] {
            let answer = try XCTUnwrap(Calc.answer(words, now: now, rates: rates()), words)
            XCTAssertFalse(answer.copy.isEmpty, words)
            XCTAssertFalse(FieldAnswerPolicy.takesKey(words, answer: answer, now: now), words)
        }
    }

    func testWaitingAndFailedRatesStayUncopyableAndRefreshWhenRatesArrive() async throws {
        let rates = Rates(kept: false)
        rates.fetch = { nil }
        let request = rates.warm()
        let waiting = try XCTUnwrap(Calc.answer("100 dollars to euros", now: now, rates: rates))
        XCTAssertEqual(waiting.result, "…")
        XCTAssertEqual(waiting.copy, "")
        XCTAssertFalse(FieldAnswerPolicy.takesKey("100 dollars to euros", answer: waiting, now: now))
        XCTAssertNil(FieldAnswerPolicy.reversed(waiting, words: "100 dollars to euros", rates: rates))
        await request?.value
        let failed = try XCTUnwrap(Calc.answer("100 dollars to euros", now: now, rates: rates))
        XCTAssertEqual(failed.resultNote, "Rates unavailable")
        XCTAssertEqual(failed.copy, "")
        rates.set(["EUR": 0.9])
        XCTAssertEqual(Calc.answer("100 dollars to euros", now: now, rates: rates)?.copy, "90")
    }

    func testSwapPreservesUnitBaseAndCurrencyClipboardSemantics() throws {
        let rates = rates()
        for (words, expected) in [("5 km to mi", "5 km"), ("0xff in decimal", "0xFF"),
                                  ("255 in hex", "255"), ("100 usd in eur", "100")] {
            let original = try XCTUnwrap(Calc.answer(words, now: now, rates: rates))
            let swapped = try XCTUnwrap(FieldAnswerPolicy.reversed(original, words: words, rates: rates))
            XCTAssertEqual(swapped.question, original.result)
            XCTAssertEqual(swapped.result, original.question)
            XCTAssertEqual(swapped.copy, expected)
        }
        let sum = try XCTUnwrap(Calc.math("2+2"))
        XCTAssertNil(FieldAnswerPolicy.reversed(sum, words: "2+2", rates: rates))
    }

    func testCopyReturnKeepsFieldAndPageAndPrivateAnswersStayLocal() throws {
        // This simulator's clipboard belongs to the test. Reading every
        // flavor of its old contents can wait forever on a former provider.
        UIPasteboard.general.string = "owned field-answer copy fixture"
        defer { UIPasteboard.general.string = "" }
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        let tab = app.browser.tab?.id
        app.surfaces.openField(.newTab)
        app.field.setPrivate(true)
        app.field.typed("2400*12")
        XCTAssertEqual(app.fieldKey, .search)
        app.fieldReturn()
        XCTAssertEqual(UIPasteboard.general.string, "28800")
        XCTAssertEqual(app.browser.tab?.id, tab)
        XCTAssertTrue(app.field.shown)
        XCTAssertEqual(app.field.text, "2400*12")
        XCTAssertTrue(app.field.place.isPrivate)
        XCTAssertEqual(FieldAnswers.shared.copied?.words, "2400*12")
        app.copyFieldResult("2400 × 12", markAnswer: false)
        XCTAssertEqual(UIPasteboard.general.string, "2400 × 12")
        XCTAssertNil(FieldAnswers.shared.copied, "Copy Question must not claim that the result was copied")
    }

    func testURLAndSearchReturnLeaveTheClipboardUntouchedAndChooseTheBrowserRow() throws {
        UIPasteboard.general.string = "untouched browser clipboard"
        defer { UIPasteboard.general.string = "" }
        for words in ["https://example.com/2+2", "lisbon weather october"] {
            let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
            app.surfaces.openField(.address)
            app.field.typed(words)
            UIPasteboard.general.string = "untouched browser clipboard"
            XCTAssertNil(app.fieldAnswer)
            XCTAssertFalse(app.fieldAnswerTakesKey)
            XCTAssertFalse(app.fieldRows.isEmpty)
            app.fieldReturn()
            XCTAssertEqual(UIPasteboard.general.string, "untouched browser clipboard")
            XCTAssertNil(app.surfaces.field, "Return chose the actual browser row")
        }
    }

    func testOnlyActualChatsContextSuppressesAnswersIncludingStalePagerState() throws {
        XCTAssertTrue(FieldAnswerPolicy.searchesChats(mode: .newTab, activeMode: .newTab, onChats: true, isPrivate: false))
        XCTAssertTrue(FieldAnswerPolicy.searchesChats(mode: .address, activeMode: .address, onChats: true, isPrivate: false))
        XCTAssertFalse(FieldAnswerPolicy.searchesChats(mode: .address, activeMode: .newTab, onChats: true, isPrivate: false))
        XCTAssertFalse(FieldAnswerPolicy.searchesChats(mode: .newTab, activeMode: .newTab, onChats: true, isPrivate: true))
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        app.surfaces.openField(.address)
        app.field.typed("2+2")
        NewTabPager.shared.onChats = true
        XCTAssertEqual(app.fieldAnswer?.copy, "4")
        XCTAssertFalse(app.fieldRows.isEmpty)
        app.surfaces.openField(.newTab)
        app.field.typed("2+2")
        NewTabPager.shared.activeFieldMode = .newTab
        XCTAssertNil(app.fieldAnswer)
        XCTAssertTrue(app.fieldRows.isEmpty)
        XCTAssertFalse(app.fieldMathKeys)
        app.field.setPrivate(true)
        XCTAssertEqual(app.fieldAnswer?.copy, "4")
    }

    func testMathKeysUseTheNativeCaretAndSelectionAndEveryControlFitsSmallPhone() throws {
        for words in ["2", " (2+3)", "-2*3", "1.5", "100%"] { XCTAssertTrue(FieldAnswerPolicy.mathKeys(words), words) }
        for words in ["", "sqrt(2)", "2 km", "12 dollars", "site.com"] { XCTAssertFalse(FieldAnswerPolicy.mathKeys(words), words) }
        let field = UITextField()
        field.text = "1234"
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 1))
        let end = try XCTUnwrap(field.position(from: start, offset: 2))
        field.selectedTextRange = field.textRange(from: start, to: end)
        let keys = FieldMathKeys(); keys.field = field
        keys.insert("×")
        XCTAssertEqual(field.text, "1×4")
        keys.insert("−")
        XCTAssertEqual(field.text, "1×-4", "The minus label inserts the shared parser's ASCII minus")
        XCTAssertEqual(Calc.math("1×-4")?.copy, "-4")
        keys.frame = CGRect(x: 0, y: 0, width: 375, height: Metrics.FieldAnswer.keysHeight)
        keys.layoutIfNeeded()
        let buttons = keys.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }
        XCTAssertEqual(buttons.count, 7)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.bounds.width, 44)
            XCTAssertGreaterThanOrEqual(button.bounds.height, 44)
        }
    }

    func testNativePasteUsesOriginalEditableSelectionRatherThanNewFocus() async throws {
        let view = try await page("<input id='first' value='abcdef'><input id='second' value='untouched'>")
        _ = try await view.evaluateJavaScript("first.focus(); first.setSelectionRange(2,4); window.events=0; first.oninput=()=>events++; true")
        let target = FieldPasteTarget(tab: "owned", view: view)
        let captured = await capture(target)
        XCTAssertTrue(captured)
        _ = try await view.evaluateJavaScript("second.focus(); second.setSelectionRange(0,2)")
        let inserted = await insert("28800", target: target)
        XCTAssertTrue(inserted)
        let values = try await view.evaluateJavaScript("[first.value,second.value,String(events)]") as? [String]
        XCTAssertEqual(values, ["ab28800ef", "untouched", "1"])
        let repeated = await insert("again", target: target)
        XCTAssertFalse(repeated, "The bookmark is consumed by the explicit paste")
    }

    func testNativePasteRejectsUnsupportedInputsDetachedTargetsAndNewDocuments() async throws {
        let view = try await page("<input id='mail' type='email'><input id='secret' type='password'><fieldset id='group'><textarea id='draft'>before</textarea></fieldset>")
        for id in ["mail", "secret"] {
            _ = try await view.evaluateJavaScript("document.getElementById('\(id)').focus()")
            let target = FieldPasteTarget(tab: "owned", view: view)
            let captured = await capture(target)
            XCTAssertFalse(captured, id)
        }
        _ = try await view.evaluateJavaScript("draft.focus(); draft.setSelectionRange(0,6)")
        let detached = FieldPasteTarget(tab: "owned", view: view)
        let captured = await capture(detached)
        XCTAssertTrue(captured)
        _ = try await view.evaluateJavaScript("group.disabled=true; true")
        let disabled = await insert("answer", target: detached)
        XCTAssertFalse(disabled)
        let original = try await view.evaluateJavaScript("draft.value") as? String
        XCTAssertEqual(original, "before")
        _ = try await view.evaluateJavaScript("group.disabled=false; draft.focus(); true")
        let removed = FieldPasteTarget(tab: "owned", view: view)
        let recaptured = await capture(removed)
        XCTAssertTrue(recaptured)
        _ = try await view.evaluateJavaScript("draft.remove()")
        let inserted = await insert("answer", target: removed)
        XCTAssertFalse(inserted)
        _ = try await view.evaluateJavaScript("document.body.innerHTML='<input id=next value=before>'; next.focus()")
        let previous = FieldPasteTarget(tab: "owned", view: view)
        let nextCaptured = await capture(previous)
        XCTAssertTrue(nextCaptured)
        try await load("<input id='fresh' value='new document'>", in: view)
        let afterNavigation = await insert("answer", target: previous)
        XCTAssertFalse(afterNavigation)
        let value = try await view.evaluateJavaScript("fresh.value") as? String
        XCTAssertEqual(value, "new document")
    }

    func testLocalAnswersAndIncompleteArithmeticCancelSuggestionsBeforeAnyRequest() async {
        var requested: [URL] = []
        let suggest = SearchSuggest(enabled: { true }) { url in
            requested.append(url)
            return Data(#"["weather lisbon",["weather lisbon today"]]"#.utf8)
        }
        let pending = suggest.ask("old pending words", engine: .google)
        suggest.ask("2400*", engine: .google, local: FieldAnswerPolicy.keepsLocal("2400*"))
        await pending?.value
        XCTAssertTrue(requested.isEmpty, "Changing to local arithmetic must cancel the old delayed request too")
        let rates = rates()
        for words in ["2", "2400*", "(2+", "sqrt(", "2x", "2400*12", "20% of 80", "5 km to mi",
                      "100 usd in eur", "time in tokyo", "days until christmas"] {
            let local = FieldAnswerPolicy.keepsLocal(words, rates: rates)
            XCTAssertTrue(local, words)
            await suggest.ask(words, engine: .google, local: local)?.value
        }
        XCTAssertTrue(requested.isEmpty)
        XCTAssertTrue(suggest.phrases(for: "2400*").isEmpty)
        let words = "weather lisbon"
        XCTAssertFalse(FieldAnswerPolicy.keepsLocal(words, rates: rates))
        await suggest.ask(words, engine: .google, local: false)?.value
        XCTAssertEqual(requested.count, 1, "Ordinary search suggestions still use the production URL-building path")
        let query = requested.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems
        XCTAssertEqual(query?.first { $0.name == "q" }?.value, words)
        XCTAssertEqual(suggest.phrases(for: words), ["weather lisbon today"])
    }

    func testSuggestionsAskTheChosenEngineAndGoogleFixesSpellingInTheWordsLanguage() throws {
        let russian = "\u{44D}\u{43D}\u{433}\u{430}\u{440} \u{440}\u{430}\u{439}\u{444}\u{442}"
        let google = try XCTUnwrap(SearchSuggest.url(for: russian, engine: .google, languages: ["en-US", "ru-RU", "emoji"]))
        let items = URLComponents(url: google, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "client" }?.value, "chrome-omni", "Only this client fixes spelling")
        XCTAssertEqual(items.first { $0.name == "hl" }?.value, "ru-RU", "Russian words on an English iPhone with a Russian keyboard")
        XCTAssertEqual(SearchSuggest.language(of: "weather", in: ["de-DE", "en-US"]), "de-DE")
        XCTAssertEqual(SearchSuggest.language(of: russian, in: ["en-US"]), "en-US")
        XCTAssertEqual(SearchSuggest.url(for: "c++", engine: .bing, languages: ["en"])?.host(), "api.bing.com")
        XCTAssertTrue(SearchSuggest.url(for: "c++", engine: .bing, languages: ["en"])?.absoluteString.contains("c%2B%2B") == true)
        for engine in SearchEngine.allCases where engine != .custom {
            XCTAssertNotNil(SearchSuggest.url(for: "words", engine: engine, languages: ["en"]), engine.rawValue)
        }
        XCTAssertNil(SearchSuggest.url(for: "words", engine: .custom, languages: ["en"]))
        XCTAssertNil(SearchSuggest.url(for: "", engine: .google, languages: ["en"]))
    }

    func testSuggestionAnswersKeepPhrasesAndDropGoogleSites() {
        let google = #")]}'\#n["yt",["yt music","https://www.youtube.com/","yt studio"],["","",""],[],{"google:suggesttype":["QUERY","NAVIGATION","QUERY"]}]"#
        XCTAssertEqual(SearchSuggest.parse(Data(google.utf8)), ["yt music", "yt studio"])
        XCTAssertEqual(SearchSuggest.parse(Data(#"["yt",["yt music"]]"#.utf8)), ["yt music"])
        XCTAssertEqual(SearchSuggest.parse(Data(#"{"data":{"items":[{"value":"yt music"}]}}"#.utf8)), ["yt music"])
        XCTAssertEqual(SearchSuggest.parse(Data("not json".utf8)), [])
    }

    private func capture(_ target: FieldPasteTarget) async -> Bool {
        await withCheckedContinuation { target.capture(completion: $0.resume(returning:)) }
    }

    private func insert(_ value: String, target: FieldPasteTarget) async -> Bool {
        await withCheckedContinuation { target.insert(value, completion: $0.resume(returning:)) }
    }

    private func page(_ html: String) async throws -> WKWebView {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let previous = scene?.windows.first(where: \.isKeyWindow)
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: window.rootViewController!.view.bounds, configuration: configuration)
        window.rootViewController!.view.addSubview(view)
        addTeardownBlock { @MainActor in
            view.removeFromSuperview(); window.isHidden = true; previous?.makeKey()
        }
        try await load(html, in: view)
        return view
    }

    private func load(_ html: String, in view: WKWebView) async throws {
        let done = expectation(description: "owned answer paste document")
        let delegate = AnswerPageLoaded { done.fulfill() }
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: URL(string: "https://answer.example/"))
        await fulfillment(of: [done], timeout: 10)
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AnswerPageLoaded: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(_ done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}
