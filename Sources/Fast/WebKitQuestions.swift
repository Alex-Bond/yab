import WebKit

extension PageOrigin {
    init(_ origin: WKSecurityOrigin) {
        self.init(scheme: origin.protocol, host: origin.host, port: origin.port)
    }
}

extension PageAuthentication {
    init(_ challenge: URLAuthenticationChallenge) {
        let space = challenge.protectionSpace
        self.init(host: space.host, realm: space.realm, scheme: space.protocol,
                  method: space.authenticationMethod, previousFailureCount: challenge.previousFailureCount,
                  proposedUser: challenge.proposedCredential?.user,
                  proposedPasswordIsEmpty: (challenge.proposedCredential?.password ?? "x").isEmpty)
    }
}

extension PagePermission {
    var webKit: WKPermissionDecision {
        switch self {
        case .grant: return .grant
        case .deny: return .deny
        case .prompt: return .prompt
        }
    }
}

/// The engine keeps live trust objects and credentials. Only copied metadata
/// and asynchronous replies cross PageEvents, including delayed trust checks.
@MainActor
enum WebKitQuestions {
    static func once<Value>(_ done: @escaping (Value) -> Void) -> @MainActor (Value) -> Void {
        var answered = false
        return { value in
            guard !answered else { return }
            answered = true
            done(value)
        }
    }

    static func authenticate(_ view: WKWebView, _ challenge: URLAuthenticationChallenge,
                             listener: (any PageEvents)?,
                             done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let finish: (PageAuthenticationReply) -> Void = once { answer in
            switch answer {
            case .performDefaultHandling: done(.performDefaultHandling, nil)
            case .cancel: done(.cancelAuthenticationChallenge, nil)
            case .credential(let user, let password):
                done(.useCredential, URLCredential(user: user, password: password, persistence: .forSession))
            }
        }
        guard let listener else { finish(.performDefaultHandling); return }
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(view, challenge, listener: listener, done: done)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            if let page = view as? PageView {
                listener.page(page, authenticate: PageAuthentication(challenge), reply: finish)
            } else if let browser = listener as? Browser {
                // Separate legacy WebKit surfaces retain the system sheet.
                browser.signIn(view, PageAuthentication(challenge), finish)
            } else {
                finish(.performDefaultHandling)
            }
        default: finish(.performDefaultHandling)
        }
    }

    private static func trust(_ view: WKWebView, _ challenge: URLAuthenticationChallenge,
                              listener: any PageEvents,
                              done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            done(.cancelAuthenticationChallenge, nil)
            return
        }
        if Dialogs.trustOnMain {
            let trusted = MainBudget.chunk("trust.evaluate") { SecTrustEvaluateWithError(trust, nil) }
            if trusted { done(.performDefaultHandling, nil) }
            else { untrusted(view, challenge, trust, listener: listener, done: done) }
            return
        }
        let queue = DispatchQueue.global(qos: .userInitiated)
        let began = ProcessInfo.processInfo.systemUptime
        queue.async {
            SecTrustEvaluateAsyncWithError(trust, queue) { _, trusted, _ in
                MainBudget.record("trust.evaluate", ProcessInfo.processInfo.systemUptime - began, main: false)
                DispatchQueue.main.async { [weak listener] in
                    guard trusted else {
                        guard let listener else { done(.cancelAuthenticationChallenge, nil); return }
                        MainActor.assumeIsolated { untrusted(view, challenge, trust, listener: listener, done: done) }
                        return
                    }
                    done(.performDefaultHandling, nil)
                }
            }
        }
    }

    private static func untrusted(_ view: WKWebView, _ challenge: URLAuthenticationChallenge, _ trust: SecTrust,
                                  listener: any PageEvents,
                                  done: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let host = CertificateException.hostName(challenge.protectionSpace.host)
        if let exception = CertificateException(host: host, port: challenge.protectionSpace.port, trust: trust),
           CertificateExceptions.contains(exception, in: view) {
            done(.useCredential, URLCredential(trust: trust))
            return
        }
        // Explicit cancellation prevents a cached credential from another
        // view in the store silently approving an invalid subresource.
        done(.cancelAuthenticationChallenge, nil)
        guard let page = view as? PageView else { return }
        let certificate = PageCertificate(host: host, port: challenge.protectionSpace.port, trust: trust)
        listener.page(page, rejected: certificate)
    }

    static func closed(_ view: WKWebView, listener: (any PageEvents)?) {
        if Leaving.closed(view) { return }
        if let document = DocumentPiP.owning(page: view) { document.didClose(); return }
        if let link = LinkWindow.owning(page: view) { link.close(); return }
        guard let page = view as? PageView else { return }
        listener?.pageClosed(page)
    }
}

