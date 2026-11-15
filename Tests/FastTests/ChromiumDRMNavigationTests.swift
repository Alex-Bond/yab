import Foundation
import Testing
import YabCoreClient
@testable import Fast

struct ChromiumDRMNavigationTests {
    private let url = URL(string: "https://navigation.test/next")!

    @Test func preservesTheWebKitReferrerWithoutCredentialsOrFragment() throws {
        var request = URLRequest(url: url)
        request.setValue("https://user:secret@navigation.test/before#part", forHTTPHeaderField: "Referer")
        let navigation = try ChromiumDRMNavigation(request)
        #expect(navigation.parameters == ["url": .string(url.absoluteString),
                                           "referrer": .string("https://navigation.test/before")])
    }

    @Test func urlOnlyAndEmptyReferrerRemainOrdinaryGETs() throws {
        var request = URLRequest(url: url)
        #expect(try ChromiumDRMNavigation(request).parameters == ["url": .string(url.absoluteString)])
        request.setValue("", forHTTPHeaderField: "Referer")
        #expect(try ChromiumDRMNavigation(request).parameters == ["url": .string(url.absoluteString)])
    }

    @Test func rejectsBodiesStreamsCustomHeadersAndNonWebReferrers() {
        var post = URLRequest(url: url); post.httpMethod = "POST"
        var body = URLRequest(url: url); body.httpBody = Data("body".utf8)
        var stream = URLRequest(url: url); stream.httpBodyStream = InputStream(data: Data("body".utf8))
        var custom = URLRequest(url: url); custom.setValue("private", forHTTPHeaderField: "X-Custom")
        var referrer = URLRequest(url: url); referrer.setValue("file:///private/file", forHTTPHeaderField: "Referer")
        for request in [post, body, stream, custom, referrer] {
            #expect(throws: (any Error).self) { try ChromiumDRMNavigation(request) }
        }
    }

    @Test func onlyWebKitRoutingRecomputesItsEngineHeaders() throws {
        var request = URLRequest(url: url)
        request.setValue("Synthetic Safari agent", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("https://navigation.test/before", forHTTPHeaderField: "Referer")
        #expect(throws: (any Error).self) { try ChromiumDRMNavigation(request) }
        let routed = ChromiumDRMNavigation.webKitDocument(request)
        #expect(routed.value(forHTTPHeaderField: "User-Agent") == nil)
        #expect(routed.value(forHTTPHeaderField: "Accept") == nil)
        #expect(try ChromiumDRMNavigation(routed).parameters["referrer"] == .string("https://navigation.test/before"))
        request.setValue("synthetic", forHTTPHeaderField: "Authorization")
        let unsupported = ChromiumDRMNavigation.webKitDocument(request)
        #expect(unsupported.value(forHTTPHeaderField: "Authorization") == "synthetic")
        #expect(throws: (any Error).self) { try ChromiumDRMNavigation(unsupported) }
    }
}
