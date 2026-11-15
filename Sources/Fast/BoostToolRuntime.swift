import WebKit

/// The plugin never receives cookies. Only this native transport can attach
/// them to the exact declared origin, after a revision-bound action approval.
@MainActor
final class BoostToolRuntime: NSObject, WKScriptMessageHandlerWithReply {
    let package: BoostPackage
    let revision: String
    let session: String
    let tab: Tab
    let writes: Bool
    let origin: URL
    private var live = true
    private var transports: [UUID: URLSession] = [:]
    private var stillValid: Bool {
        live && Boosts.shared.isEnabled(package.id, in: AddonProfiles.of(tab)) && Boosts.shared.records.contains(where: { $0.id == package.id && $0.revision == revision }) && Agents.shared.session(session)?.state.live == true && tab.agent == session && tab.address?.scheme == origin.scheme && tab.address?.host == origin.host && tab.address?.port == origin.port && !tab.shy && !tab.isDev
    }
    init(package: BoostPackage, revision: String, session: String, tab: Tab, writes: Bool, origin: URL) {
        self.package = package; self.revision = revision; self.session = session; self.tab = tab; self.writes = writes; self.origin = origin
    }
    func run(source: String, name: String, arguments: [String: Any]) async throws -> Any? {
        let config = WKWebViewConfiguration(); config.processPool = Web.pool; config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "site")
        let web = WKWebView(frame: .zero, configuration: config)
        let navigation = BoostNavigation(); web.navigationDelegate = navigation
        defer { withExtendedLifetime(navigation) {}; live = false; transports.values.forEach { $0.invalidateAndCancel() }; transports.removeAll(); config.userContentController.removeScriptMessageHandler(forName: "site", contentWorld: .page); web.stopLoading() }
        web.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; base-uri 'none'; form-action 'none'\"><body></body>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await BoostJavaScript.evaluate("!!document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')", on: web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard (try await BoostJavaScript.evaluate("!!document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')", on: web)) as? Bool == true else { throw BoostPackage.Invalid("The isolated plugin document did not load its network policy.") }
        let code = source.replacingOccurrences(of: #"\bexport\s+(?=(?:const|let|var|async\s+function|function)\s)"#, with: "", options: .regularExpression)
        let script = """
        const request=(method,address,body)=>window.webkit.messageHandlers.site.postMessage({method,address,body}).then(r=>{if(r.error)throw Error(r.error);return r.value});
        const site=Object.freeze({json:address=>request('GET',address,null),post:(address,body)=>request('POST',address,body)});
        \(code)
        const selected=\(name);
        let timer;
        try { return await Promise.race([typeof selected==='function'?selected(args,site):selected.run(args,site),new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Tool timed out; its effect may be unknown')),30000)})]); }
        finally { clearTimeout(timer); }
        """
        return try await BoostJavaScript.call(script, arguments: ["args": arguments], on: web)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard message.frameInfo.isMainFrame, let value = message.body as? [String: Any],
                  let method = value["method"] as? String, ["GET", "POST"].contains(method), method != "POST" || writes,
                  let address = value["address"] as? String, let target = URL(string: address, relativeTo: origin)?.absoluteURL,
                  target.scheme == origin.scheme, target.host == origin.host, target.port == origin.port, target.user == nil, target.password == nil,
                  stillValid else {
                replyHandler(["error": "The request exceeds this tool's approved scope or its task ended."], nil); return
            }
            Task {
                do {
                    let cookies: [HTTPCookie] = try await withCheckedThrowingContinuation { done in
                        var answered = false
                        tab.store.httpCookieStore.getAllCookies { cookies in
                            guard !answered else { return }; answered = true; done.resume(returning: cookies)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            guard !answered else { return }; answered = true; done.resume(throwing: URLError(.timedOut))
                        }
                    }
                    guard stillValid else { throw BoostPackage.Invalid("The plugin or task changed.") }
                    var request = URLRequest(url: target, timeoutInterval: 20); request.httpMethod = method
                    for (field, value) in HTTPCookie.requestHeaderFields(with: cookies.filter { AgentRead.sent($0, to: target) }) { request.setValue(value, forHTTPHeaderField: field) }
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    if method == "POST" {
                        let body = try JSONSerialization.data(withJSONObject: value["body"] ?? [:], options: [.fragmentsAllowed])
                        guard body.count <= 128_000 else { throw BoostPackage.Invalid("The tool request is too large.") }
                        request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                    let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never
                    let transport = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
                    let requestID = UUID(); transports[requestID] = transport
                    defer { transport.invalidateAndCancel(); transports.removeValue(forKey: requestID) }
                    let (data, response) = try await transport.data(for: request)
                    AgentRead.take(response, of: request, into: tab.store)
                    guard stillValid else { throw BoostPackage.Invalid("The tool ended while the request was running.") }
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), data.count <= 2_000_000 else {
                        throw BoostPackage.Invalid("The endpoint failed, redirected or returned too much data.")
                    }
                    replyHandler(["value": try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])], nil)
                } catch { replyHandler(["error": error.localizedDescription], nil) }
            }
        }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
}
