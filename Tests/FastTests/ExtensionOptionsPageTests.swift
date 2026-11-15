import Foundation
import Testing
@testable import Fast

/// An options page asked for again brings its open tab forward, a
/// singleton tab, whatever its fragment (feedback #322).
@Suite struct ExtensionOptionsPageTests {
    private let page = URL(string: "yab-extension://abc/options/options.html")!

    @Test func theSamePageWhateverItsFragment() {
        #expect(Extensions.samePage(page, page))
        #expect(Extensions.samePage(URL(string: "yab-extension://abc/options/options.html#sites")!, page))
    }

    @Test func anotherPageOrExtensionIsNot() {
        #expect(!Extensions.samePage(URL(string: "yab-extension://abc/options/popup.html")!, page))
        #expect(!Extensions.samePage(URL(string: "yab-extension://xyz/options/options.html")!, page))
        #expect(!Extensions.samePage(URL(string: "yab-extension://abc/options/options.html?tab=2")!, page))
    }
}
