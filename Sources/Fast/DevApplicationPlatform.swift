import AppKit
import WebKit

/// Native WebKit operations not exposed by the page inspector protocol.
@MainActor enum DevApplicationPlatform {
    static func origin(_ url: URL) -> String { (url.scheme ?? "") + "://" + (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") }
    static func push(_ web: WKWebView, scope: String, payload: String, done: @escaping (Bool?, String?) -> Void) {
        let store = web.configuration.websiteDataStore
        let selector = NSSelectorFromString("_processPushMessage:completionHandler:")
        let partitionSelector = NSSelectorFromString("_webPushPartition")
        guard store.responds(to: selector), store.responds(to: partitionSelector) else { done(nil, "Push emulation is unavailable in this WebKit build"); return }
        guard let url = URL(string: scope), ["http", "https"].contains(url.scheme ?? ""), payload.utf8.count <= 65536 else { done(nil, "Enter a valid worker scope and a payload under 64 KiB"); return }
        let partition = store.perform(partitionSelector)?.takeUnretainedValue() as? String ?? ""
        let message: NSDictionary = ["WebKitPushRegistrationURL": url as NSURL, "WebKitPushPartition": partition, "WebKitPushData": payload.isEmpty ? NSNull() : Data(payload.utf8) as NSData, "WebKitNotificationPayload": NSNull()]
        typealias Reply = @convention(block) (Bool) -> Void
        typealias Send = @convention(c) (AnyObject, Selector, NSDictionary, Reply) -> Void
        let reply: Reply = { processed in DispatchQueue.main.async { done(processed, nil) } }
        unsafeBitCast(store.method(for: selector), to: Send.self)(store, selector, message, reply)
    }
    static func backgroundFetches(_ web: WKWebView, origin: String, done: @escaping ([[String: Any]]?, String?) -> Void) {
        let store = web.configuration.websiteDataStore
        let selector = NSSelectorFromString("_getAllBackgroundFetchIdentifiers:")
        let stateSelector = NSSelectorFromString("_getBackgroundFetchState:completionHandler:")
        guard store.responds(to: selector), store.responds(to: stateSelector) else { done(nil, "Background Fetch inspection is unavailable in this WebKit build"); return }
        typealias Reply = @convention(block) (NSArray) -> Void
        typealias List = @convention(c) (AnyObject, Selector, Reply) -> Void
        let reply: Reply = { identifiers in
            Task { @MainActor in
                var rows: [[String: Any]] = []
                for identifier in identifiers.compactMap({ $0 as? String }) {
                    let state = await fetchState(store, identifier)
                    guard let scope = state["Scope"] as? URL, Self.origin(scope) == origin else { continue }
                    var row = state; row["id"] = identifier; row["Scope"] = scope.absoluteString; rows.append(row)
                }
                done(rows, nil)
            }
        }
        unsafeBitCast(store.method(for: selector), to: List.self)(store, selector, reply)
    }
    private static func fetchState(_ store: WKWebsiteDataStore, _ identifier: String) async -> [String: Any] {
        let selector = NSSelectorFromString("_getBackgroundFetchState:completionHandler:")
        typealias Reply = @convention(block) (NSDictionary?) -> Void
        typealias State = @convention(c) (AnyObject, Selector, NSString, Reply) -> Void
        return await withCheckedContinuation { continuation in
            let reply: Reply = { state in continuation.resume(returning: state as? [String: Any] ?? [:]) }
            unsafeBitCast(store.method(for: selector), to: State.self)(store, selector, identifier as NSString, reply)
        }
    }
    static func backgroundAction(_ web: WKWebView, origin: String, identifier: String, action: String, done: @escaping (String?) -> Void) {
        let selectors = ["pause": "_pauseBackgroundFetch:completionHandler:", "resume": "_resumeBackgroundFetch:completionHandler:", "abort": "_abortBackgroundFetch:completionHandler:"]
        guard let name = selectors[action] else { done("Unknown Background Fetch action"); return }
        let store = web.configuration.websiteDataStore, selector = NSSelectorFromString(name)
        guard store.responds(to: selector), store.responds(to: NSSelectorFromString("_getBackgroundFetchState:completionHandler:")) else { done("Background Fetch controls are unavailable"); return }
        Task { @MainActor in
            let state = await fetchState(store, identifier)
            guard let scope = state["Scope"] as? URL, Self.origin(scope) == origin else { done("The background fetch does not belong to the selected origin"); return }
            typealias Reply = @convention(block) () -> Void
            typealias Action = @convention(c) (AnyObject, Selector, NSString, Reply) -> Void
            let reply: Reply = { DispatchQueue.main.async { done(nil) } }
            unsafeBitCast(store.method(for: selector), to: Action.self)(store, selector, identifier as NSString, reply)
        }
    }
}

extension Browser {
    /// Native Application commands use the inspected tab's own data store.
    func applicationNative(_ method: String, _ params: [String: Any], failed: ((String) -> Void)?, done: ((Any?) -> Void)?) -> Bool {
        guard ["application.push", "application.backgroundFetch", "application.backgroundFetchAction"].contains(method) else { return false }
        guard let web = toolsFront?.webKitOnly("WebKit response metadata", build: false) else { failed?("No inspected page"); done?(nil); return true }
        let origin = params["origin"] as? String ?? web.url.map(DevApplicationPlatform.origin) ?? ""
        guard workbench?.application.origins.contains(where: { $0["origin"] as? String == origin }) == true || web.url.map(DevApplicationPlatform.origin) == origin else { failed?("The selected origin is no longer loaded"); done?(nil); return true }
        func finish(_ value: Any?, _ error: String?) { if let error { failed?(error); done?(nil) } else { done?(value) } }
        if method == "application.push" {
            guard let scope = params["scope"] as? String, let url = URL(string: scope), DevApplicationPlatform.origin(url) == origin else { finish(nil, "Worker scope does not belong to the selected origin"); return true }
            // Prompt-state delivery can remove the site's subscription in WebKit.
            // Read both the browser's policy and the live frame before invoking it.
            guard let site = SiteNotices.origin(webKit: origin), SiteNotices.said(site) == true else { finish(nil, "Allow this site's notifications before emulating Push."); return true }
            var permissionFailed = false
            wire("application.notificationPermission", ["origin": origin], failed: { error in permissionFailed = true; finish(nil, error) }) { value in
                guard !permissionFailed else { return }
                let permission = (value as? String).flatMap(DevWorkbench.parse) as? String ?? value as? String
                guard permission == "granted" else { finish(nil, "Allow this site's notifications before emulating Push."); return }
                DevApplicationPlatform.push(web, scope: scope, payload: params["payload"] as? String ?? "") { [weak self] processed, error in
                    if let app = self?.workbench?.application, app.recordingEvents {
                        app.events.append(["kind": "Push emulation", "origin": origin, "scope": scope, "payload": String((params["payload"] as? String ?? "").prefix(4000)), "time": Date().timeIntervalSince1970 * 1000, "processed": processed ?? false])
                        if app.events.count > 2000 { app.events.removeFirst(app.events.count - 2000) }
                    }
                    finish(processed, error)
                }
            }
        } else if method == "application.backgroundFetch" {
            DevApplicationPlatform.backgroundFetches(web, origin: origin) { rows, error in finish(rows, error) }
        } else {
            DevApplicationPlatform.backgroundAction(web, origin: origin, identifier: params["id"] as? String ?? "", action: params["action"] as? String ?? "") { error in finish(error == nil, error) }
        }
        return true
    }
}


nonisolated(unsafe) private var applicationResponsesKey: UInt8 = 0
@MainActor private final class ApplicationResponses {
    var headers: [String: [String: String]] = [:]
    var order: [String] = []
}
extension WKWebView {
    /// Save the real document policies before an inspector is opened.
    func rememberApplicationResponse(_ response: URLResponse) {
        guard let http = response as? HTTPURLResponse, let url = response.url?.absoluteString else { return }
        let records = objc_getAssociatedObject(self, &applicationResponsesKey) as? ApplicationResponses ?? ApplicationResponses()
        objc_setAssociatedObject(self, &applicationResponsesKey, records, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let keys: Set<String> = ["content-security-policy", "content-security-policy-report-only", "cross-origin-opener-policy", "cross-origin-embedder-policy", "cross-origin-resource-policy", "permissions-policy", "origin-agent-cluster"]
        records.headers[url] = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
            let name = String(describing: key).lowercased(); return keys.contains(name) ? (name, String(describing: value)) : nil
        })
        records.order.removeAll { $0 == url }; records.order.append(url)
        if records.order.count > 512 { records.headers.removeValue(forKey: records.order.removeFirst()) }
    }
    func applicationResponseHeaders(_ url: String) -> [String: String] { (objc_getAssociatedObject(self, &applicationResponsesKey) as? ApplicationResponses)?.headers[url] ?? [:] }
}
extension Browser {
    func applicationFrameInfo(_ value: Any?) -> Any? {
        guard var info = ((value as? String).flatMap(DevWorkbench.parse) ?? value) as? [String: Any], let url = info["url"] as? String else { return value }
        var headers = toolsFront?.webKitOnly("WebKit response metadata", build: false)?.applicationResponseHeaders(url) ?? [:]
        for (key, value) in info["headers"] as? [String: Any] ?? [:] { headers[key.lowercased()] = String(describing: value) }
        info["headers"] = headers
        var csp = info["csp"] as? [String] ?? []
        if let policy = headers["content-security-policy"], !csp.contains(policy) { csp.append(policy) }
        info["csp"] = csp; return info
    }
}
