import WebKit

extension PageScriptMessage {
    init(_ message: WKScriptMessage) {
        self.init(body: message.body, frame: PageFrame(message.frameInfo), sourceView: message.webView)
    }
}

extension ScrollRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension VeilRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension MeasureRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension JSONRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension ItemRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension IconRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension FormRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension WalletRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension StoreRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension CallRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension ShareRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension DevRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension RecordRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension BadgeRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension WindowRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension WatchRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension FindRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension ImageRelay: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageScriptMessage(message))
    }
}

extension DarkRelay: WKScriptMessageHandlerWithReply {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        receive(PageScriptMessage(message), reply: replyHandler)
    }
}
