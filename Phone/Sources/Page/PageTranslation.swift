import SwiftUI
import Translation
import WebKit
import os

/// Translate page: each tab's page is looked at once it has loaded, and when
/// its language is none of the person's the page menu offers Translate. The
/// page is translated where it is, on this iPhone (Apple's Translation, the
/// languages downloaded once with iOS's own sheet), what is on screen first,
/// a batch at a time; the plate says "Translating…" under the address, then
/// "Translated". Show Original puts every word back. Always Translate is
/// remembered per site and language (SiteSettings; a private tab's in memory
/// only). Words the page adds later (a feed, replies) are translated too
/// while the page stays translated. Test worlds translate with a stand-in
/// that knows its fixture's English (Pages/translations.json), since the
/// simulator has no translation models.
@MainActor
@Observable
final class PageTranslation {
    enum Phase: Equatable, Sendable {
        case offered
        /// `done` of `total` batches back in the page.
        case translating(done: Int, total: Int)
        case translated
    }

    struct Page: Equatable, Sendable {
        var source: String
        var target: String
        /// The document the offer is about (the page script's own id).
        var document: String
        var phase: Phase

        var sourceName: String { PageTranslate.name(source) }
        var targetName: String { PageTranslate.name(target) }
        var isTranslating: Bool { if case .translating = phase { true } else { false } }
        /// Done so far, 0 to 1, for the menu's words.
        var progress: Double {
            guard case let .translating(done, total) = phase, total > 0 else { return 0 }
            return Double(done) / Double(total)
        }
    }

    /// Who translates: Apple's models on this iPhone, or the test worlds' stand-in.
    enum Engine {
        case apple
        case standIn(StandInTranslator)
    }

    private(set) var pages: [Tab.ID: Page] = [:]
    /// What TranslationHost asks a session for when the languages aren't on
    /// this iPhone yet (iOS asks to download them first).
    private(set) var configuration: TranslationSession.Configuration?

    let engine: Engine
    /// The person's languages, the first one what pages are translated into.
    @ObservationIgnored var preferred: [String]
    /// Tests: this translator instead of the engine's.
    @ObservationIgnored var engineOverride: (any PageTranslating)?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var checked: Set<Tab.ID> = []
    @ObservationIgnored private var detecting: [Tab.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var jobs: [Tab.ID: Job] = [:]
    /// Jobs waiting for TranslationHost's session.
    @ObservationIgnored private var waiting: [Job] = []
    @ObservationIgnored private var watchers: [Tab.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "translate")

    /// One translation of one document; a later one, or Show Original, cancels it.
    @MainActor
    final class Job {
        let tab: Tab.ID
        let document: String
        let source: String
        let target: String
        /// Words the page added to a translated page: the phase stays.
        let catchUp: Bool
        var cancelled = false

        init(tab: Tab.ID, document: String, source: String, target: String, catchUp: Bool) {
            self.tab = tab; self.document = document; self.source = source; self.target = target; self.catchUp = catchUp
        }
    }

    init(app: AppModel?, engine: Engine? = nil, preferred: [String]? = nil) {
        self.app = app
        let fixtures = app?.fixturesEnabled ?? true
        self.engine = engine ?? (fixtures ? .standIn(StandInTranslator()) : .apple)
        // Test worlds read English whatever the simulator's languages are.
        self.preferred = preferred ?? (fixtures || LaunchOptions.current.isTestRun ? ["en-US"] : Locale.preferredLanguages)
    }

    func page(_ id: Tab.ID?) -> Page? { id.flatMap { pages[$0] } }

    /// The plate's line under the address while a page is or has been translated.
    func plateWords(_ id: Tab.ID?) -> String? {
        switch page(id)?.phase {
        case .translating: "Translating…"
        case .translated: "Translated"
        default: nil
        }
    }

    // MARK: - looking at pages

    /// A tab's page said how it is (WebPool's state): a new page is looked
    /// at once it has loaded; one going away takes its translation with it.
    func pageChanged(_ id: Tab.ID, _ state: WebPool.PageState) {
        guard let app else { return }
        if state.isLoading || state.failure != nil || !app.pages.isLive(id) {
            forget(id)
            return
        }
        guard !checked.contains(id), detecting[id] == nil else { return }
        detect(id)
    }

    /// Everything about a tab's page: it loads another, or its view went.
    func forget(_ id: Tab.ID) {
        checked.remove(id)
        detecting.removeValue(forKey: id)?.task.cancel()
        jobs.removeValue(forKey: id)?.cancelled = true
        waiting.removeAll { $0.tab == id }
        watchers.removeValue(forKey: id)?.cancel()
        if pages[id] != nil { pages[id] = nil }
    }

    private func detect(_ id: Tab.ID) {
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            // The page settles first; a redirect is a new page anyway.
            try? await Task.sleep(for: .milliseconds(Motion.disabled ? 30 : 350))
            await self?.look(at: id)
            if self?.detecting[id]?.token == token { self?.detecting[id] = nil }
        }
        detecting[id] = (token, task)
    }

