import XCTest
@testable import Fast

// Which frames may ask to open another app (feedback #143/#144): the page
// itself and a hidden frame of its own site, as Slack's "Redirecting..."
// page uses; another site's frame only with a press in it.

@MainActor
final class AppLinkFramesTests: XCTestCase {
    func testThePageItselfAsks() {
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: true, sourceHost: "acme.slack.com", pageHost: "acme.slack.com", gesture: false))
    }

    func testAFrameOfThePagesOwnSiteAsks() {
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: false, sourceHost: "acme.slack.com", pageHost: "acme.slack.com", gesture: false))
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: false, sourceHost: "a.slack-edge.com", pageHost: "a.slack-edge.com", gesture: false))
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: false, sourceHost: "app.slack.com", pageHost: "acme.slack.com", gesture: false))
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: false, sourceHost: "127.0.0.1", pageHost: "127.0.0.1", gesture: false))
    }

    func testAnotherSitesFrameOnItsOwnIsIgnored() {
        XCTAssertFalse(Browser.pageAsks(sourceIsPage: false, sourceHost: "ads.example.net", pageHost: "news.example.com", gesture: false))
        XCTAssertFalse(Browser.pageAsks(sourceIsPage: false, sourceHost: "localhost", pageHost: "127.0.0.1", gesture: false))
    }

    func testAFrameWithNoOriginOfItsOwnIsIgnored() {
        // A sandboxed frame's origin is opaque: no host.
        XCTAssertFalse(Browser.pageAsks(sourceIsPage: false, sourceHost: "", pageHost: "news.example.com", gesture: false))
        XCTAssertFalse(Browser.pageAsks(sourceIsPage: false, sourceHost: "news.example.com", pageHost: nil, gesture: false))
    }

    func testAPressInAnotherSitesFrameAsks() {
        XCTAssertTrue(Browser.pageAsks(sourceIsPage: false, sourceHost: "zoom.us", pageHost: "calendar.google.com", gesture: true))
    }
}
