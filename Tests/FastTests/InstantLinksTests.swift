import Foundation
import Testing
@testable import Fast

struct InstantLinksTests {
    @Test func queryPartsAndLimits() {
        #expect(InstantLinks.requests("  alpha, beta, , gamma  ") == [.init(words: "alpha", count: 1), .init(words: "beta", count: 1), .init(words: "gamma", count: 1)])
        #expect(InstantLinks.requests("OPEN the top 3 ramen in tokyo") == [.init(words: "ramen in tokyo", count: 3)])
        #expect(InstantLinks.requests("top 99 swift guides") == [.init(words: "swift guides", count: 5)])
        #expect(InstantLinks.requests("a,b,c,d,e,f").count == 5)
        #expect(InstantLinks.requests(" , , ").isEmpty)
        #expect(InstantLinks.requests(" ").isEmpty)
        #expect(InstantLinks.requests("top 0 cats") == [.init(words: "top 0 cats", count: 1)])
    }

    @Test func commaInAURLStaysOneAddress() {
        let url = "https://example.org/a,b?q=one,two"
        #expect(InstantLinks.requests(url) == [.init(words: url, count: 1)])
    }

    @Test func redirectsSchemesControlsAndDuplicates() throws {
        let search = try #require(URL(string: "https://www.google.com/search?q=test"))
        let strings = ["javascript:alert(1)", "file:///tmp/x", "https://www.google.com/preferences", "https://user:pass@example.net/",
                       "/url?q=https%3A%2F%2Fexample.org%2Ffirst&sa=U", "https://example.org/first", "https://example.org/second"]
        #expect(InstantLinks.destinations(strings, from: search, count: 3).map(\.absoluteString) == ["https://example.org/first", "https://example.org/second"])
        #expect(InstantLinks.destinations(strings, from: search, count: 1).count == 1)
    }

    @Test func duckDuckGoAndBingRedirects() throws {
        let ddg = try #require(URL(string: "https://duckduckgo.com/?q=test"))
        #expect(InstantLinks.destinations(["https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.net%2F"], from: ddg, count: 1).first?.host == "example.net")
        let bing = try #require(URL(string: "https://www.bing.com/search?q=test"))
        let encoded = Data("https://example.org/bing".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(InstantLinks.destinations(["https://www.bing.com/ck/a?u=a1" + encoded], from: bing, count: 1).first?.path == "/bing")
        #expect(InstantLinks.destinations(["https://www.bing.com/ck/a?u=a1!"], from: bing, count: 1).isEmpty)
    }

    @Test func opaqueGoogleResultsRemainNavigable() throws {
        let search = try #require(URL(string: "https://www.google.com/search?q=test"))
        let redirect = "https://www.google.com/goto?url=CAESOpaqueTarget"
        let links = ["https://www.google.com/preferences", "https://www.google.com/goto?url=", redirect, redirect]
        #expect(InstantLinks.destinations(links, from: search, count: 3).map(\.absoluteString) == [redirect])
        let other = try #require(URL(string: "https://example.net/search?q=test"))
        #expect(InstantLinks.destinations(["https://example.net/goto?url=opaque"], from: other, count: 1).isEmpty)
    }

    @Test func unsupportedEngineHasAVisibleFallback() {
        #expect(InstantLinks.script(engine: .custom) == nil)
        for engine in Engine.allCases where engine != .custom { #expect(InstantLinks.script(engine: engine) != nil) }
    }
}