    private func look(at id: Tab.ID) async {
        guard !Task.isCancelled, let app, let view = app.pages.liveView(id), !view.isLoading,
              let scheme = view.url?.scheme?.lowercased(),
              ["http", "https", PageSchemeHandler.scheme].contains(scheme) else { return }
        checked.insert(id)
        guard let result = try? await Self.call(PageTranslate.probe, [:], in: view) as? [String: Any],
              let document = result["documentID"] as? String,
              !Task.isCancelled, app.pages.liveView(id) === view else { return }
        let (hypotheses, letters) = PageTranslate.recognize(result["sample"] as? String ?? "")
        let source = PageTranslate.source(declared: result["lang"] as? String, hypotheses: hypotheses, letters: letters)
        log.info("page language: \(source ?? "unknown", privacy: .public), \(letters) letters")
        guard let source, PageTranslate.offers(source: source, preferred: preferred),
              let target = PageTranslate.target(preferred: preferred),
              await supports(source, target),
              !Task.isCancelled, app.pages.liveView(id) === view, checked.contains(id) else { return }
        pages[id] = Page(source: source, target: target, document: document, phase: .offered)
        if alwaysTranslates(id) == source { translate(id) }
    }

    private func supports(_ source: String, _ target: String) async -> Bool {
        switch engine {
        case .standIn: return true
        case .apple:
            let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                             to: Locale.Language(identifier: target))
            return status != .unsupported
        }
    }

    /// The language this tab's site is always translated from, if any.
    func alwaysTranslates(_ id: Tab.ID) -> String? {
        guard let app, let tab = app.browser.tab(id) else { return nil }
        let isPrivate = tab.isPrivate || app.browser.space(holding: id)?.isPrivate == true
        return app.siteSettings.alwaysTranslates(app.siteHost(of: tab), isPrivate: isPrivate)
    }

    // MARK: - translating

    /// Translate: the page's words in batches, what is on screen first.
    func translate(_ id: Tab.ID) {
        guard var page = pages[id], page.phase == .offered else { return }
        let job = Job(tab: id, document: page.document, source: page.source, target: page.target, catchUp: false)
        jobs[id]?.cancelled = true
        jobs[id] = job
        page.phase = .translating(done: 0, total: 0)
        pages[id] = page
        start(job)
    }

    /// Show Original: whatever is under way stops, every word goes back.
    func showOriginal(_ id: Tab.ID) {
        guard var page = pages[id], page.phase != .offered else { return }
        jobs.removeValue(forKey: id)?.cancelled = true
        waiting.removeAll { $0.tab == id }
        watchers.removeValue(forKey: id)?.cancel()
        page.phase = .offered
        pages[id] = page
        restore(id, document: page.document)
    }

    private func restore(_ id: Tab.ID, document: String) {
        guard let view = app?.pages.liveView(id) else { return }
        Task { @MainActor in
            _ = try? await Self.call(PageTranslate.restore, ["expectedDocument": document], in: view)
        }
    }

    private func start(_ job: Job) {
        if let translator = engineOverride {
            Task { @MainActor [weak self] in await self?.run(job, with: translator) }
            return
        }
        switch engine {
        case let .standIn(translator):
            Task { @MainActor [weak self] in await self?.run(job, with: translator) }
        case .apple:
            Task { @MainActor [weak self] in
                guard let self else { return }
                let source = Locale.Language(identifier: job.source), target = Locale.Language(identifier: job.target)
                if await LanguageAvailability().status(from: source, to: target) == .installed {
                    await self.run(job, with: AppleTranslator(TranslationSession(installedSource: source, target: target)))
                } else {
                    // Not on this iPhone yet: TranslationHost's session, after iOS's own download sheet.
                    self.waiting.append(job)
                    self.askForSession(source: source, target: target)
                }
            }
        }
    }

    private func askForSession(source: Locale.Language, target: Locale.Language) {
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// TranslationHost has a session: the jobs waiting for its languages
    /// run in it, one after another; the next pair asks for its own.
    func serve(_ session: TranslationSession) async {
        let translator = AppleTranslator(session)
        func matches(_ job: Job) -> Bool {
            session.sourceLanguage.map(\.minimalIdentifier) == Locale.Language(identifier: job.source).minimalIdentifier
                && session.targetLanguage.map(\.minimalIdentifier) == Locale.Language(identifier: job.target).minimalIdentifier
        }
        while let index = waiting.firstIndex(where: matches) {
            let job = waiting.remove(at: index)
            await run(job, with: translator)
        }
        if let next = waiting.first {
            askForSession(source: Locale.Language(identifier: next.source), target: Locale.Language(identifier: next.target))
        }
    }

    private func current(_ job: Job, _ view: WKWebView) -> Bool {
        !job.cancelled && jobs[job.tab] === job && app?.pages.liveView(job.tab) === view && pages[job.tab]?.document == job.document
    }

    private func run(_ job: Job, with translator: any PageTranslating) async {
        guard let app, let view = app.pages.liveView(job.tab), current(job, view) else { return }
        let started = Date()
        let found = try? await Self.call(PageTranslate.collect, ["expectedDocument": job.document, "target": job.target], in: view)
        guard current(job, view) else { return }
        let batches = PageTranslate.batches(Self.pieces(found))
        if !job.catchUp { set(job.tab, .translating(done: 0, total: batches.count)) }
        do {
            for (index, batch) in batches.enumerated() {
                let texts = try await translator.translate(batch.texts, from: job.source, to: job.target)
                guard current(job, view) else { return }
                _ = try await Self.call(PageTranslate.apply, ["expectedDocument": job.document, "nodes": batch.nodes, "texts": texts], in: view)
                guard current(job, view) else { return }
                if !job.catchUp { set(job.tab, .translating(done: index + 1, total: batches.count)) }
            }
        } catch {
            guard current(job, view) else { return }
            failed(job, error)
            return
        }
        jobs[job.tab] = nil
        set(job.tab, .translated)
        log.info("translated \(batches.count) batches in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        follow(job.tab)
    }

    private func set(_ id: Tab.ID, _ phase: Phase) {
        guard var page = pages[id], page.phase != phase else { return }
        page.phase = phase
        pages[id] = page
    }

    /// The models said no (or the download was refused): the page goes back
    /// to its own words and a word says why; canceling says nothing.
    private func failed(_ job: Job, _ error: Error) {
        log.error("translation failed: \(String(describing: error), privacy: .public)")
        jobs[job.tab] = nil
        watchers.removeValue(forKey: job.tab)?.cancel()
        guard var page = pages[job.tab] else { return }
        page.phase = .offered
        pages[job.tab] = page
        restore(job.tab, document: job.document)
        if error is CancellationError { return }
        if app?.browser.tab?.id == job.tab { app?.say("Couldn't translate this page", glyph: .translate) }
    }

    /// A translated page in front is asked now and then whether it added
    /// words; new ones are translated as the rest were.
    private func follow(_ id: Tab.ID) {
        watchers[id]?.cancel()
        watchers[id] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard !Task.isCancelled, let self, let app = self.app, let page = self.pages[id], page.phase == .translated,
                      let view = app.pages.liveView(id) else { return }
                guard app.browser.tab?.id == id, self.jobs[id] == nil else { continue }
                guard (try? await Self.call(PageTranslate.changed, ["expectedDocument": page.document], in: view)) as? Bool == true,
                      self.pages[id] == page else { continue }
                let job = Job(tab: id, document: page.document, source: page.source, target: page.target, catchUp: true)
                self.jobs[id] = job
                self.start(job)
            }
        }
    }

    // MARK: - the page script

    static func pieces(_ found: Any?) -> [PageTranslate.Piece] {
        guard let rows = found as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count >= 3, let id = (row[0] as? NSNumber)?.intValue, let text = row[1] as? String else { return nil }
            return PageTranslate.Piece(id: id, text: text, distance: (row[2] as? NSNumber)?.doubleValue ?? 1e9)
        }
    }

    /// Runs one of PageTranslate's scripts in Yab's own world on the page.
    static func call(_ script: String, _ arguments: [String: Any], in view: WKWebView) async throws -> Any {
        // The completion overload returns JS values on both SDKs.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            view.callAsyncJavaScript(script, arguments: arguments, in: nil, in: PageTranslate.world) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - test states

    /// Named states: the stand-in stops after `batches` batches until told
    /// to go on, so a page can be pictured part way.
    func holdStandIn(after batches: Int?) {
        if case let .standIn(translator) = engine { translator.hold = batches }
    }
}

