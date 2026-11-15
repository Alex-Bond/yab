import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PagePopupEventsTests {
    private final class Listener: NSObject, PageEvents {
        var finished = false
        var popup: PagePopup?
        var reply: (@MainActor (UUID?) -> Void)?
        var dialog: PageDialog?
        var answer: (@MainActor (PageDialogReply) -> Void)?
        var picker: PageFilePicker?
        var files: (@MainActor ([URL]?) -> Void)?

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .finished = event { finished = true }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) {
            self.popup = popup; self.reply = reply
        }
        func page(_ page: any PageHandle, dialog: PageDialog, reply: @escaping @MainActor (PageDialogReply) -> Void) {
            self.dialog = dialog; answer = reply
        }
        func page(_ page: any PageHandle, chooseFiles picker: PageFilePicker, reply: @escaping @MainActor ([URL]?) -> Void) {
            self.picker = picker; files = reply
        }
    }

    private func fixture(_ listener: Listener) async throws -> PageView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = PageView(frame: .zero, configuration: configuration)
        view.events = listener
        view.navigate(html: "<title>Popup seam</title><input type='file' id='file' multiple>", base: URL(string: "https://seam.invalid:8443"))
        for _ in 0..<300 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        return view
    }

    @Test func realPopupCanWaitAndKeepsOpenerStoreAndSeparateControllerAcrossListenerTransfer() async throws {
        let listener = Listener(), next = Listener(), view = try await fixture(listener)
        let controller = view.configuration.userContentController
        defer { listener.reply?(nil); listener.answer?(.cancel); listener.files?(nil); view.stopLoading(); view.events = nil }
        let opening = Task { try await view.run("window.child = window.open('about:blank', 'seam-child', 'width=420,height=300'); child !== null && child.opener === window") }
        for _ in 0..<300 where listener.popup == nil { try await Task.sleep(for: .milliseconds(20)) }
        let popup = try #require(listener.popup), reply = try #require(listener.reply)
        #expect(popup.width == 420 && popup.height == 300 && popup.isPopup)
        #expect(popup.action.kind == .other && popup.action.source?.isMainFrame == true)
        #expect(view.navigationEvents.popups[popup.id] != nil)
        #expect(view.configuration.userContentController === controller)
        view.events = next
        try await Task.sleep(for: .milliseconds(60))
        let child = try #require(view.webKitPopupTab(popup.id))
        defer { child.close() }
        #expect(view.webKitPopupTab(popup.id) == nil)
        let page = requireNativeWebKitFixture(child, "PagePopupEventsTests")
        #expect(page.configuration.websiteDataStore === view.configuration.websiteDataStore)
        #expect(page.configuration.userContentController !== controller)
        #expect(SiteProcesses.related(of: page.configuration) === view)
        reply(child.id); reply(nil)
        #expect(try await opening.value as? Bool == true)
        #expect(view.navigationEvents.popups.isEmpty && next.popup == nil)
        #expect(try await page.run("window.opener !== null") as? Bool == true)
        #expect(view.webKitPopupTab(popup.id) == nil)
    }

    @Test func realPopupRefusalReleasesPendingConstruction() async throws {
        let listener = Listener(), view = try await fixture(listener)
        defer { listener.reply?(nil); listener.answer?(.cancel); listener.files?(nil); view.stopLoading(); view.events = nil }
        let opening = Task { try await view.run("window.open('about:blank') === null") }
        for _ in 0..<300 where listener.reply == nil { try await Task.sleep(for: .milliseconds(20)) }
        let reply = try #require(listener.reply)
        reply(nil); reply(UUID())
        #expect(try await opening.value as? Bool == true)
        #expect(view.navigationEvents.popups.isEmpty)
    }

    @Test(arguments: [PageDialog.Kind.alert, .confirm, .prompt])
    func realDialogsWaitAndAnswerOnceWithCopiedOrigin(kind: PageDialog.Kind) async throws {
        let listener = Listener(), next = Listener(), view = try await fixture(listener)
        defer { listener.reply?(nil); listener.answer?(.cancel); listener.files?(nil); view.stopLoading(); view.events = nil }
        let script: String
        switch kind {
        case .alert: script = "alert('words'); 'done'"
        case .confirm: script = "String(confirm('words'))"
        case .prompt: script = "prompt('words', 'initial')"
        case .beforeUnload:
            Issue.record("This script-dialog fixture cannot exercise native beforeunload navigation")
            return
        }
        let asking = Task { try await view.run(script) }
        for _ in 0..<300 where listener.answer == nil { try await Task.sleep(for: .milliseconds(20)) }
        let dialog = try #require(listener.dialog), reply = try #require(listener.answer)
        #expect(dialog.kind == kind && dialog.message == "words")
        #expect(dialog.origin == PageOrigin(scheme: "https", host: "seam.invalid", port: 8443))
        let decoded = try JSONDecoder().decode(PageDialog.self, from: JSONEncoder().encode(dialog))
        #expect(decoded == dialog)
        if kind == .prompt { #expect(dialog.defaultText == "initial") }
        view.events = next
        reply(.accept("typed")); reply(.cancel)
        let expected = kind == .alert ? "done" : kind == .confirm ? "true" : "typed"
        #expect(try await asking.value as? String == expected)
        #expect(next.dialog == nil)
    }

    @Test func aRealFileInputWaitsForOneSelectionAndKeepsItsFrameAndFlags() async throws {
        let listener = Listener(), next = Listener(), view = try await fixture(listener)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-picker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = [folder.appendingPathComponent("first.txt"), folder.appendingPathComponent("second.txt")]
        try Data("first".utf8).write(to: files[0]); try Data("second".utf8).write(to: files[1])
        defer {
            listener.files?(nil); view.stopLoading(); view.events = nil
            try? FileManager.default.removeItem(at: folder)
        }
        _ = try await view.run("document.getElementById('file').click()")
        for _ in 0..<300 where listener.files == nil { try await Task.sleep(for: .milliseconds(20)) }
        let picker = try #require(listener.picker), reply = try #require(listener.files)
        #expect(picker.allowsMultiple && !picker.allowsDirectories && picker.frame?.isMain == true)
        let count = try await view.run("document.getElementById('file').files.length") as? Int
        #expect(count == 0)
        view.events = next
        reply(files); reply(nil)
        var names: [String] = []
        for _ in 0..<300 where names.count != 2 {
            names = (try await view.run("Array.from(document.getElementById('file').files, file => file.name)") as? [String]) ?? []
            if names.count != 2 { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(names == ["first.txt", "second.txt"] && next.picker == nil)
    }

    @Test func browserCardsAndApprovedUploadsKeepTheirDecisions() throws {
        let browser = Browser(windowID: UUID()), tab = browser.open(URL(string: "about:blank")!, foreground: true)
        defer { browser.close(tab) }
        let page = tab.page, origin = PageOrigin(scheme: "https", host: "seam.invalid", port: 443)
        var result: PageDialogReply?
        browser.page(page, dialog: PageDialog(kind: .confirm, message: "Leave?", defaultText: nil, origin: origin)) { result = $0 }
        #expect(result == nil && tab.asks.first?.kind == .confirm && tab.asks.first?.host == origin.host)
        browser.answer(tab, .no)
        #expect(result == .cancel)
        browser.page(page, dialog: PageDialog(kind: .prompt, message: "Name?", defaultText: "initial", origin: origin)) { result = $0 }
        #expect(tab.asks.first?.text == "initial")
        browser.answer(tab, .yes("typed"))
        #expect(result == .accept("typed"))
        let files = [URL(fileURLWithPath: "/tmp/first.txt"), URL(fileURLWithPath: "/tmp/second.txt")]
        tab.uploading = (files: files, until: Date().addingTimeInterval(30))
        var picked: [URL]?
        browser.page(page, chooseFiles: PageFilePicker(allowsDirectories: false, allowsMultiple: false)) { picked = $0 }
        #expect(picked == [files[0]] && tab.uploading == nil)
        tab.uploading = (files: files, until: Date().addingTimeInterval(30))
        browser.page(page, chooseFiles: PageFilePicker(allowsDirectories: true, allowsMultiple: true)) { picked = $0 }
        #expect(picked == files && tab.uploading == nil)
    }
}
