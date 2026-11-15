import WebKit

extension PageHandle {
    func webKitKeepSharing() { if let webKit { Bench.shared.keepSharing(webKit) } }
    func webKitDoneSharing(of tab: Tab?) { if let webKit { Bench.shared.doneSharing(webKit, of: tab) } }
}

extension Browser {
    /// WebKit's question before its own picker. Reached only from the
    /// box's way to macOS's picker, or from a page that got past Yab's
    /// getDisplayMedia: the screens' picker, which switches to windows.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func requestDisplayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                               decisionHandler: @escaping (Int) -> Void) {
        Share.shared.systemAsked += 1
        decisionHandler(Share.shared.prompts.removeValue(forKey: ObjectIdentifier(web)) ?? 1)
    }
    // Compatibility for the extension system's raw offscreen document.
    func shareAsked(page web: WKWebView, _ body: [String: Any], _ frame: WKFrameInfo) {
        shareAsked(page: web as any PageScriptTarget, body, PageFrame(frame))
    }
}

extension Share.Session {
    convenience init(id: String, caller: Tab?, browser: Browser?, frame: WKFrameInfo, source: Share.Source?, token: String? = nil, page: WKWebView? = nil) {
        self.init(id: id, caller: caller, browser: browser, frame: PageFrame(frame), source: source, token: token, page: page)
    }
}

// Grants and audio taps belong to the current WebKit extension shim.
extension ExtensionCapture {
    static func redeem(_ token: String, from frame: PageFrame, for kind: String = "picture") -> Grant? {
        guard let frame = frame.webKit else { return nil }
        return redeem(token, from: frame, for: kind)
    }
}

extension ExtensionTabAudio {
    static func start(_ grant: ExtensionCapture.Grant, consumer: any PageScriptTarget, caller: Tab? = nil,
                      frame: PageFrame, token: String, answer: @escaping ([String: Any]) -> Void) {
        guard let web = consumer as? WKWebView, let frame = frame.webKit else { answer(["choice": "cancel"]); return }
        start(grant, consumer: web, caller: caller, frame: frame, token: token, answer: answer)
    }
}

/// The page's questions, from yab's world (ShareScript.bridge).
final class ShareRelay: NSObject, PageScriptReceiving {
    static let name = ShareScript.name
    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        MainActor.assumeIsolated {
            guard let tab, let body = message.body as? [String: Any] else { return }
            tab.onShare?(tab, body, message.frame)
        }
    }
}

