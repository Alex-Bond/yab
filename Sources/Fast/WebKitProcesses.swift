import WebKit

extension Browser {
    static func gpuProcess(of web: WKWebView?) -> Int32? {
        guard let web, web.responds(to: NSSelectorFromString("_gpuProcessIdentifier")),
              let pid = (web.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    static func process(of web: WKWebView?) -> Int32? {
        guard let web, web.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }

    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        heardDeaf(tab, by: "WebKit")
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webProcessDidBecomeResponsive(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        heardAnswering(tab)
    }

    /// Once, for every window: any reach into a page goes through here.
    static func watchReaching() {
        guard PageView.reached == nil else { return }
        PageView.reached = { view in
            MainActor.assumeIsolated {
                guard let browser = BrowserWindows.shared.browser(for: view.window),
                      let tab = browser.tab(for: view), tab.deaf != nil else { return }
                browser.reachedDeaf(tab)
            }
        }
    }
}

extension WKWebView {
    /// The page's process ended, as Activity Monitor's Force Quit would.
    /// WebKit is asked first, so it knows the process went and says so; on
    /// macOS that launches its pages as extensions, that only asks the
    /// process to go, which one stuck in a loop never hears, so a second
    /// later it is ended by its pid if it is still there.
    func killContent() {
        let pid = Browser.process(of: self)
        let name = NSSelectorFromString("_killWebContentProcess")
        if responds(to: name) { perform(name) }
        guard let pid, let born = Self.started(pid) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            // The same process, not another that took its number since.
            guard Self.started(pid) == born else { return }
            kill(pid, SIGKILL)
        }
    }

    static func end(_ pid: Int32, born: UInt64) { PageProcessLife.end(pid, born: born) }
    static func started(_ pid: Int32) -> UInt64? { PageProcessLife.started(pid) }
}

extension WebKitPageEvents {
    @objc(_webViewWebProcessDidBecomeUnresponsive:)
    func webProcessDidBecomeUnresponsive(_ webView: WKWebView) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, responsive: false)
    }

    @objc(_webViewWebProcessDidBecomeResponsive:)
    func webProcessDidBecomeResponsive(_ webView: WKWebView) {
        guard let page = webView as? PageView else { return }
        listener?.page(page, responsive: true)
    }
}
