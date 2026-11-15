import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Translate page: which pages are offered (the language decisions), how a
/// page's words are batched (on screen first, each text once), the page
/// script on a real document (what it leaves alone, every word back with
/// Show Original), the whole flow in a test world with the stand-in
/// translator (Always Translate, private tabs), and a long article measured.
@MainActor
final class PageTranslateTests: XCTestCase {
    private var window: UIWindow!
    private var previousMotion = false

    override func setUp() async throws {
        previousMotion = Motion.disabled
        Motion.disabled = true
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        Motion.disabled = previousMotion
        window?.isHidden = true
        window = nil
    }

    // MARK: - which language

    func testLanguageCodesCompareByBaseLanguageAndChineseScript() {
        XCTAssertEqual(PageTranslate.code("pt-BR"), "pt")
        XCTAssertEqual(PageTranslate.code("en_US"), "en")
        XCTAssertEqual(PageTranslate.code("EN"), "en")
        XCTAssertEqual(PageTranslate.code("zh-Hans"), "zh-Hans")
        XCTAssertEqual(PageTranslate.code("zh-TW"), "zh-Hant", "Taiwan reads Traditional")
        XCTAssertEqual(PageTranslate.code("zh-CN"), "zh-Hans")
        XCTAssertNil(PageTranslate.code("und"))
        XCTAssertNil(PageTranslate.code(""))
        XCTAssertNil(PageTranslate.code(nil))
        XCTAssertNil(PageTranslate.code("{{lang}}"), "a template's placeholder is no language")
        XCTAssertEqual(PageTranslate.name("pt"), "Portuguese")
    }

    func testThePagesLanguageFromWhatItSaysAndWhatItsWordsAre() {
        // Only what the page says.
        XCTAssertEqual(PageTranslate.source(declared: "pt", hypotheses: [:], letters: 0), "pt")
        // Only its words, enough of them and sure.
        XCTAssertEqual(PageTranslate.source(declared: nil, hypotheses: ["pt": 0.95, "es": 0.03], letters: 500), "pt")
        XCTAssertNil(PageTranslate.source(declared: nil, hypotheses: ["pt": 0.95], letters: 20), "too few letters to say")
        XCTAssertNil(PageTranslate.source(declared: nil, hypotheses: ["pt": 0.4, "es": 0.35], letters: 900), "not sure")
        // Both agree.
        XCTAssertEqual(PageTranslate.source(declared: "en-US", hypotheses: ["en": 0.9], letters: 900), "en")
        // A template's lang="en" over a page written in Portuguese: many sure words win.
        XCTAssertEqual(PageTranslate.source(declared: "en", hypotheses: ["pt": 0.95], letters: 800), "pt")
        // Not sure enough, or too few words, and what the page says stands.
        XCTAssertEqual(PageTranslate.source(declared: "en", hypotheses: ["pt": 0.7], letters: 800), "en")
        XCTAssertEqual(PageTranslate.source(declared: "en", hypotheses: ["pt": 0.95], letters: 120), "en")
    }

    func testTheRecognizerHearsPortugueseAndEnglish() {
        let pt = PageTranslate.recognize("Às sete da manhã, Alfama ainda pertence a quem lá vive. As ruas estreitas cheiram a café e a pão quente, e o único som é o de uma porta que se abre.")
        XCTAssertEqual(pt.hypotheses.max { $0.value < $1.value }?.key, "pt")
        XCTAssertGreaterThan(pt.letters, 100)
        let en = PageTranslate.recognize("At seven in the morning, Alfama still belongs to the people who live there. The narrow streets smell of coffee and warm bread.")
        XCTAssertEqual(en.hypotheses.max { $0.value < $1.value }?.key, "en")
        XCTAssertEqual(PageTranslate.recognize("12:30 - 4 / 5").letters, 0)
    }

    func testOfferedOnlyInALanguageNoneOfThePersonsLanguages() {
        XCTAssertTrue(PageTranslate.offers(source: "pt", preferred: ["en-US"]))
        XCTAssertFalse(PageTranslate.offers(source: "pt", preferred: ["en-US", "pt-PT"]), "a person who reads Portuguese too")
        XCTAssertFalse(PageTranslate.offers(source: "en", preferred: ["en-GB"]), "another English is English")
        XCTAssertTrue(PageTranslate.offers(source: "zh-Hant", preferred: ["zh-Hans-CN"]), "the other Chinese script")
        XCTAssertFalse(PageTranslate.offers(source: nil, preferred: ["en"]))
        XCTAssertFalse(PageTranslate.offers(source: "pt", preferred: []))
        XCTAssertEqual(PageTranslate.target(preferred: ["ru-RU", "en-US"]), "ru", "into the first of the person's languages")
        XCTAssertEqual(PageTranslate.target(preferred: ["und", "de-DE"]), "de")
    }

