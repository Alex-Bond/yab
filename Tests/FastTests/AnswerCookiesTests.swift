import Foundation
import Testing
import WebKit
@testable import Fast

/// A read without a tab (AgentRead, LiveReader, a plugin's tool) keeps the
/// cookies the site answers with, as the tab would have.
@MainActor struct AnswerCookiesTests {
    private func cookies(_ store: WKWebsiteDataStore, until test: ([HTTPCookie]) -> Bool) async throws -> [HTTPCookie] {
        for _ in 0..<50 {
            let all = await store.httpCookieStore.allCookies()
            if test(all) { return all }
            try await Task.sleep(for: .milliseconds(100))
        }
        return await store.httpCookieStore.allCookies()
    }

    /// A request sent with the store's cookies for its host.
    private func signedIn(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("sid=S3", forHTTPHeaderField: "Cookie")
        return request
    }

    @Test func aSiteNeverSignedInToLeavesNothing() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let url = URL(string: "https://never.example.net/")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Set-Cookie": "tracker=1; Path=/"])
        AgentRead.take(response, of: URLRequest(url: url), into: store)
        // Another host's answer to a signed-in request leaves nothing either.
        AgentRead.take(response, of: signedIn(URL(string: "https://app.example.com/")!), into: store)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await store.httpCookieStore.allCookies().isEmpty)
    }

    @Test func aSessionTurnedOverReachesTheStore() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let url = URL(string: "https://app.example.com/api/session")!
        await store.httpCookieStore.setCookie(HTTPCookie(properties: [.name: "sid", .value: "S3", .domain: "app.example.com", .path: "/"])!)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "sid=S4; Path=/; HttpOnly, theme=dark; Path=/; Max-Age=3600"])
        AgentRead.take(response, of: signedIn(url), into: store)
        let all = try await cookies(store) { $0.contains { $0.name == "sid" && $0.value == "S4" } }
        let sid = all.first { $0.name == "sid" }
        #expect(sid?.value == "S4")
        #expect(sid?.isHTTPOnly == true)
        #expect(sid?.isSessionOnly == true)
        #expect(all.first { $0.name == "theme" }?.value == "dark")
        #expect(all.filter { $0.name == "sid" }.count == 1)
    }

    @Test func aCookieForAnotherSiteIsRefused() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let url = URL(string: "https://app.example.com/")!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Set-Cookie": "stolen=1; Domain=other.example.org; Path=/, wide=1; Domain=com; Path=/, "
                                                        + "parent=1; Domain=example.com; Path=/, ok=1; Path=/"])
        AgentRead.take(response, of: signedIn(url), into: store)
        let all = try await cookies(store) { $0.contains { $0.name == "ok" } && $0.contains { $0.name == "parent" } }
        #expect(all.contains { $0.name == "ok" })
        #expect(all.contains { $0.name == "parent" })
        #expect(!all.contains { $0.name == "stolen" })
        #expect(!all.contains { $0.name == "wide" })
    }
}
