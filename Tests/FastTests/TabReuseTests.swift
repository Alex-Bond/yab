import Foundation
import Testing
@testable import Fast

// Normalized page keys only deduplicate disposable tabs left by finished agents.
struct TabReuseTests {
    @Test func samePageLeavesOutWhatOnlySaysWhereALinkCameFrom() {
        let page = TabReuse.page(URL(string: "https://x.com/dwhitedesign/status/2112132907162853477")!)
        #expect(TabReuse.page(URL(string: "https://www.x.com/dwhitedesign/status/2112132907162853477/?utm_source=a&fbclid=b#reply")!) == page)
        #expect(TabReuse.page(URL(string: "http://x.com/dwhitedesign/status/2112132907162853477")!) == page)
        #expect(TabReuse.page(URL(string: "https://x.com/dwhitedesign/status/1")!) != page)
        // What the query says that matters stays, in any order.
        #expect(TabReuse.page(URL(string: "https://a.com/s?q=1&p=2")!) == TabReuse.page(URL(string: "https://a.com/s?p=2&q=1")!))
        #expect(TabReuse.page(URL(string: "https://a.com/s?q=1")!) != TabReuse.page(URL(string: "https://a.com/s?q=2")!))
        #expect(TabReuse.page(URL(string: "yab://task/1")!) == nil)
        #expect(TabReuse.site(URL(string: "https://www.github.com/a")!) == "github.com")
    }

}
