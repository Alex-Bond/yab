import Foundation
import Testing
import SyncKit
@testable import Fast

/// Now's mail rows as `now` records for the iPhone's widget (SyncNow): only
/// mail rows go, at most three, each with what a mail app needs to find the
/// thread, and a Mac removes only its own.
struct SyncNowTests {
    init() { SyncShapes.register() }

    private func mail(_ thread: String, title: String = "Danny says hi", account: String = "me@example.com") -> Hint {
        var parts = URLComponents(string: "yab://mail")!
        parts.fragment = "thread=" + account + "|" + thread
        return Hint(id: "mail." + thread, icon: .site("example.com"), title: title, detail: "12m · Re: Hi", url: parts.url,
                    source: .noticed, sender: Hint.Sender(address: "danny@example.com", name: "Danny"))
    }

    @Test func onlyMailRowsGoAtMostThree() {
        let link = Hint(id: "copied", icon: .symbol("link"), title: "A link", detail: "", url: URL(string: "https://example.com"), source: .noticed)
        let skipped = Hint(id: "mail.skipped", icon: .symbol("archivebox"), title: "4 archived", detail: "", url: URL(string: "yab://mail#list=x"), source: .noticed)
        let found = Hint(id: "mail.agent", icon: .face, title: "Found", detail: "", url: URL(string: "yab://mail#thread=a|b"), source: .found)
        let rows = SyncNow.rows([link, mail("t1"), skipped, found, mail("t2"), mail("t3"), mail("t4")]) { _, thread in "<\(thread)@mail>" }
        #expect(rows.map(\.id) == ["mail.t1", "mail.t2", "mail.t3"])
        #expect(rows[0].who == "Danny" && rows[0].host == "example.com" && rows[0].message == "<t1@mail>")
        #expect(rows[0].web == "https://mail.google.com/mail/u/me@example.com/#all/t1")
    }

    @Test func aMacRemovesOnlyItsOwnRows() throws {
        let journal = try Journal(path: nil, device: "mac-a")
        let a = SyncNow.rows([mail("t1"), mail("t2")]) { _, _ in "" }
        try SyncNow.reconcile(journal, a, device: "mac-a")
        try journal.change(.init(collection: SyncNow.now, id: "mail.b1"), ["title": "From B", "device": "mac-b"])
        let all = journal.all(SyncNow.now).filter { $0.alive() }
        #expect(Set(all.map(\.id)) == ["mail.t1", "mail.t2", "mail.b1"])
        #expect(all.first { $0.id == "mail.t1" }?["order"] == .number(0) && all.first { $0.id == "mail.t1" }?["message"] == nil)

        // Danny answered on this Mac: his row leaves, Mac B's stays.
        try SyncNow.reconcile(journal, Array(a.dropFirst()), device: "mac-a")
        #expect(Set(journal.all(SyncNow.now).filter { $0.alive() }.map(\.id)) == ["mail.t2", "mail.b1"])
    }
}
