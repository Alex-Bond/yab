import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct AudioDownloadMenuTests {
    private func page() -> PageView {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return PageView(frame: .zero, configuration: configuration)
    }

    private func menu(_ identifiers: [String]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for id in identifiers {
            if id == "-" { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifier" + id)
            menu.addItem(item)
        }
        return menu
    }

    @Test func onlyAnAudioAddressInAStandaloneMediaDocumentQualifies() {
        for text in ["http://example.test/song.mp3", "https://example.test/song.M4A?download=1"] {
            let address = URL(string: text)!
            #expect(VideoSave.audioDocument(address, standalone: true) == PointedMedia(src: text, audio: true))
            #expect(VideoSave.audioDocument(address, standalone: false) == nil)
        }
        for text in ["https://example.test/page.html", "https://example.test/clip.mp4",
                     "https://example.test/master.m3u8", "file:///tmp/song.mp3", "blob:https://example.test/song.mp3"] {
            #expect(VideoSave.audioDocument(URL(string: text), standalone: true) == nil)
        }
        #expect(VideoSave.audioDocument(nil, standalone: true) == nil)
    }

    @Test(arguments: [false, true])
    func aSoundDocumentGetsTheDownloadRow(withMediaRows: Bool) throws {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        let address = URL(string: "https://example.test/song.mp3")!
        let document = try #require(VideoSave.audioDocument(address, standalone: true))
        var reads = 0
        var picked = 0
        page.onMedia = { _ in picked += 1; return true }
        // WebKit can display a sound document with a video element.
        page.mediaHeard = { _ in reads += 1; return PointedMedia(src: address.absoluteString) }
        let menu = menu(withMediaRows ? ["MediaPlayPause", "MediaMute", "CopyMediaLink", "-", "ShareMenu"] : ["Reload", "ShareMenu"])
        page.mediaHere(menu, since: ProcessInfo.processInfo.systemUptime, document: document)
        PageView.dress(menu)
        let index = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "YabDownloadAudio" })
        let item = menu.items[index]
        #expect(reads == 0)
        #expect(index == (withMediaRows ? 4 : 0))
        #expect(item.title == "Download Audio")
        #expect(item.image === MenuMark.image("yab.audio.dl"))
        #expect(menu.items[index + 1].isSeparatorItem)
        if withMediaRows {
            #expect(menu.items[index - 1].isSeparatorItem)
            #expect(menu.items[index + 2].identifier?.rawValue == "WKMenuItemIdentifierShareMenu")
        } else {
            #expect(menu.items[index + 2].identifier?.rawValue == "WKMenuItemIdentifierReload")
        }
        menu.performActionForItem(at: index)
        #expect(picked == 1)
        #expect(VideoSave.route(document) == .download(address))
    }

    @Test(arguments: [false, true])
    func onlyVideoMenusWaitForAPageMessage(video: Bool) async throws {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        page.onMedia = { _ in true }
        var reads = 0
        page.mediaHeard = { _ in reads += 1; return nil }
        let menu = menu(video ? ["ToggleVideoViewer", "ShareMenu"] : ["Reload", "ShareMenu"])
        page.mediaHere(menu, since: ProcessInfo.processInfo.systemUptime, document: nil)
        #expect(reads == (video ? 1 : 0))
        try await Task.sleep(for: .milliseconds(250))
        #expect(reads == (video ? 2 : 0))
        #expect(!menu.items.contains { ["YabDownloadMedia", "YabDownloadAudio"].contains($0.identifier?.rawValue ?? "") })
        if !video {
            #expect(menu.items.map(\.title) == ["Reload", "ShareMenu"])
            #expect(menu.items.allSatisfy { $0.image == nil })
        }
    }

    @Test(arguments: [false, true])
    func embeddedAudioDoesNotGetAnAddedRow(withVideoRows: Bool) {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        page.onMedia = { _ in true }
        var reads = 0
        page.mediaHeard = { _ in reads += 1; return PointedMedia(src: "https://example.test/song.mp3", audio: true) }
        let menu = menu(withVideoRows ? ["ShowHideMediaControls", "ShareMenu"] : ["MediaPlayPause", "MediaMute", "CopyMediaLink", "ShareMenu"])
        page.mediaHere(menu, since: ProcessInfo.processInfo.systemUptime, document: nil)
        #expect(reads == (withVideoRows ? 1 : 0))
        #expect(!menu.items.contains { ["YabDownloadMedia", "YabDownloadAudio"].contains($0.identifier?.rawValue ?? "") })
    }

    @Test func anAudioAddressAloneDoesNotOverrideThePointedMedia() {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, configuration: configuration, factory: .webKitOnly)
        defer { tab.close() }
        tab.restore(url: URL(string: "http://127.0.0.1:9/song.mp3")!, title: "song.mp3")
        let page = requireNativeWebKitFixture(tab, "AudioDownloadMenuTests")
        let now = ProcessInfo.processInfo.systemUptime
        #expect(page.audioDocument == nil)
        #expect(page.mediaHeard?(now) == nil)
        let pointed = PointedMedia(src: "https://example.test/clip.mp4")
        tab.pointedMedia = (pointed, now)
        #expect(page.mediaHeard?(now) == pointed)
        tab.pointedMedia = (pointed, now - 2)
        #expect(page.mediaHeard?(now) == nil)
    }

    @Test func aBlobVideoStillGetsItsDownloadRow() throws {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        page.onMedia = { _ in true }
        page.mediaHeard = { _ in PointedMedia(src: "blob:https://example.test/clip") }
        let menu = menu(["ToggleVideoViewer", "ToggleEnhancedFullScreen", "-", "ShareMenu"])
        page.mediaHere(menu, since: ProcessInfo.processInfo.systemUptime, document: nil)
        let index = try #require(menu.items.firstIndex { $0.identifier?.rawValue == "YabDownloadMedia" })
        #expect(index == 3)
        #expect(menu.items[index].title == "Download Video")
    }

    @Test func webKitsDownloadRowStillUsesTheAppWithoutReadingThePage() {
        let page = page()
        defer { page.stopLoading(); Tab.end(page) }
        page.onMedia = { _ in true }
        var reads = 0
        page.mediaHeard = { _ in reads += 1; return nil }
        let menu = menu(["DownloadMedia"])
        let item = menu.items[0]
        item.isEnabled = false
        page.mediaHere(menu, since: ProcessInfo.processInfo.systemUptime, document: nil)
        #expect(reads == 0)
        #expect(item.target === page)
        #expect(item.action == NSSelectorFromString("mediaRow:"))
        #expect(item.isEnabled)
        #expect(menu.items.count == 1)
    }
}
