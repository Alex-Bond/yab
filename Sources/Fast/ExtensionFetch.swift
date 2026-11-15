import Foundation
import WebKit

// A request an extension's page or worker makes with the user's cookies to a
// site it may reach.
//
// Chrome makes such a request as though it were the site's own: same-origin,
// to any host the extension's permissions reach, so the site's cookies go,
// SameSite=Lax and Strict too, unless credentials are "omit". WebKit counts it
// same-origin as well, but chrome-extension:// another site, and leaves the
// SameSite ones out; most sign-ins are Lax, claude.ai's sessionKey is.
// Claude's side panel asks claude.ai/api/bootstrap with credentials
// "include", got no account back, and asked the user to sign in for ever,
// signed in as they were.
//
// WebKit has no setting for it, so the shim (extension-shims.js, "A site's
// own cookies") hands this app a fetch or an XHR that may carry cookies to an
// http(s) host. When the store holds a SameSite cookie for it, the request
// goes out here with URLSession, its Cookie header made from the first
// space's store (Store.websites, the one the extension's pages use), and what
// the site sets is written back there. Otherwise it is answered "native" and
// the shim makes it itself, as before; for a host the extension may not
// reach, the shim remembers that. The body comes back in pieces the shim asks
// for one at a time, so a stream (server-sent events) arrives as it is sent.

