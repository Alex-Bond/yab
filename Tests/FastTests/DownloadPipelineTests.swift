import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct DownloadPipelineTests {
    private final class Download: PageDownload {
        let downloadID = UUID()
        let originalRequest: URLRequest? = URLRequest(url: URL(string: "https://download.invalid/same.bin")!)
        let isUserInitiated = true
        var isExtensionDownload = false
        var publication: ((URL) async throws -> Void)?
        let progress = Progress(totalUnitCount: 10)
        var page: (any PageHandle)? { nil }
        let view: NSView
        var sourceView: NSView? { view }
        var pageURL: URL? { URL(string: "https://origin.invalid/page") }
        var pageTitle: String? { "Origin" }
        weak var downloadEvents: (any PageDownloadEvents)?
        var replacement: Download?
        var retries = 0
        init(view: NSView? = nil) {
            self.view = view ?? NSView(frame: .zero)
            // Real pages clear this counter when they commit. A new mock
            // page must not inherit a deallocated view's reused address.
            if view == nil { SiteDownloads.committed(self.view) }
        }
        func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) { done(nil) }
        func didPublish(to file: URL) async throws { try await publication?(file) }
        func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                             done: @escaping @MainActor ((any PageDownload)?) -> Void) {
            retries += 1; done(replacement)
        }
    }

    @MainActor private final class World {
        let browser: Browser
        let root: URL
        let old: (URL, Bool, Bool)
        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            browser = Browser(windowID: UUID())
            browser.dropSpare(); browser.lay([]); browser.activeID = nil
            root = FileManager.default.temporaryDirectory.appendingPathComponent("download-pipeline-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            old = (browser.prefs.downloads, browser.prefs.asksWhereToSave, browser.prefs.tidyDownloads)
            browser.prefs.downloads = root; browser.prefs.asksWhereToSave = false; browser.prefs.tidyDownloads = false
        }
        func close() {
            browser.discardUnfinishedDownloads()
            for fetch in browser.hoard.fetches { browser.hoard.dismiss(fetch) }
            browser.downloading = []
            browser.dropSpare(); browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            browser.prefs.downloads = old.0; browser.prefs.asksWhereToSave = old.1; browser.prefs.tidyDownloads = old.2
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://download.invalid/same.bin")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream"])!
    }

    private func destination(_ download: Download, _ browser: Browser, suggested: String = "same.bin") async throws -> URL {
        var answered = false, result: URL?
        browser.download(download, decideDestinationUsing: response(), suggestedFilename: suggested) {
            #expect(!answered); answered = true; result = $0
        }
        for _ in 0..<600 where !answered { try await Task.sleep(for: .milliseconds(10)) }
        try #require(answered)
        return try #require(result)
    }

    private func settle(_ browser: Browser, _ download: Download) async throws {
        for _ in 0..<600 where !browser.completedDownloadIDs.contains(download.downloadID)
            && !browser.failedDownloadIDs.contains(download.downloadID) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(browser.completedDownloadIDs.contains(download.downloadID) || browser.failedDownloadIDs.contains(download.downloadID))
    }

    @Test func explicitSavePanelReplacementPublishesCompleteBytes() async throws {
        let world = try World(); defer { world.close() }
        let target = world.root.appendingPathComponent("existing.bin")
        try Data("old".utf8).write(to: target)
        world.browser.prefs.asksWhereToSave = true
        world.browser.chooseDownloadLocation = { _, _, done in done(target) }
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        try Data("replacement".utf8).write(to: staging)
        // The existing file survives the entire transfer until completion.
        #expect(try Data(contentsOf: target) == Data("old".utf8))
        world.browser.downloadDidFinish(download)
        try await settle(world.browser, download)
        #expect(world.browser.completedDownloadIDs.contains(download.downloadID))
        #expect(!world.browser.failedDownloadIDs.contains(download.downloadID))
        #expect(try Data(contentsOf: target) == Data("replacement".utf8))
    }

    @Test func simultaneousSameURLDownloadsReserveDifferentNamesBeforeAnyFileExists() async throws {
        let world = try World(); defer { world.close() }
        let first = Download(), second = Download()
        world.browser.keep(first); world.browser.keep(second); world.browser.keep(first)
        #expect(world.browser.downloading.count == 2)
        let a = try await destination(first, world.browser), b = try await destination(second, world.browser)
        let finalA = try #require(world.browser.downloadFiles[ObjectIdentifier(first)])
        let finalB = try #require(world.browser.downloadFiles[ObjectIdentifier(second)])
        #expect(a != b && finalA != finalB && finalA.lastPathComponent == "same.bin" && finalB.lastPathComponent == "same 2.bin")
        #expect(!FileManager.default.fileExists(atPath: finalA.path) && !FileManager.default.fileExists(atPath: finalB.path))
        try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b)
        world.browser.downloadDidFinish(first); world.browser.downloadDidFinish(second)
        try await settle(world.browser, first); try await settle(world.browser, second)
        #expect(try Data(contentsOf: finalA) == Data("first".utf8))
        #expect(try Data(contentsOf: finalB) == Data("second".utf8))
        #expect(world.browser.downloading.isEmpty && world.browser.downloadParts.isEmpty)
    }

    @Test func requestedNamesBelongToEachTransferEvenWhenTheURLsAndRedirectsMatch() async throws {
        let world = try World(); defer { world.close() }
        let first = Download(), second = Download()
        world.browser.keep(first); world.browser.keep(second)
        world.browser.downloadNames[ObjectIdentifier(first)] = "first.png"
        world.browser.downloadNames[ObjectIdentifier(second)] = "second.png"
        _ = try await destination(first, world.browser)
        _ = try await destination(second, world.browser)
        #expect(world.browser.downloadFiles[ObjectIdentifier(first)]?.lastPathComponent == "first.png")
        #expect(world.browser.downloadFiles[ObjectIdentifier(second)]?.lastPathComponent == "second.png")
        #expect(world.browser.downloadNames.isEmpty)
    }

    @Test func completionWaitsForTheNativeJournalAndKeepsPublishedBytesOnRejection() async throws {
        let world = try World(); defer { world.close() }
        let download = Download(); download.isExtensionDownload = true
        var acknowledge: CheckedContinuation<Void, any Error>?
        var published: URL?
        download.publication = { file in
            published = file
            try await withCheckedThrowingContinuation { acknowledge = $0 }
        }
        world.browser.keep(download)
        let staging = try await destination(download, world.browser, suggested: "Pictures/original.bin")
        let bytes = Data("complete original file".utf8)
        try bytes.write(to: staging)
        world.browser.downloadDidFinish(download)
        for _ in 0..<600 where acknowledge == nil { try await Task.sleep(for: .milliseconds(10)) }
        let file = try #require(published)
        #expect(file == world.root.appendingPathComponent("Pictures/original.bin"))
        #expect(try Data(contentsOf: file) == bytes)
        #expect(!world.browser.completedDownloadIDs.contains(download.downloadID))
        acknowledge?.resume(throwing: CocoaError(.fileWriteUnknown))
        try await settle(world.browser, download)
        #expect(world.browser.failedDownloadIDs.contains(download.downloadID))
        #expect(!world.browser.completedDownloadIDs.contains(download.downloadID))
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func nativePublicationAcknowledgmentPrecedesCompletedDownload() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        var acknowledge: CheckedContinuation<Void, any Error>?
        download.publication = { file in
            #expect(FileManager.default.fileExists(atPath: file.path))
            try await withCheckedThrowingContinuation { acknowledge = $0 }
        }
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        try Data("complete".utf8).write(to: staging)
        world.browser.downloadDidFinish(download)
        for _ in 0..<600 where acknowledge == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!world.browser.completedDownloadIDs.contains(download.downloadID))
        try #require(acknowledge).resume()
        try await settle(world.browser, download)
        #expect(world.browser.completedDownloadIDs.contains(download.downloadID))
    }

    @Test(arguments: [401, 403, 404, 500])
    func HTTPFailuresBeforeTheDestinationRetainARetryAndNeverSaveAnErrorPage(status: Int) throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        var answered = 0
        world.browser.download(download, decideDestinationUsing: response(status), suggestedFilename: "same.bin") {
            answered += 1; #expect($0 == nil)
        }
        let fetch = try #require(world.browser.hoard.fetches.first)
        #expect(answered == 1 && fetch.failed && world.browser.hoard.unseen)
        #expect(world.browser.downloadFiles.isEmpty && world.browser.downloadParts.isEmpty)
        world.browser.hoard.retry(fetch)
        #expect(download.retries == 1)
    }

    @Test func networkFailureBeforeAnyResponseCanRetryImmediately() async throws {
        let world = try World(); defer { world.close() }
        let download = Download(), replacement = Download()
        world.browser.keep(download)
        world.browser.download(download, didFailWithError: URLError(.cannotFindHost), resumeData: nil)
        let fetch = try #require(world.browser.hoard.fetches.first)
        download.replacement = replacement
        world.browser.hoard.retry(fetch)
        let staging = try await destination(replacement, world.browser)
        try Data("retried".utf8).write(to: staging)
        world.browser.downloadDidFinish(replacement)
        try await settle(world.browser, replacement)
        #expect(try Data(contentsOf: world.root.appendingPathComponent("same.bin")) == Data("retried".utf8))
    }

    @Test(arguments: [false, true])
    func retryBeforeAnyResponseUsesTheServerFilenameUnlessOneWasExplicitlyRequested(explicit: Bool) async throws {
        let world = try World(); defer { world.close() }
        let first = Download(), next = Download(view: first.view)
        first.replacement = next
        if explicit { world.browser.downloadNames[ObjectIdentifier(first)] = "chosen.dmg" }
        world.browser.keep(first)
        world.browser.download(first, didFailWithError: URLError(.cannotFindHost), resumeData: nil)
        let failed = try #require(world.browser.hoard.fetches.first)
        world.browser.hoard.retry(failed)
        _ = try await destination(next, world.browser, suggested: "installer.dmg")
        #expect(world.browser.downloadFiles[ObjectIdentifier(next)]?.lastPathComponent == (explicit ? "chosen.dmg" : "installer.dmg"))
        #expect(world.browser.downloadNames[ObjectIdentifier(first)] == nil)
    }

    @Test func retryInTheSamePageDoesNotBecomeAnAutomaticMultipleDownload() async throws {
        let world = try World(); defer { world.close() }
        let first = Download(), next = Download(view: first.view)
        first.replacement = next
        world.browser.keep(first)
        let part = try await destination(first, world.browser)
        try Data("partial".utf8).write(to: part)
        world.browser.download(first, didFailWithError: URLError(.networkConnectionLost), resumeData: nil)
        let failed = try #require(world.browser.hoard.fetches.first)
        world.browser.hoard.retry(failed)
        // No new page input: Retry was pressed in the download list. The
        // old policy incorrectly asked for a site's extra automatic file.
        let retried = try await destination(next, world.browser)
        try Data("complete".utf8).write(to: retried)
        world.browser.downloadDidFinish(next)
        try await settle(world.browser, next)
        #expect(world.browser.completedDownloadIDs.contains(next.downloadID))
        #expect(try Data(contentsOf: world.root.appendingPathComponent("same.bin")) == Data("complete".utf8))
    }

    @Test func lateDestinationAfterFailureAnswersOnceAndCannotResurrectTheTransfer() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        var answered = 0
        world.browser.download(download, decideDestinationUsing: response(), suggestedFilename: "same.bin") {
            answered += 1; #expect($0 == nil)
        }
        world.browser.download(download, didFailWithError: URLError(.networkConnectionLost), resumeData: nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(answered == 1 && world.browser.downloadFiles.isEmpty && world.browser.downloadParts.isEmpty)
        #expect(world.browser.hoard.fetches.count == 1 && world.browser.hoard.fetches[0].failed)
    }

    @Test func aFileCreatedAtTheDestinationDuringTheTransferSurvivesFailureAndDismissal() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        let target = try #require(world.browser.downloadFiles[ObjectIdentifier(download)])
        try Data("user file".utf8).write(to: target)
        try Data("download".utf8).write(to: staging)
        world.browser.downloadDidFinish(download)
        try await settle(world.browser, download)
        #expect(world.browser.failedDownloadIDs.contains(download.downloadID))
        #expect(try Data(contentsOf: target) == Data("user file".utf8))
        let fetch = try #require(world.browser.hoard.fetches.first)
        world.browser.hoard.dismiss(fetch)
        #expect(try Data(contentsOf: target) == Data("user file".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func completionInTheDestinationCallbackFindsRegisteredStateAndPublishesOnce() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        world.browser.download(download, decideDestinationUsing: response(), suggestedFilename: "same.bin") { file in
            guard let file else { Issue.record("No destination"); return }
            #expect(world.browser.downloadParts[ObjectIdentifier(download)] != nil)
            #expect(world.browser.hoard.fetches.contains { $0.id == ObjectIdentifier(download) })
            do { try Data("complete".utf8).write(to: file) } catch { Issue.record(error) }
            world.browser.downloadDidFinish(download); world.browser.downloadDidFinish(download)
        }
        try await settle(world.browser, download)
        #expect(try Data(contentsOf: world.root.appendingPathComponent("same.bin")) == Data("complete".utf8))
        #expect(world.browser.hoard.fetches.isEmpty && world.browser.downloading.isEmpty)
    }

    @Test func stopBeforeTheDestinationCompletesRefusesLateCallbacks() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        var answers = 0
        world.browser.download(download, decideDestinationUsing: response(), suggestedFilename: "same.bin") { file in
            answers += 1; #expect(file == nil)
        }
        world.browser.hoard.stop(ObjectIdentifier(download))
        try await Task.sleep(for: .milliseconds(150))
        #expect(answers == 1 && world.browser.downloadReplies.isEmpty && world.browser.downloadFiles.isEmpty)
    }

    // MARK: - what Finder shows meanwhile

    private func partial(_ download: Download, _ browser: Browser) async throws -> URL {
        let sign = try #require(browser.downloadParts[ObjectIdentifier(download)]?.partial)
        for _ in 0..<600 where sign.placed == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(sign.placed)
    }

    @Test func aFileUnderWayShowsAPartialNameAndAPublishedProgressThenItsRealName() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        let target = world.root.appendingPathComponent("same.bin")
        #expect(sign.lastPathComponent == "same.bin.yabdownload")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        let shown = try #require(world.browser.downloadParts[ObjectIdentifier(download)]?.partial?.published)
        #expect(shown.fileURL == sign && shown.kind == .file && shown.fileOperationKind == .downloading)
        #expect(shown.totalUnitCount == 10)
        download.progress.completedUnitCount = 4
        #expect(shown.completedUnitCount == 4)
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        try bytes.write(to: staging)
        world.browser.downloadDidFinish(download)
        try await settle(world.browser, download)
        #expect(try Data(contentsOf: target) == bytes)
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.root.path) == ["same.bin"])
    }

    @Test func cancelTakesThePartialNameAndTheBytes() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        try Data("piece".utf8).write(to: staging)
        world.browser.hoard.stop(ObjectIdentifier(download))
        for _ in 0..<200 where FileManager.default.fileExists(atPath: sign.path) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: world.root.path).isEmpty)
    }

    @Test func aFailureWithNothingToGoOnFromLeavesNoPartialName() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        _ = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        world.browser.download(download, didFailWithError: URLError(.networkConnectionLost), resumeData: nil)
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(world.browser.hoard.fetches.first?.failed == true)
    }

    @Test func aResumableFailureKeepsTheNameWithoutABarUntilItGoesOnOrIsDismissed() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        let part = try #require(world.browser.downloadParts[ObjectIdentifier(download)])
        world.browser.download(download, didFailWithError: URLError(.networkConnectionLost), resumeData: Data("resume".utf8))
        #expect(FileManager.default.fileExists(atPath: sign.path) && part.partial?.published == nil)
        let next = Download(view: download.view)
        download.replacement = next
        let fetch = try #require(world.browser.hoard.fetches.first)
        world.browser.hoard.retry(fetch)
        #expect(part.partial?.published?.fileURL == sign)
        try Data("whole".utf8).write(to: staging)
        world.browser.downloadDidFinish(next)
        try await settle(world.browser, next)
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(try Data(contentsOf: world.root.appendingPathComponent("same.bin")) == Data("whole".utf8))

        let dropped = Download()
        world.browser.keep(dropped)
        _ = try await destination(dropped, world.browser)
        let other = try await partial(dropped, world.browser)
        world.browser.download(dropped, didFailWithError: URLError(.networkConnectionLost), resumeData: Data("resume".utf8))
        world.browser.hoard.dismiss(try #require(world.browser.hoard.fetches.first))
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func aFileAlreadyUnderThePartialNameIsNeverTouched() async throws {
        let world = try World(); defer { world.close() }
        let mine = world.root.appendingPathComponent("same.bin.yabdownload")
        try Data("mine".utf8).write(to: mine)
        let download = Download()
        world.browser.keep(download)
        let staging = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        #expect(sign.lastPathComponent == "same.bin 2.yabdownload")
        try Data("whole".utf8).write(to: staging)
        world.browser.downloadDidFinish(download)
        try await settle(world.browser, download)
        #expect(try Data(contentsOf: mine) == Data("mine".utf8))
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(try Data(contentsOf: world.root.appendingPathComponent("same.bin")) == Data("whole".utf8))
    }

    @Test func aPartialNameFitsWhenTheFilesNameIsAtTheLimit() {
        let long = URL(fileURLWithPath: "/synthetic/" + String(repeating: "\u{00E9}", count: 120) + ".zip")
        let name = DownloadPartial.name(for: long, attempt: 2)
        #expect(name.utf8.count <= 255 && name.hasSuffix(" 2.yabdownload"))
    }

    @Test func aFolderThatRefusesThePartialNameCostsOnlyTheSign() async throws {
        let world = try World(); defer { world.close() }
        let shut = world.root.appendingPathComponent("gone-away", isDirectory: true)
        let parts = world.root.appendingPathComponent("parts", isDirectory: true)
        let file = try DownloadFile(destination: shut.appendingPathComponent("x.bin"), root: parts, showsPartial: true)
        file.partial?.place()
        #expect(file.partial?.placed == nil)
        try Data("bytes".utf8).write(to: file.staging)
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        #expect(try file.publish() == shut.appendingPathComponent("x.bin"))
    }

    @Test func aPartialPlacedAfterTheTransferEndedDoesNotStay() throws {
        let world = try World(); defer { world.close() }
        let file = try DownloadFile(destination: world.root.appendingPathComponent("x.bin"),
                                    root: world.root.appendingPathComponent("parts"), showsPartial: true)
        file.discard()
        file.partial?.place()
        #expect(!FileManager.default.fileExists(atPath: world.root.appendingPathComponent("x.bin.yabdownload").path))
    }

    @Test func launchClearsWhatAKilledYabLeftAndNothingOfTheUsers() throws {
        let world = try World(); defer { world.close() }
        let parts = world.root.appendingPathComponent("parts", isDirectory: true)
        let killed = try DownloadFile(destination: world.root.appendingPathComponent("killed.bin"), root: parts, showsPartial: true)
        killed.partial?.place()
        try Data("piece".utf8).write(to: killed.staging)
        let sign = try #require(killed.partial?.placed)

        // A note pointing at something that isn't a sign any more.
        let reused = try DownloadFile(destination: world.root.appendingPathComponent("reused.bin"), root: parts, showsPartial: true)
        reused.partial?.place()
        let filled = try #require(reused.partial?.placed)
        try Data("the user's now".utf8).write(to: filled)
        let other = try DownloadFile(destination: world.root.appendingPathComponent("other.bin"), root: parts, showsPartial: true)
        let finished = world.root.appendingPathComponent("finished.bin")
        try Data("whole".utf8).write(to: finished)
        try finished.path.write(to: other.staging.deletingLastPathComponent().appendingPathComponent("partial"), atomically: true, encoding: .utf8)

        DownloadFile.clear(DownloadFile.leftovers(in: parts))
        #expect(!FileManager.default.fileExists(atPath: sign.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parts.path).isEmpty)
        #expect(try Data(contentsOf: filled) == Data("the user's now".utf8))
        #expect(try Data(contentsOf: finished) == Data("whole".utf8))
    }

    @Test func launchLeavesATransferOfAnotherRunningYabAlone() throws {
        let world = try World(); defer { world.close() }
        let parts = world.root.appendingPathComponent("parts", isDirectory: true)
        let running = parts.appendingPathComponent("\(getppid()).\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        let dead = parts.appendingPathComponent("99999999.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        let left = DownloadFile.leftovers(in: parts).map(\.lastPathComponent)
        #expect(left == [dead.lastPathComponent])
    }

    @Test func quittingLeavesNoPartialName() async throws {
        let world = try World(); defer { world.close() }
        let download = Download()
        world.browser.keep(download)
        _ = try await destination(download, world.browser)
        let sign = try await partial(download, world.browser)
        world.browser.discardUnfinishedDownloads()
        #expect(!FileManager.default.fileExists(atPath: sign.path))
    }

    @Test func anAgentsFileShowsNoPartialName() throws {
        let world = try World(); defer { world.close() }
        let file = try DownloadFile(destination: world.root.appendingPathComponent("agent.bin"),
                                    root: world.root.appendingPathComponent("parts"))
        #expect(file.partial == nil)
    }
}