/// Who turns texts into the target language, in order.
@MainActor
protocol PageTranslating: AnyObject {
    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String]
}

/// Apple's on-device models, through a session TranslationHost or iOS gave.
@MainActor
final class AppleTranslator: PageTranslating {
    private let session: TranslationSession

    init(_ session: TranslationSession) { self.session = session }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        let requests = texts.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
        let responses = try await session.translations(from: requests)
        var out = texts
        for response in responses {
            if let index = response.clientIdentifier.flatMap(Int.init), out.indices.contains(index) { out[index] = response.targetText }
        }
        return out
    }
}

/// Test worlds' translator: the fixtures' own English (Pages/translations.json),
/// anything else marked as translated, at once or after `delay`.
@MainActor
final class StandInTranslator: PageTranslating {
    private let known: [String: [String: String]]
    /// Each batch waits this long, as a model would (measurements).
    var delay: Duration = .zero
    /// Stops after this many batches until `resume()` (named states).
    var hold: Int?
    private(set) var batches = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(known: [String: [String: String]]? = nil) {
        if let known {
            self.known = known
        } else if let url = PageSchemeHandler.resources?.appendingPathComponent("Pages/translations.json"),
                  let data = try? Data(contentsOf: url),
                  let table = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            self.known = table
        } else {
            self.known = [:]
        }
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        if let hold, batches >= hold {
            await withCheckedContinuation { held.append($0) }
        }
        batches += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        let table = known["\(source)-\(target)"] ?? [:]
        return texts.map { table[$0] ?? "[\(target)] \($0)" }
    }

    func resume() {
        hold = nil
        let waiting = held
        held = []
        waiting.forEach { $0.resume() }
    }
}

/// Where Apple's translation gets a session for languages not on this
/// iPhone yet: iOS shows its download sheet from here, then the session
/// translates what waited for it. Always in the view tree, drawing nothing.
struct TranslationHost: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(app.translation.configuration) { session in
                await app.translation.serve(session)
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
