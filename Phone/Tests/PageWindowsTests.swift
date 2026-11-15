import WebKit
import XCTest
@testable import YabPhone

/// The judgment itself; PageWindowsUITests has the fingers on real pages.
final class PageWindowsTests: XCTestCase {
    private let main = PageWindows.Asker(frame: nil, isSubframe: false)
    private let adFrame = PageWindows.Asker(frame: "ads.net", isSubframe: true)
    private let ownFrame = PageWindows.Asker(frame: "news.com", isSubframe: true)

    func testOneTapOneWindow() {
        XCTAssertTrue(PageWindows.opens(link: false, spent: false, asker: main, page: "news.com", going: "x.com"))
        XCTAssertFalse(PageWindows.opens(link: false, spent: true, asker: main, page: "news.com", going: "x.com"))
        XCTAssertTrue(PageWindows.opens(link: true, spent: true, asker: main, page: "news.com", going: "x.com"), "a link is never judged")
    }

    func testAnotherSitesFrame() {
        XCTAssertFalse(PageWindows.opens(link: false, spent: false, asker: adFrame, page: "news.com", going: "casino.bet"))
        XCTAssertTrue(PageWindows.opens(link: false, spent: false, asker: adFrame, page: "news.com", going: "ads.net"), "its own site")
        XCTAssertTrue(PageWindows.opens(link: false, spent: false, asker: adFrame, page: "news.com", going: "news.com"), "the page's site")
        XCTAssertTrue(PageWindows.opens(link: false, spent: false, asker: adFrame, page: "news.com", going: nil), "nowhere yet")
        XCTAssertTrue(PageWindows.opens(link: true, spent: false, asker: adFrame, page: "news.com", going: "casino.bet"), "its link")
        XCTAssertTrue(PageWindows.opens(link: false, spent: false, asker: ownFrame, page: "news.com", going: "casino.bet"), "the page's own frame")
        XCTAssertFalse(PageWindows.opens(link: false, spent: false, asker: .init(frame: nil, isSubframe: true), page: "news.com", going: "casino.bet"), "an opaque frame")
    }

    func testThePageGoingElsewhere() {
        func follows(_ type: WKNavigationType = .other, _ asker: PageWindows.Asker? = nil, page: String? = "news.com",
                     going: String? = "casino.bet", behind: Bool = false) -> Bool {
            PageWindows.follows(navigation: type, asker: asker ?? main, page: page, going: going, behind: behind)
        }
        XCTAssertTrue(follows(), "a page sending itself elsewhere stays allowed")
        XCTAssertFalse(follows(behind: true), "the tab-under")
        XCTAssertFalse(follows(.other, adFrame), "another site's frame")
        XCTAssertTrue(follows(.linkActivated, adFrame, behind: true), "a link")
        XCTAssertTrue(follows(.backForward, behind: true))
        XCTAssertTrue(follows(.reload, behind: true))
        XCTAssertTrue(follows(going: "news.com", behind: true), "its own site")
        XCTAssertTrue(follows(page: nil, behind: true), "nothing here yet")
        XCTAssertTrue(follows(going: nil, behind: true), "not a web address")
    }

    func testSites() {
        XCTAssertEqual(PageWindows.site(of: "www.News.com"), "news.com")
        XCTAssertEqual(PageWindows.site(of: "a.b.news.com."), "news.com")
        XCTAssertEqual(PageWindows.site(of: "localhost"), "localhost")
        XCTAssertEqual(PageWindows.site(of: "127.0.0.1"), "127.0.0.1")
        XCTAssertEqual(PageWindows.site(of: "::1"), "::1")
        XCTAssertNil(PageWindows.site(of: ""))
        XCTAssertNil(PageWindows.site(of: URL(string: "about:blank")))
        XCTAssertEqual(PageWindows.site(of: URL(string: "https://m.x.com/a")), "x.com")
    }
}
