import AppKit
import Foundation
import WebKit

@main struct Probe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        var rows: [[String: Any]] = []
        for policy in ["absent", "none", "None", "lax", "strict"] {
            var properties: [HTTPCookiePropertyKey: Any] = [.name: "probe_" + policy, .value: "fake", .domain: "drm.example.test", .path: "/", .secure: "TRUE"]
            if policy != "absent" { properties[.sameSitePolicy] = policy }
            guard let cookie = HTTPCookie(properties: properties) else { rows.append(["input": policy, "error": "cookie rejected"]); continue }
            await store.setCookie(cookie)
            let found = await store.allCookies().first { $0.name == cookie.name }
            rows.append(["input": policy, "foundation": cookie.sameSitePolicy?.rawValue ?? "nil", "webkit": found?.sameSitePolicy?.rawValue ?? "nil", "stored": found == nil ? "no" : "yes", "foundationProperties": cookie.properties?.reduce(into: [String: String]()) { $0[$1.key.rawValue] = String(describing: $1.value) } ?? [:], "webkitProperties": found?.properties?.reduce(into: [String: String]()) { $0[$1.key.rawValue] = String(describing: $1.value) } ?? [:]])
        }
        withExtendedLifetime(dataStore) {}
        print(String(data: try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
