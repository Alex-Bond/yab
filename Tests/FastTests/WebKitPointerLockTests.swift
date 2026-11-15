import AppKit
import Testing
import WebKit
@testable import Fast

/// #1921: WebKit hands the pointer to a page only when its UI delegate
/// answers `_webViewDidRequestPointerLock:completionHandler:`; unanswered,
/// every requestPointerLock() ended in pointerlockerror.
@MainActor @Suite(.serialized)
struct WebKitPointerLockTests {
    private final class Listener: NSObject, PageEvents {
        var asked: [(SitePermission, PageOrigin)] = []
        var reply: (@MainActor (Bool) -> Void)?
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, permission kind: SitePermission, origin: PageOrigin,
                  reply: @escaping @MainActor (Bool) -> Void) {
            asked.append((kind, origin)); self.reply = reply
        }
        func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) { reply(nil) }
        func page(_ page: any PageHandle, dialog: PageDialog, reply: @escaping @MainActor (PageDialogReply) -> Void) { reply(.cancel) }
    }

    @Test func webKitAsksForThePointerAndAnswersOnce() async throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        let listener = Listener()
        view.events = listener
        defer { view.stopLoading(); view.events = nil }
        // WebKit asks the UI delegate only if it answers this selector.
        let selector = NSSelectorFromString("_webViewDidRequestPointerLock:completionHandler:")
        #expect(view.uiDelegate?.responds(to: selector) == true)
        view.loadHTMLString("<canvas></canvas>", baseURL: URL(string: "https://game.invalid:8443/play"))
        for _ in 0..<200 where view.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        try #require(view.url != nil)
        var answers: [Bool] = []
        view.navigationEvents.requestPointerLock(view) { answers.append($0) }
        #expect(answers.isEmpty)
        #expect(listener.asked.count == 1)
        #expect(listener.asked.first?.0 == .pointer)
        #expect(listener.asked.first?.1 == PageOrigin(scheme: "https", host: "game.invalid", port: 8443))
        let reply = try #require(listener.reply)
        reply(true); reply(false)
        #expect(answers == [true])
    }

    @Test func noListenerRefuses() {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration())
        var answers: [Bool] = []
        view.navigationEvents.requestPointerLock(view) { answers.append($0) }
        #expect(answers == [false])
    }
}
