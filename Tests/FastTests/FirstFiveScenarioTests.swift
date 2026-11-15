import AppKit
import Testing
import WebKit
@testable import Fast

/// Qualification of the two reporter scenarios through their actual model
/// and download owner. Passing these controls is not reporter acceptance.
@MainActor @Suite(.serialized)
struct FirstFiveScenarioTests {
    @Test func tidyFoldersRemainAfterTheReportedTenSecondDelay() async throws {
        try #require(Store.testing)
        let browser = Browser(windowID: UUID())
        let oldBrowser = Folders.shared.browser, oldAnswer = TidyTabs.benchAnswer
        let previous = Store.settings.object(forKey: "tidy.tabs")
        browser.prefs.tidyTabs = true
        TidyTabs.benchAnswer = #"{"groups":[{"name":"Trading Platform","tabs":[0,1]},{"name":"Workout Settings","tabs":[2,3]},{"name":"Web Browsers","tabs":[4,5]}]}"#
        Folders.shared.browser = browser
        defer {
            Folders.shared.browser = oldBrowser
            TidyTabs.benchAnswer = oldAnswer
            Store.settings.set(previous, forKey: "tidy.tabs")
            browser.letGo()
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id).json"))
                Store.settings.removeObject(forKey: "window.\(id).space")
            }
        }
        let tabs = (0..<6).map { index in
            let tab = Tab()
            tab.restore(url: URL(string: "https://tidy-fixture.invalid/\(index)")!, title: "Page \(index)")
            browser.prepare(tab)
            return tab
        }
        browser.lay(tabs)
        try #require(browser.canTidyTabs)
        browser.tidyTabs()
        let deadline = Date().addingTimeInterval(5)
        while browser.tabsTidying, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(!browser.tabsTidying)
        try #require(tabs.allSatisfy { $0.nest?.today == true })
        let folderIDs = tabs.map { $0.nest?.id }
        for _ in 0..<11 {
            try await Task.sleep(for: .seconds(1))
            Folders.shared.refresh()
            #expect(browser.tabs.map(\.id) == tabs.map(\.id))
            #expect(tabs.map { $0.nest?.id } == folderIDs)
        }
        browser.flushSession()
        let saved = Session.read(space: browser.spaceID, window: browser.windowID)
        #expect(saved.tabs.count == 6)
        #expect(saved.tabs.allSatisfy { $0.folderToday == true && $0.folder != nil })
        #expect(Set(saved.tabs.compactMap(\.folder)).count == 3)
    }

    @Test func browserDownloadActuallySavesAndLeavesInProgress() async throws {
        try #require(Store.testing)
        let server = try DownloadPartTests.SlowServer(), browser = Browser(windowID: UUID())
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-owner-\(UUID())")
        let keys = ["downloads", "downloads.ask", "tidy.downloads"]
        let old = keys.map { Store.settings.object(forKey: $0) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        browser.prefs.downloads = folder
        browser.prefs.asksWhereToSave = false
        browser.prefs.tidyDownloads = false
        let web = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        defer {
            server.stop(); web.stopLoading(); browser.letGo()
            for (key, value) in zip(keys, old) { Store.settings.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: folder)
        }
        let download = await web.startDownload(using: URLRequest(url: server.url("/slow")))
        browser.keep(download)
        let deadline = Date().addingTimeInterval(45)
        while !browser.downloading.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        #expect(browser.downloading.isEmpty, "The real Browser download owner must receive terminal lifecycle")
        #expect(browser.hoard.going.isEmpty, "Files must not stay In Progress after completion")
        let file = folder.appendingPathComponent("part.bin")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file).count == DownloadPartTests.SlowServer.total)
        #expect(browser.loot.kept.contains { $0.path == file.path })
    }
}
