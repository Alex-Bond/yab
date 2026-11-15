import WebKit

extension WebKitPageEvents {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let page = webView as? PageView, let listener else { completionHandler(); return }
        var answered = false
        listener.page(page, dialog: PageDialog(kind: .alert, message: message, defaultText: nil, origin: PageOrigin(frame.securityOrigin))) { _ in
            guard !answered else { return }; answered = true
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let page = webView as? PageView, let listener else { completionHandler(false); return }
        var answered = false
        listener.page(page, dialog: PageDialog(kind: .confirm, message: message, defaultText: nil, origin: PageOrigin(frame.securityOrigin))) { answer in
            guard !answered else { return }; answered = true
            if case .accept = answer { completionHandler(true) } else { completionHandler(false) }
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard let page = webView as? PageView, let listener else { completionHandler(nil); return }
        var answered = false
        listener.page(page, dialog: PageDialog(kind: .prompt, message: prompt, defaultText: defaultText, origin: PageOrigin(frame.securityOrigin))) { answer in
            guard !answered else { return }; answered = true
            if case .accept(let text) = answer { completionHandler(text ?? defaultText ?? "") } else { completionHandler(nil) }
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard let page = webView as? PageView, let listener else { completionHandler(nil); return }
        var answered = false
        listener.page(page, chooseFiles: PageFilePicker(allowsDirectories: parameters.allowsDirectories,
                                                        allowsMultiple: parameters.allowsMultipleSelection, frame: PageFrame(frame))) { files in
            guard !answered else { return }; answered = true
            completionHandler(files)
        }
    }
}

// Separate raw WebKit surfaces keep their existing system-sheet path.
extension Browser {
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        showPageAlert(webView, owner: tab(for: webView), message: message, origin: PageOrigin(frame.securityOrigin), completionHandler: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        showPageConfirm(webView, owner: tab(for: webView), message: message, origin: PageOrigin(frame.securityOrigin), completionHandler: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        showPagePrompt(webView, owner: tab(for: webView), prompt: prompt, defaultText: defaultText, origin: PageOrigin(frame.securityOrigin), completionHandler: completionHandler)
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        showPageFiles(webView, parameters: PageFilePicker(allowsDirectories: parameters.allowsDirectories,
                                                         allowsMultiple: parameters.allowsMultipleSelection, frame: PageFrame(frame)), completionHandler: completionHandler)
    }
}

extension Dialogs {
    static func host(of frame: WKFrameInfo) -> String { host(of: PageOrigin(frame.securityOrigin)) }
    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        alert(from: PageOrigin(frame.securityOrigin), saying: message)
    }
}