extension PageCertificate {
    init(host: String, port: Int, trust: SecTrust) {
        self.host = host
        self.port = port
        var error: CFError?
        _ = SecTrustEvaluateWithError(trust, &error)
        switch error.map({ CFErrorGetCode($0) }) {
        case Int(errSecCertificateExpired): why = "Its certificate has run out"
        case Int(errSecHostNameMismatch): why = "Its certificate is for another site"
        default: why = "This Mac doesn’t trust whoever signed its certificate"
        }
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        exception = CertificateException(host: host, port: port, trust: trust)
        let summaries = chain.prefix(2).compactMap { SecCertificateCopySubjectSummary($0) as String? }
        switch summaries.count {
        case 0: names = ""
        case 1: names = "Issued to \(summaries[0]), by itself."
        default: names = "Issued to \(summaries[0]), by \(summaries[1])."
        }
    }
}

extension Untrusted {
    init(host: String, url: URL, trust: SecTrust) {
        let certificate = PageCertificate(host: host, port: url.port ?? 443, trust: trust)
        self.init(host: host, url: url, exception: certificate.exception, why: certificate.why, names: certificate.names)
    }
}

extension WebKitPageEvents {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebKitQuestions.authenticate(webView, challenge, listener: listener, done: completionHandler)
    }

    func webViewDidClose(_ webView: WKWebView) {
        WebKitQuestions.closed(webView, listener: listener)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, ended: nil)
    }

    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func _webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, ended: PageEnd(rawValue: reason) ?? .crash)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let reply = WebKitQuestions.once { (answer: PagePermission) in decisionHandler(answer.webKit) }
        guard let type = PageCapture(rawValue: type.rawValue) else { reply(.deny); return }
        guard let page = webView as? PageView, let listener else { reply(.deny); return }
        listener.page(page, capture: type, origin: PageOrigin(origin), reply: reply)
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        requestGeolocationPermission(webView, origin: origin, frame: frame, decisionHandler: decisionHandler)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func requestGeolocationPermission(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let reply = WebKitQuestions.once { (answer: PagePermission) in decisionHandler(answer.webKit) }
        guard let page = webView as? PageView, let listener else { reply(.deny); return }
        listener.page(page, locate: PageOrigin(origin), reply: reply)
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func requestNotificationPermission(_ webView: WKWebView, origin: WKSecurityOrigin,
                                       decisionHandler: @escaping (Bool) -> Void) {
        let reply = WebKitQuestions.once(decisionHandler)
        guard let page = webView as? PageView, let listener else { reply(false); return }
        listener.page(page, notify: PageOrigin(origin), reply: reply)
    }
}

extension Browser {
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        WebKitQuestions.authenticate(webView, challenge, listener: self, done: completionHandler)
    }

    func webViewDidClose(_ webView: WKWebView) {
        WebKitQuestions.closed(webView, listener: self)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let page = webView as? PageView else { return }
        self.page(page, ended: nil)
    }

    @objc(_webView:webContentProcessDidTerminateWithReason:)
    func _webView(_ webView: WKWebView, webContentProcessDidTerminateWithReason reason: Int) {
        guard let page = webView as? PageView else { return }
        self.page(page, ended: PageEnd(rawValue: reason) ?? .crash)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let reply = WebKitQuestions.once { (answer: PagePermission) in decisionHandler(answer.webKit) }
        guard let type = PageCapture(rawValue: type.rawValue) else { reply(.deny); return }
        if let page = webView as? PageView { self.page(page, capture: type, origin: PageOrigin(origin), reply: reply) }
        else { askCapture(webView, PageOrigin(origin), type, reply) }
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        requestGeolocationPermission(webView, origin: origin, frame: frame, decisionHandler: decisionHandler)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func requestGeolocationPermission(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                                      decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let reply = WebKitQuestions.once { (answer: PagePermission) in decisionHandler(answer.webKit) }
        if let page = webView as? PageView { self.page(page, locate: PageOrigin(origin), reply: reply) }
        else { askLocation(webView, PageOrigin(origin), reply) }
    }

    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func requestNotificationPermission(_ webView: WKWebView, origin: WKSecurityOrigin,
                                       decisionHandler: @escaping (Bool) -> Void) {
        let reply = WebKitQuestions.once(decisionHandler)
        if let page = webView as? PageView { self.page(page, notify: PageOrigin(origin), reply: reply) }
        else { askNotifications(webView, PageOrigin(origin), reply) }
    }
}