    // MARK: - batches

    func testBatchesTakeWhatIsOnScreenFirstAndEachTextOnce() {
        let pieces = [
            PageTranslate.Piece(id: 0, text: "Reply", distance: 500),
            PageTranslate.Piece(id: 1, text: "Hello there", distance: 0),
            PageTranslate.Piece(id: 2, text: " Reply ", distance: 0),
            PageTranslate.Piece(id: 3, text: "Hello there", distance: 900),
            PageTranslate.Piece(id: 4, text: "   ", distance: 0),
            PageTranslate.Piece(id: 5, text: "Above the screen", distance: 1700),
        ]
        let batches = PageTranslate.batches(pieces)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].texts, ["Hello there", "Reply", "Above the screen"], "on screen first, in page order, then by distance")
        XCTAssertEqual(batches[0].nodes, [[1, 3], [2, 0], [5]], "the same words go back into every node that had them")
    }

    func testBatchesKeepTheirLimitsAndTheFirstIsSmall() {
        let short = (0..<30).map { PageTranslate.Piece(id: $0, text: "Words \($0)!", distance: 0) }
        XCTAssertEqual(PageTranslate.batches(short).map(\.texts.count), [24, 6], "24 texts at most")

        let paragraph = String(repeating: "palavra ", count: 40) // 320 letters
        let long = (0..<12).map { PageTranslate.Piece(id: $0, text: paragraph + "\($0)", distance: Double($0)) }
        let batches = PageTranslate.batches(long)
        XCTAssertLessThanOrEqual(batches[0].letters, PageTranslate.firstBatchLetters, "the screen's words come back soonest")
        XCTAssertTrue(batches.dropFirst().allSatisfy { $0.letters <= PageTranslate.batchLetters })
        XCTAssertEqual(batches.flatMap(\.nodes).flatMap { $0 }.sorted(), Array(0..<12), "every node once")

        let huge = [PageTranslate.Piece(id: 0, text: String(repeating: "a", count: 5000), distance: 0),
                    PageTranslate.Piece(id: 1, text: "after", distance: 0)]
        XCTAssertEqual(PageTranslate.batches(huge).map(\.texts.count), [1, 1], "a text longer than a batch goes alone")
        XCTAssertTrue(PageTranslate.batches([]).isEmpty)
    }

    // MARK: - the page script on a real document

    func testThePageScriptTranslatesTextNodesOnlyAndShowOriginalPutsEveryWordBack() async throws {
        let view = try await load(fixture: "lisboa-alfama")
        let before = try await page("document.body.innerHTML", in: view) as? String
        let probed = try await PageTranslation.call(PageTranslate.probe, [:], in: view)
        let probe = try XCTUnwrap(probed as? [String: Any])
        XCTAssertEqual(probe["lang"] as? String, "pt")
        XCTAssertTrue((probe["sample"] as? String ?? "").contains("Alfama"))
        let document = try XCTUnwrap(probe["documentID"] as? String)

        let found = try await PageTranslation.call(PageTranslate.collect, ["expectedDocument": document, "target": "en"], in: view)
        let pieces = PageTranslation.pieces(found)
        let texts = pieces.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        XCTAssertEqual(Set(texts).count, 23, "the article's 23 texts: \(texts)")
        XCTAssertFalse(texts.contains("Lisboa a Pé"), "translate=\"no\" stays")
        XCTAssertFalse(texts.contains { $0.contains("não traduzir") || $0.contains("código") }, "scripts and code stay")
        XCTAssertFalse(texts.contains("L"), "a lone initial is no words")
        XCTAssertEqual(pieces.filter { $0.distance == 0 }.first?.text.contains("Crónicas"), true, "the screen's words are marked")

        let translator = StandInTranslator()
        var applied = 0
        for batch in PageTranslate.batches(pieces) {
            let english = try await translator.translate(batch.texts, from: "pt", to: "en")
            applied += try await PageTranslation.call(PageTranslate.apply, ["expectedDocument": document, "nodes": batch.nodes, "texts": english], in: view) as? Int ?? 0
        }
        XCTAssertEqual(applied, pieces.count)
        let english = try await page("document.body.innerText", in: view) as? String ?? ""
        XCTAssertTrue(english.contains("Alfama, early in the morning"))
        XCTAssertTrue(english.contains("At seven in the morning, Alfama still belongs"))
        XCTAssertTrue(english.contains("Read next: The best viewpoints in Lisbon"), "words around a link keep their spaces")
        XCTAssertTrue(english.contains("Lisboa a Pé"))
        let lang = try await page("document.documentElement.lang", in: view) as? String
        XCTAssertEqual(lang, "en", "VoiceOver reads it as English")
        let paragraphs = try await page("document.querySelectorAll('p').length", in: view) as? Int
        XCTAssertEqual(paragraphs, 15, "no element made or lost")

        // Nothing new: nothing to collect again.
        let again = try await PageTranslation.call(PageTranslate.collect, ["expectedDocument": document, "target": "en"], in: view)
        XCTAssertTrue(PageTranslation.pieces(again).isEmpty)

        // The page writes over one translation: those are its own words now.
        _ = try await page("document.querySelector('h3').firstChild.nodeValue = 'Novo título'", in: view)
        let restored = try await PageTranslation.call(PageTranslate.restore, ["expectedDocument": document], in: view) as? Int
        XCTAssertEqual(restored, pieces.count - 1)
        _ = try await page("document.querySelector('h3').firstChild.nodeValue = 'Onde começar'", in: view)
        let after = try await page("document.body.innerHTML", in: view) as? String
        XCTAssertEqual(after, before, "every word back where it was")
        let langAfter = try await page("document.documentElement.lang", in: view) as? String
        XCTAssertEqual(langAfter, "pt")

        // Another document: the old one's id does nothing.
        let stale = try await PageTranslation.call(PageTranslate.restore, ["expectedDocument": "elsewhere"], in: view) as? Int
        XCTAssertEqual(stale, -1)
    }

    func testWordsThePageAddsLaterAreSeen() async throws {
        let view = try await load(fixture: "lisboa-alfama")
        let probed = try await PageTranslation.call(PageTranslate.probe, [:], in: view)
        let probe = try XCTUnwrap(probed as? [String: Any])
        let document = try XCTUnwrap(probe["documentID"] as? String)
        let first = try await PageTranslation.call(PageTranslate.collect, ["expectedDocument": document, "target": "en"], in: view)
        let translator = StandInTranslator()
        for batch in PageTranslate.batches(PageTranslation.pieces(first)) {
            let english = try await translator.translate(batch.texts, from: "pt", to: "en")
            _ = try await PageTranslation.call(PageTranslate.apply, ["expectedDocument": document, "nodes": batch.nodes, "texts": english], in: view)
        }
        let quiet = try await PageTranslation.call(PageTranslate.changed, ["expectedDocument": document], in: view) as? Bool
        XCTAssertEqual(quiet, false, "its own translations are no change")
        _ = try await page("var p = document.createElement('p'); p.textContent = 'Mais um comentário dos leitores'; document.querySelector('article').appendChild(p); 0", in: view)
        try await Task.sleep(for: .milliseconds(50))
        let changed = try await PageTranslation.call(PageTranslate.changed, ["expectedDocument": document], in: view) as? Bool
        XCTAssertEqual(changed, true)
        let found = try await PageTranslation.call(PageTranslate.collect, ["expectedDocument": document, "target": "en"], in: view)
        XCTAssertEqual(PageTranslation.pieces(found).map(\.text), ["Mais um comentário dos leitores"], "only the new words")
    }

    // MARK: - the whole flow in a test world

    func testOfferedTranslatedShownOriginalAndAlwaysForTheSite() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        let tab = try await openPortuguese(in: app)
        let offer = try XCTUnwrap(app.translation.page(tab.id), "a Portuguese page is offered")
        XCTAssertEqual(offer.source, "pt")
        XCTAssertEqual(offer.target, "en")
        XCTAssertEqual(offer.phase, .offered)
        XCTAssertEqual(TranslateWords.subtitle(offer), "This page is in Portuguese")
        XCTAssertNil(app.translation.plateWords(tab.id))

        app.pageMenuTranslate()
        try await waitFor { app.translation.page(tab.id)?.phase == .translated }
        XCTAssertEqual(app.translation.plateWords(tab.id), "Translated")
        let view = try XCTUnwrap(app.pages.liveView(tab.id))
        let english = try await page("document.body.innerText", in: view) as? String ?? ""
        XCTAssertTrue(english.contains("The sound of fado"))
        XCTAssertTrue(Haptics.played.suffix(3).map(\.reason).contains(Haptics.Reason.pageToggle))

        app.pageMenuTranslate() // Show Original
        try await waitFor { (try? await self.page("document.body.innerText", in: view) as? String)?.contains("O som do fado") == true }
        XCTAssertEqual(app.translation.page(tab.id)?.phase, .offered)

        // Always Translate Portuguese: remembered for the site, and the page translated now.
        app.pageMenuAlwaysTranslate()
        XCTAssertTrue(app.pageAlwaysTranslates)
        XCTAssertEqual(app.siteSettings.alwaysTranslates("lisboa-a-pe.pt", isPrivate: false), "pt")
        try await waitFor { app.translation.page(tab.id)?.phase == .translated }
        // Loaded again, the site's page translates by itself.
        app.pages.reload(tab.id)
        try await waitFor { app.translation.page(tab.id)?.phase == .translated }
        app.pageMenuAlwaysTranslate()
        XCTAssertFalse(app.pageAlwaysTranslates)
        XCTAssertNil(app.siteSettings.alwaysTranslates("lisboa-a-pe.pt", isPrivate: false))
    }

    func testEnglishPagesAreNotOffered() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        let url = URL(string: "https://uxmatters.com/thumb-zone-ten-years-later")!
        app.browser.open(PageFixtures.tab(for: url, in: app.world))
        let tab = try XCTUnwrap(app.browser.tab)
        try await show(tab, in: app)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(app.translation.page(tab.id), "an English article for an English reader")
    }

    func testPrivateTabsTranslateAndRememberApart() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        let tab = try await openPortuguese(in: app, privately: true)
        XCTAssertTrue(app.pageIsPrivate)
        XCTAssertNotNil(app.translation.page(tab.id), "private pages are offered too: nothing leaves this iPhone")
        app.pageMenuAlwaysTranslate()
        try await waitFor { app.translation.page(tab.id)?.phase == .translated }
        XCTAssertEqual(app.siteSettings.alwaysTranslates("lisboa-a-pe.pt", isPrivate: true), "pt")
        XCTAssertNil(app.siteSettings.alwaysTranslates("lisboa-a-pe.pt", isPrivate: false), "never the ordinary memory")
    }

    func testAFailedTranslationPutsThePageBackAndSaysSo() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.toastsStay = true
        let tab = try await openPortuguese(in: app)
        let failing = FailingTranslator()
        app.translation.engineOverride = failing
        app.translation.translate(tab.id)
        try await waitFor { app.translation.page(tab.id)?.phase == .offered }
        XCTAssertEqual(app.surfaces.toast?.text, "Couldn't translate this page")
        let view = try XCTUnwrap(app.pages.liveView(tab.id))
        let words = try await page("document.body.innerText", in: view) as? String ?? ""
        XCTAssertTrue(words.contains("Às sete da manhã"), "no half translated page")
    }

    // MARK: - a long article, measured

    /// 400 paragraphs and 40 headings, every one different (the worst case
    /// for the one-text-once rule): the page script's own costs, and how soon
    /// the screen is English with a model's latency per batch.
    func testMeasureALongArticle() async throws {
        let paragraphs = (try JSONDecoder().decode([String: [String: String]].self,
            from: Data(contentsOf: try XCTUnwrap(PageSchemeHandler.resources?.appendingPathComponent("Pages/translations.json")))))["pt-en"]!
            .keys.filter { $0.count > 120 }.sorted()
        var body = "<article><h1>Alfama, de manhã cedo</h1>"
        for i in 0..<400 {
            if i % 10 == 0 { body += "<h3>Parte \(i / 10 + 1) da crónica</h3>" }
            body += "<p>\(paragraphs[i % paragraphs.count]) (\(i))</p>"
        }
        body += "</article>"
        let html = "<!doctype html><html lang=\"pt\"><meta name=viewport content=\"width=device-width\"><body style=\"font:17px -apple-system;padding:20px\">\(body)</body></html>"
        let view = try await load(html: html)
        let letters = try await page("document.body.innerText.length", in: view) as? Int ?? 0

        let clock = ContinuousClock()
        var probe: [String: Any] = [:]
        let probing = try await clock.measure {
            probe = try await PageTranslation.call(PageTranslate.probe, [:], in: view) as? [String: Any] ?? [:]
        }
        let document = try XCTUnwrap(probe["documentID"] as? String)
        let detecting = clock.measure { _ = PageTranslate.recognize(probe["sample"] as? String ?? "") }
        var found: Any = NSNull()
        let collecting = try await clock.measure {
            found = try await PageTranslation.call(PageTranslate.collect, ["expectedDocument": document, "target": "en"], in: view)
        }
        let pieces = PageTranslation.pieces(found)
        var batches: [PageTranslate.Batch] = []
        let batching = clock.measure { batches = PageTranslate.batches(pieces) }
        XCTAssertEqual(pieces.count, 441, "400 paragraphs, 40 headings and the title")

        let translator = StandInTranslator()
        var applying: Duration = .zero
        var firstScreen: Duration?
        let whole = try await clock.measure {
            for batch in batches {
                let english = try await translator.translate(batch.texts, from: "pt", to: "en")
                applying += try await clock.measure {
                    _ = try await PageTranslation.call(PageTranslate.apply, ["expectedDocument": document, "nodes": batch.nodes, "texts": english], in: view)
                }
                if firstScreen == nil { firstScreen = applying }
            }
        }
        let restoring = try await clock.measure {
            _ = try await PageTranslation.call(PageTranslate.restore, ["expectedDocument": document], in: view)
        }

        // A model's latency: 250 ms a batch (an iPhone's on-device model
        // takes about that for 600 to 1600 letters), the screen after the first.
        let latency = 0.25
        let screenWithModel = latency + seconds(probing + collecting + (firstScreen ?? .zero))
        let wholeWithModel = Double(batches.count) * latency + seconds(probing + collecting + applying)

        let report = String(format: """
        translate.measure letters=%d texts=%d batches=%d probe=%.1fms recognize=%.1fms collect=%.1fms batch=%.2fms \
        apply=%.1fms (%.2fms a batch) firstScreen=%.1fms wholeStandIn=%.1fms restore=%.1fms \
        withModel250ms: screen=%.2fs whole=%.1fs
        """, letters, pieces.count, batches.count, ms(probing), ms(detecting), ms(collecting), ms(batching),
            ms(applying), ms(applying) / Double(max(1, batches.count)), ms(firstScreen ?? .zero), ms(whole), ms(restoring),
            screenWithModel, wholeWithModel)
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "translate-measure"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(ms(collecting), 500, "walking a long article stays well under half a second")
        XCTAssertLessThan(ms(applying) / Double(max(1, batches.count)), 50, "a batch back into the page is a frame or two")
    }

    // MARK: - helpers

    private func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
    private func seconds(_ d: Duration) -> Double { ms(d) / 1000 }

    private func waitFor(_ timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        let met = await condition()
        XCTAssertTrue(met, "timed out")
    }

    private func openPortuguese(in app: AppModel, privately: Bool = false) async throws -> Tab {
        let page = PageFixtures.tab(for: StateCatalog.translatePage, in: app.world)
        if privately { app.openPrivately(page) } else { app.browser.open(page) }
        let tab = try XCTUnwrap(app.browser.tab)
        XCTAssertEqual(tab.page, "lisboa-alfama")
        try await show(tab, in: app)
        try await waitFor { app.translation.page(tab.id) != nil }
        return tab
    }

    private func show(_ tab: Tab, in app: AppModel) async throws {
        let view = app.pages.activate(tab)
        view.frame = window.rootViewController!.view.bounds
        window.rootViewController!.view.addSubview(view)
        await app.pages.waitUntilPainted(tab.id, timeout: .seconds(10))
    }

    private func load(fixture stem: String) async throws -> WKWebView {
        let file = try XCTUnwrap(PageSchemeHandler.resources?.appendingPathComponent("Pages/\(stem).html"))
        return try await load(html: try String(contentsOf: file, encoding: .utf8))
    }

    private func load(html: String) async throws -> WKWebView {
        let view = WKWebView(frame: window.rootViewController!.view.bounds)
        window.rootViewController!.view.addSubview(view)
        let done = LoadWait()
        view.navigationDelegate = done
        view.loadHTMLString(html, baseURL: URL(string: "https://lisboa-a-pe.pt/"))
        try await done.wait()
        addTeardownBlock { @MainActor in view.removeFromSuperview() }
        return view
    }

    private func page(_ js: String, in view: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Any, Error>) in
            view.evaluateJavaScript(js) { result, error in
                if let error { reply.resume(throwing: error) } else { reply.resume(returning: result ?? NSNull()) }
            }
        }
    }
}

/// A translator whose model refuses.
@MainActor
private final class FailingTranslator: PageTranslating {
    struct Refused: Error {}
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] { throw Refused() }
}

@MainActor
private final class LoadWait: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
