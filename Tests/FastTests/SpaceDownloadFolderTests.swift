import AppKit
import Testing
import WebKit
@testable import Fast

/// Policy plus the real Browser download delegate and Hoard retry. The page
/// is an NSView-only engine fixture as in TabEngineTests, never a website.
@MainActor @Suite(.serialized)
struct SpaceDownloadFolderTests {
    private final class Page: NSView, PageHandle {
        let engine: PageEngineKind
        weak var events: (any PageEvents)?
        weak var stateEvents: (any PageStateEvents)?
        var url: URL?
        var committedURL: URL? { historyEntry?.url }
        var historyEntry: PageHistoryEntry?
        var title: String?
        var isLoading = false
        var estimatedProgress = 0.0
        var canGoBack = false
        var canGoForward = false
        var pageZoom: CGFloat = 1
        var magnification: CGFloat = 1
        var themeColor: NSColor?
        var lastInput: TimeInterval?
        var contentProcess: pid_t? { nil }
        var gpuProcess: pid_t? { nil }
        var captureStatus = PageCaptureStatus(camera: .none, microphone: .none, screen: .none)
        var requests: [URLRequest] = []
        var retired = false
        var reloads = 0
        var backs = 0
        var forwards = 0

        init(_ kind: PageEngineKind) { engine = kind; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func emit(_ state: PageStateChange) { stateEvents?.page(self, changed: state) }
        func navigate(to request: URLRequest) { requests.append(request) }
        func navigate(html: String, base: URL?) { }
        func reload(fromOrigin: Bool) { reloads += 1 }
        func stopLoading() { }
        func navigateBack() { backs += 1 }
        func navigateForward() { forwards += 1 }
        func retire(call: Bool, pictureInPicture: Bool) {
            retired = true
            stateEvents = nil
            events = nil
            removeFromSuperview()
        }
        func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) { done([]) }
        func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) { done(nil, PageShotFailed()) }
        func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) { done(.failure(PageShotFailed())) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) { done?(.success(nil)) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? { nil }
        func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool { false }
        func agentHover(x: Double, y: Double) -> Bool { false }
        func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func insertAgentText(_ text: String) { }
        func sendAgentKeys(_ strokes: [PageKey]) { }
        func setCameraCapture(_ state: PageMediaState) { }
        func setMicrophoneCapture(_ state: PageMediaState) { }
        func stopDisplayCapture() { }
        func killContent() { }
    }

    private final class Download: PageDownload {
        let downloadID = UUID()
        let originalRequest: URLRequest?
        let isUserInitiated = true
        let progress = Progress(totalUnitCount: 10)
        let page: (any PageHandle)?
        var sourceView: NSView? { page }
        var pageURL: URL? { page?.url }
        var pageTitle: String? { page?.title }
        weak var downloadEvents: (any PageDownloadEvents)?
        var replacement: Download?
        var receivedResume: Data?
        init(page: (any PageHandle)? = nil) {
            self.page = page
            originalRequest = URLRequest(url: URL(string: "https://space-download.invalid/" + UUID().uuidString)!)
        }
        func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) { done(nil) }
        func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                             done: @escaping @MainActor ((any PageDownload)?) -> Void) {
            receivedResume = resumeData
            done(replacement)
        }
    }

    @MainActor
    private final class World {
        let browser: Browser
        let work = UUID(), other = UUID()
        let root: URL
        let original: URL
        let custom: URL
        let changed: URL
        let tab: Tab
        let page: Page
        private let old: (URL, Bool, Bool, Bool)

        init() throws {
            try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
            _ = NSApplication.shared
            let browser = Browser(windowID: UUID())
            browser.lookForMailSignInLink = {}
            browser.dropSpare()
            let prefs = browser.prefs
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("space-download-" + UUID().uuidString)
            let page = Page(.webKit)
            page.url = URL(string: "owned-fixture:/origin")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let tab = Tab(configuration: configuration, factory: PageEngineFactory(kinds: [.webKit]) { _, _ in page })
            self.browser = browser; self.root = root; self.tab = tab; self.page = page
            old = (prefs.downloads, prefs.asksWhereToSave, prefs.usesSpaces, prefs.tidyDownloads)
            original = root.appendingPathComponent("general", isDirectory: true)
            custom = root.appendingPathComponent("work", isDirectory: true)
            changed = root.appendingPathComponent("other", isDirectory: true)
            var ready = false
            defer { if !ready { close() } }
            for folder in [original, custom, changed] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            prefs.downloads = original; prefs.asksWhereToSave = false; prefs.usesSpaces = true; prefs.tidyDownloads = false
            browser.spaces = [Space(id: work, name: "Work", icon: "", ownSignIns: false),
                              Space(id: other, name: "Other", icon: "", ownSignIns: false)]
            browser.spaceID = work
            tab.restore(url: page.url!, title: "Owned source")
            browser.lay([tab])
            try #require(tab.page === page && tab.built == nil, "No native engine or website is started")
            DownloadFolder.set(custom, for: work)
            ready = true
        }

        func moveAway() {
            browser.parked[work] = Parked(tabs: [tab], active: nil)
            browser.lay([])
            browser.spaceID = other
        }

        func close() {
            for fetch in browser.hoard.fetches { browser.hoard.dismiss(fetch) }
            browser.discardUnfinishedDownloads()
            browser.downloading.forEach { $0.downloadEvents = nil }
            browser.downloading = []
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.dropSpare()
            (browser.tabs + browser.parkedTabs + browser.outside + [tab]).forEach { $0.close() }
            DownloadFolder.set(nil, for: work); DownloadFolder.set(nil, for: other)
            browser.prefs.downloads = old.0; browser.prefs.asksWhereToSave = old.1
            browser.prefs.usesSpaces = old.2; browser.prefs.tidyDownloads = old.3
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func destination(_ download: Download, in browser: Browser, name: String = "fixture.bin") async throws -> URL {
        let response = URLResponse(url: try #require(download.originalRequest?.url),
                                   mimeType: "application/octet-stream", expectedContentLength: 10, textEncodingName: nil)
        var answered = false
        var result: URL?
        browser.download(download, decideDestinationUsing: response, suggestedFilename: name) {
            #expect(!answered, "The production destination callback must answer exactly once")
            answered = true; result = $0
        }
        for _ in 0..<600 where !answered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(answered, "A timeout is a failed fixture, never routing proof")
        let staging = try #require(result)
        let part = try #require(browser.downloadParts[ObjectIdentifier(download)])
        #expect(staging == part.staging)
        #expect(staging != part.destination, "The engine only writes its owned staging file")
        return part.destination
    }

    @Test func localPreferenceInheritsPersistsAndResetsByStableID() throws {
        let name = "space-folder-policy-" + UUID().uuidString
        let store = try #require(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let work = UUID(), other = UUID()
        let global = URL(fileURLWithPath: "/synthetic/general", isDirectory: true)
        let custom = URL(fileURLWithPath: "/synthetic/work", isDirectory: true)
        let later = URL(fileURLWithPath: "/synthetic/new-general", isDirectory: true)
        #expect(DownloadFolder.destination(for: work, fallback: global, store: store) == global)
        DownloadFolder.set(custom, for: work, store: store)
        let reloaded = try #require(UserDefaults(suiteName: name))
        #expect(DownloadFolder.custom(for: work, store: reloaded) == custom)
        #expect(DownloadFolder.destination(for: other, fallback: later, store: store) == later)
        #expect(DownloadFolder.destination(for: nil, fallback: later, store: store) == later)
        DownloadFolder.set(nil, for: work, store: store)
        #expect(DownloadFolder.destination(for: work, fallback: later, store: store) == later)
        store.set("relative/folder", forKey: DownloadFolder.key(for: work))
        #expect(DownloadFolder.destination(for: work, fallback: global, store: store) == global)
    }

    @Test func actualDownloadKeepsItsCapturedFolderAcrossSpaceAndPreferenceChanges() async throws {
        let world = try World(); defer { world.close() }
        let download = Download(page: world.page)
        world.browser.keep(download)
        world.moveAway()
        DownloadFolder.set(world.changed, for: world.work)
        world.browser.prefs.downloads = world.changed
        let file = try await destination(download, in: world.browser)
        #expect(file.deletingLastPathComponent().standardizedFileURL == world.custom.standardizedFileURL)
        #expect(world.browser.downloadFiles[ObjectIdentifier(download)] == file)
        world.browser.discardPart(of: ObjectIdentifier(download))
        #expect(world.browser.downloadFolders[ObjectIdentifier(download)] == nil)
    }

    @Test func parkedAndPeekSourcesUseTheirActualSpaceButUnknownSourcesUseGeneral() async throws {
        let world = try World(); defer { world.close() }
        world.moveAway()
        let parked = Download(page: world.page)
        let parkedFile = try await destination(parked, in: world.browser)
        #expect(parkedFile.deletingLastPathComponent().standardizedFileURL == world.custom.standardizedFileURL)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let peekPage = Page(.webKit)
        let peek = Tab(configuration: configuration, factory: PageEngineFactory(kinds: [.webKit]) { _, _ in peekPage })
        peek.from = world.tab.id
        world.browser.outside.append(peek)
        _ = peek.page
        let peekFile = try await destination(Download(page: peekPage), in: world.browser)
        #expect(peekFile.deletingLastPathComponent().standardizedFileURL == world.custom.standardizedFileURL)
        DownloadFolder.set(world.changed, for: world.other)
        let unknown = try await destination(Download(), in: world.browser)
        #expect(unknown.deletingLastPathComponent().standardizedFileURL == world.original.standardizedFileURL)
        world.browser.prefs.usesSpaces = false
        #expect(world.browser.downloadFolder(for: world.tab) == world.original)
    }

    @Test func actualAskBranchStartsAtTheSpaceFolderAndHonorsTheExplicitChoice() async throws {
        let world = try World(); defer { world.close() }
        world.browser.prefs.asksWhereToSave = true
        var offered: URL?
        let chosen = world.changed.appendingPathComponent("chosen.bin")
        world.browser.chooseDownloadLocation = { name, folder in
            #expect(name == "fixture.bin"); offered = folder; return chosen
        }
        let download = Download(page: world.page)
        let file = try await destination(download, in: world.browser)
        #expect(offered == world.custom)
        #expect(file == chosen && world.browser.downloadFiles[ObjectIdentifier(download)] == chosen)
        var canceled = false
        world.browser.chooseDownloadLocation = { _, _ in nil }
        let second = Download(page: world.page)
        world.browser.download(second, decideDestinationUsing: URLResponse(), suggestedFilename: "canceled.bin") {
            #expect($0 == nil); canceled = true
        }
        #expect(canceled && world.browser.downloadFiles[ObjectIdentifier(second)] == nil)
        #expect(world.browser.downloadFolders[ObjectIdentifier(second)] == nil)
    }

    @Test(arguments: [false, true])
    func actualRetryRetainsTheOriginalDestinationWhenItsTabIsNoLongerOwned(resumable: Bool) async throws {
        let world = try World(); defer { world.close() }
        let download = Download(page: world.page)
        world.browser.keep(download)
        let file = try await destination(download, in: world.browser)
        let part = try #require(world.browser.downloadParts[ObjectIdentifier(download)])
        try Data("partial".utf8).write(to: part.staging)
        let resume = resumable ? Data("owned-resume".utf8) : nil
        world.browser.download(download, didFailWithError: URLError(.networkConnectionLost), resumeData: resume)
        let fetch = try #require(world.browser.hoard.fetches.first { $0.id == ObjectIdentifier(download) })
        world.moveAway()
        world.browser.parked = [:]
        DownloadFolder.set(world.changed, for: world.work)
        world.browser.prefs.downloads = world.changed
        let next = Download()
        download.replacement = next
        world.browser.hoard.retry(fetch)
        #expect(download.receivedResume == resume)
        #expect(world.browser.downloadFolders[ObjectIdentifier(download)] == nil)
        #expect(world.browser.downloadFolders[ObjectIdentifier(next)] == world.custom)
        if resumable {
            #expect(world.browser.downloadFiles[ObjectIdentifier(next)] == file)
            #expect(world.browser.downloadParts[ObjectIdentifier(next)]?.staging == part.staging)
            #expect(FileManager.default.fileExists(atPath: part.staging.path))
        } else {
            #expect(!FileManager.default.fileExists(atPath: part.staging.path))
            let restarted = try await destination(next, in: world.browser)
            #expect(restarted.deletingLastPathComponent().standardizedFileURL == world.custom.standardizedFileURL)
        }
    }

    @Test func anUnavailableOverrideUsesExistingSafeFallbackWithoutForgettingTheChoice() async throws {
        let world = try World(); defer { world.close() }
        let blocker = world.root.appendingPathComponent("not-a-directory")
        try Data("owned fixture".utf8).write(to: blocker)
        let blocked = blocker.appendingPathComponent("folder", isDirectory: true)
        DownloadFolder.set(blocked, for: world.work)
        let file = try await destination(Download(page: world.page), in: world.browser)
        #expect(file.deletingLastPathComponent().standardizedFileURL == DownloadFolder.own.standardizedFileURL)
        #expect(DownloadFolder.custom(for: world.work) == blocked)
    }

    @Test func aMissingOverrideIsCreatedBeforeTheDestinationIsAnswered() async throws {
        let world = try World(); defer { world.close() }
        let missing = world.root.appendingPathComponent("missing/nested", isDirectory: true)
        DownloadFolder.set(missing, for: world.work)
        let file = try await destination(Download(page: world.page), in: world.browser)
        #expect(file.deletingLastPathComponent().standardizedFileURL == missing.standardizedFileURL)
        try Data("complete fixture".utf8).write(to: file)
        #expect(try Data(contentsOf: file) == Data("complete fixture".utf8))
    }
}
