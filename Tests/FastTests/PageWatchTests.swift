import Foundation
import Testing
@testable import Fast

// watch_page's check runner and the words around it (PageWatches.swift):
// what a check makes of a page, when it reads, wakes, and what it says.
struct PageWatchTests {
    static let price = """
    const m = text.match(/Price:\\s*\\$([\\d,.]+)/);
    if (!m) return null;
    const p = number(m[1]);
    return { value: '$' + p, holds: p < 200 };
    """

    static func watch(until: String = "under $200", tell: String? = nil, every: Double = 30) -> PageWatch {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return PageWatch(id: "w1", url: "https://shop.test/p", name: "Sony WH-1000XM6", until: until, check: price, tell: tell,
                         every: every, started: now, expires: now.addingTimeInterval(30 * 86_400))
    }

    @Test func aPriceAboveTheLineDoesNotHold() {
        #expect(PageWatchCheck.run(Self.price, text: "Sony WH-1000XM6\nPrice: $249.99\nAdd to cart") == .not("$249.99"))
    }

    @Test func aPriceUnderTheLineHolds() {
        #expect(PageWatchCheck.run(Self.price, text: "Price: $189") == .holds("$189"))
        #expect(PageWatchCheck.run(Self.price, text: "Price: $1,189.50") == .not("$1189.5"))
    }

    @Test func numberReadsPricesAsPeopleWriteThem() {
        let check = "return { value: String(number(text)), holds: false };"
        #expect(PageWatchCheck.run(check, text: "Now only $1,299.99!") == .not("1299.99"))
        #expect(PageWatchCheck.run(check, text: "US$\u{00a0}74") == .not("74"))
        #expect(PageWatchCheck.run(check, text: "no digits") == .not("NaN"))
    }

    @Test func inStockReadsWords() {
        let check = """
        const out = /out of stock|sold out/i.test(text);
        const inStock = /in stock|add to cart/i.test(text);
        return { value: out ? 'Out of stock' : inStock ? 'In stock' : 'Unknown', holds: !out && inStock };
        """
        #expect(PageWatchCheck.run(check, text: "Currently out of stock") == .not("Out of stock"))
        #expect(PageWatchCheck.run(check, text: "In stock. Ships tomorrow.") == .holds("In stock"))
    }

    @Test func htmlAndJSONAreThere() {
        let ld = """
        const m = html.match(/"price"\\s*:\\s*"?([\\d.]+)/);
        return m ? { value: '$' + m[1], holds: number(m[1]) < 200 } : null;
        """
        let html = #"<script type="application/ld+json">{"offers":{"price":"179.00"}}</script><p>Loading…</p>"#
        #expect(PageWatchCheck.run(ld, text: "Loading…", html: html) == .holds("$179.00"))
        let api = "return { value: json.status, holds: json.status === 'shipped' };"
        #expect(PageWatchCheck.run(api, text: #"{"status":"processing"}"#) == .not("processing"))
        #expect(PageWatchCheck.run(api, text: #"{"status":"shipped"}"#) == .holds("shipped"))
        #expect(PageWatchCheck.run("return { value: url, holds: false };", text: "", url: "https://shop.test/p") == .not("https://shop.test/p"))
    }

    @Test func aCheckThatReadsNothingIsAMiss() {
        #expect(PageWatchCheck.run(Self.price, text: "This page has moved") == .miss("the check found nothing on the page"))
        guard case .miss(let thrown) = PageWatchCheck.run("return text.nope.deeper;", text: "x") else { Issue.record("no miss"); return }
        #expect(thrown.contains("TypeError"))
        guard case .miss = PageWatchCheck.run("return {", text: "x") else { Issue.record("a broken script read something"); return }
        #expect(PageWatchCheck.run("return { value: '$5' };", text: "x") == .miss("the check returned no holds: true or false"))
        #expect(PageWatchCheck.run("return { value: '', holds: true };", text: "x") == .miss("the check returned no value"))
        #expect(PageWatchCheck.run("return 5;", text: "x") == .miss("the check returned no holds: true or false"))
    }

    @Test func aCheckThatRunsForeverIsStopped() {
        let started = Date()
        let read = PageWatchCheck.run("while (true) {}", text: "x", seconds: 0.3)
        #expect(read == .miss("the check ran too long"))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func aCheckHasNoPageAndNoNetwork() {
        let check = "return { value: [typeof document, typeof fetch, typeof XMLHttpRequest].join(','), holds: false };"
        #expect(PageWatchCheck.run(check, text: "") == .not("undefined,undefined,undefined"))
    }

    @Test func theSentenceItSays() {
        #expect(PageWatchCheck.sentence(Self.watch(tell: "Sony WH-1000XM6 is {value}, under the $200 you asked for"), value: "$189")
                == "Sony WH-1000XM6 is $189, under the $200 you asked for")
        #expect(PageWatchCheck.sentence(Self.watch(), value: "$189") == "Sony WH-1000XM6 is $189 (under $200)")
        #expect(PageWatchCheck.sentence(Self.watch(tell: "It's back"), value: "In stock") == "It's back")
    }

    @Test func theRowSaysWatchingThenTheValue() {
        var watch = Self.watch()
        let now = watch.started.addingTimeInterval(3600)
        #expect(PageWatchCheck.words(watch, now: now)?.text == "Watching: under $200")
        #expect(PageWatchCheck.words(watch, now: now)?.loud == false)
        #expect(PageWatchCheck.words(watch, now: now, short: true)?.text == "Watching")
        watch.held = now
        watch.value = "$189"
        #expect(PageWatchCheck.words(watch, now: now.addingTimeInterval(60))?.text == "$189")
        #expect(PageWatchCheck.words(watch, now: now.addingTimeInterval(60))?.loud == true)
        #expect(PageWatchCheck.words(watch, now: now.addingTimeInterval(60), short: true)?.text == "$189")
        #expect(PageWatchCheck.words(watch, now: now.addingTimeInterval(PageWatchCheck.shownFor + 1)) == nil)
        #expect(PageWatchCheck.words(Self.watch(), now: Self.watch().expires) == nil)
    }

    @Test func itReadsEverySoManyMinutes() {
        var watch = Self.watch(every: 30)
        #expect(PageWatchCheck.due(watch, now: watch.started))
        watch.checked = watch.started
        #expect(!PageWatchCheck.due(watch, now: watch.started.addingTimeInterval(29 * 60)))
        #expect(PageWatchCheck.due(watch, now: watch.started.addingTimeInterval(30 * 60)))
        #expect(!PageWatchCheck.due(watch, now: watch.expires))
        watch.held = watch.started
        #expect(!PageWatchCheck.due(watch, now: watch.started.addingTimeInterval(3600)))
    }

    @Test func threeMissesInARowWakeOnce() {
        var watch = Self.watch()
        watch.misses = 2
        #expect(!PageWatchCheck.wakes(watch))
        watch.misses = 3
        #expect(PageWatchCheck.wakes(watch))
        watch.woke = true
        watch.misses = 7
        #expect(!PageWatchCheck.wakes(watch))
    }

    @Test func pagesAreKeptWithoutTheirFragment() {
        #expect(PageWatchCheck.key(URL(string: "https://shop.test/p?id=4#reviews")) == "https://shop.test/p?id=4")
        #expect(PageWatchCheck.key(URL(string: "file:///tmp/a.html")) == nil)
        #expect(PageWatchCheck.key(nil) == nil)
    }
}