@available(macOS 15.4, *)
@MainActor
enum ExtensionFetch {
    /// One session, no cookie jar or cache of its own: cookies are the
    /// store's, put in and taken out by hand.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: .main)
    }()
    private static var running: [String: Request] = [:]
    private static var next = 0

    /// A context going away cannot leave its requests or unread bodies behind.
    static func cancel(for context: WKWebExtensionContext) {
        for request in Array(running.values) where request.belongs(to: context) { request.cancel() }
    }

    static func run(_ api: String, _ args: [Any], context: WKWebExtensionContext) async throws -> Any? {
        switch api {
        case "sitefetch.start":
            guard let spec = args.first as? [String: Any] else { throw ExtensionShims.Unsupported(what: "No request") }
            return try await start(spec, context: context)
        case "sitefetch.read":
            guard let id = args.first as? String, let request = running[id] else { return ["done": true] }
            return try await request.read()
        case "sitefetch.cancel":
            if let id = args.first as? String { running[id]?.cancel() }
            return nil
        default:
            throw ExtensionShims.Unsupported(what: "Not supported: \(api)")
        }
    }

    private static func start(_ spec: [String: Any], context: WKWebExtensionContext) async throws -> Any? {
        guard let address = spec["url"] as? String, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              context.hasAccess(to: url) else {
            return ["native": true, "unreached": true]
        }
        // WebKit's own request already carries every cookie but the
        // SameSite ones: with none of those for this address, it is the
        // same request, made without a trip through here.
        let cookies = await cookies(for: url)
        guard cookies.contains(where: { $0.sameSitePolicy != nil }) else { return ["native": true] }
        var request = URLRequest(url: url)
        request.httpMethod = (spec["method"] as? String) ?? "GET"
        for pair in spec["headers"] as? [[String]] ?? [] where pair.count == 2 {
            request.addValue(pair[1], forHTTPHeaderField: pair[0])
        }
        if let body = spec["body"] as? String { request.httpBody = Data(base64Encoded: body) }
        // What Chrome sends from an extension's page to a host it may
        // reach: its origin only where a same-origin request has one, and
        // its user agent.
        if !["GET", "HEAD"].contains(request.httpMethod?.uppercased() ?? "GET") {
            request.setValue("\(Extensions.scheme)://\(context.uniqueIdentifier)", forHTTPHeaderField: "Origin")
        }
        if let agent = spec["userAgent"] as? String { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        await withCookies(&request)
        // Cookie lookup yields: disable/reload may have removed this exact
        // context while it waited, even if another now has the same id.
        guard context.isLoaded, let controller = context.webExtensionController,
              controller.extensionContext(for: context.baseURL) === context else {
            return ["failed": URLError(.cancelled).localizedDescription]
        }

        next += 1
        let id = String(next)
        let made = Request(id: id, context: context)
        running[id] = made
        made.onEnd = { running[id] = nil }
        // A request that never reached the site is the shim's TypeError,
        // not a reason to make it again there.
        do { return try await made.start(request) } catch { return ["failed": error.localizedDescription] }
    }

    /// The store's cookies for the request's address, as the site itself
    /// would send them.
    fileprivate static func withCookies(_ request: inout URLRequest) async {
        request.setValue(nil, forHTTPHeaderField: "Cookie")
        guard let url = request.url else { return }
        let cookies = await cookies(for: url)
        if let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"], !header.isEmpty {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
    }

    private static let byURL = NSSelectorFromString("_getCookiesForURL:completionHandler:")

    private static func cookies(for url: URL) async -> [HTTPCookie] {
        await ChromiumDRMCookies.beforeSending(to: url, from: Store.websites)
        let store = Store.websites.httpCookieStore
        if store.responds(to: byURL) {
            return await withCheckedContinuation { done in
                typealias Get = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) (NSArray) -> Void) -> Void
                unsafeBitCast(store.method(for: byURL), to: Get.self)(store, byURL, url as NSURL) { list in
                    done.resume(returning: list.compactMap { $0 as? HTTPCookie })
                }
            }
        }
        // The whole jar, matched the way a request matches.
        let host = url.host?.lowercased() ?? "", path = url.path.isEmpty ? "/" : url.path
        let secure = url.scheme?.lowercased() == "https"
        return await store.allCookies().filter { cookie in
            let domain = cookie.domain.lowercased()
            let hostOK = domain.hasPrefix(".")
                ? host == domain.dropFirst() || host.hasSuffix(domain)
                : host == domain
            return hostOK && path.hasPrefix(cookie.path) && (secure || !cookie.isSecure)
                && (cookie.expiresDate.map { $0 > Date() } ?? true)
        }
    }

    /// What the site set, written to the store before anything else is
    /// asked of it.
    fileprivate static func keep(_ response: HTTPURLResponse) async {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        let store = Store.websites.httpCookieStore
        for cookie in cookies { await store.setCookie(cookie) }
    }

    @MainActor
    final class Request: NSObject, URLSessionDataDelegate {
        let id: String
        private let context: WKWebExtensionContext
        private var task: URLSessionDataTask?
        private var head: CheckedContinuation<Any?, Error>?
        private var reader: CheckedContinuation<Any?, Error>?
        private var buffer = Data()
        private var finished = false
        private var failure: Error?
        private var ended = false
        private var idle: Task<Void, Never>?
        var onEnd: (() -> Void)?

        /// More waiting than this and the site is held until the shim reads.
        private static let most = 4 << 20
        /// At most this much in one answer.
        private static let piece = 1 << 20

        init(id: String, context: WKWebExtensionContext) {
            self.id = id
            self.context = context
        }

        fileprivate func belongs(to context: WKWebExtensionContext) -> Bool { self.context === context }

        func start(_ request: URLRequest) async throws -> Any? {
            try await withCheckedThrowingContinuation { done in
                head = done
                let task = ExtensionFetch.session.dataTask(with: request)
                task.delegate = self
                self.task = task
                task.resume()
            }
        }

        func read() async throws -> Any? {
            guard !ended else { return ["done": true] }
            watch()
            if !buffer.isEmpty || finished { return take() }
            return try await withCheckedThrowingContinuation { reader = $0 }
        }

        private func take() -> Any? {
            if let failure, buffer.isEmpty {
                end()
                return ["error": failure.localizedDescription]
            }
            let chunk = buffer.prefix(Self.piece)
            buffer.removeFirst(chunk.count)
            if task?.state == .suspended, buffer.count < Self.most { task?.resume() }
            let done = finished && buffer.isEmpty && failure == nil
            if done { end() }
            return ["chunk": Data(chunk).base64EncodedString(), "done": done]
        }

        private func wake() {
            guard let reader else { return }
            self.reader = nil
            reader.resume(returning: take())
        }

        /// A body nobody reads is let go of after two minutes, as a page
        /// that drops its response lets WebKit's go.
        private func watch() {
            idle?.cancel()
            idle = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
        }

        func cancel() {
            guard !ended else { return }
            task?.cancel()
            buffer.removeAll(keepingCapacity: false)
            let head = self.head, reader = self.reader
            self.head = nil
            self.reader = nil
            head?.resume(throwing: URLError(.cancelled))
            reader?.resume(returning: ["done": true])
            end()
        }

        private func end() {
            guard !ended else { return }
            ended = true
            idle?.cancel()
            onEnd?()
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            MainActor.assumeIsolated {
                Task { @MainActor in
                    guard !ended else { completionHandler(nil); return }
                    await ExtensionFetch.keep(response)
                    var next = newRequest
                    // Cookies only to a host the extension may reach, the
                    // way Chrome's redirect drops them elsewhere.
                    if let url = next.url, context.hasAccess(to: url) {
                        await ExtensionFetch.withCookies(&next)
                    } else {
                        next.setValue(nil, forHTTPHeaderField: "Cookie")
                    }
                    guard !ended else { completionHandler(nil); return }
                    completionHandler(next)
                }
            }
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            MainActor.assumeIsolated {
                Task { @MainActor in
                    guard !ended else { completionHandler(.cancel); return }
                    guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
                    await ExtensionFetch.keep(http)
                    guard !ended else { completionHandler(.cancel); return }
                    var headers: [[String]] = []
                    for (key, value) in http.allHeaderFields {
                        guard let key = key as? String, let value = value as? String,
                              key.lowercased() != "set-cookie" else { continue }
                        headers.append([key, value])
                    }
                    let first = dataTask.originalRequest?.url?.absoluteString
                    let final = http.url?.absoluteString ?? first ?? ""
                    head?.resume(returning: [
                        "id": id,
                        "status": http.statusCode,
                        "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized,
                        "headers": headers,
                        "url": final,
                        "redirected": final != first,
                    ])
                    head = nil
                    watch()
                    completionHandler(.allow)
                }
            }
        }

        nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            MainActor.assumeIsolated {
                guard !ended else { return }
                buffer.append(data)
                if buffer.count >= Self.most { dataTask.suspend() }
                wake()
            }
        }

        nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated {
                guard !ended else { return }
                finished = true
                failure = error
                if let head {
                    self.head = nil
                    head.resume(throwing: error ?? URLError(.badServerResponse))
                    end()
                    return
                }
                wake()
            }
        }
    }
}
