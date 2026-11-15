import Foundation
import Testing
@testable import Fast

@MainActor
struct StoreCatalogTests {
    private func item(_ check: StoreCatalog.Check?) -> StoreCatalog.Item {
        StoreCatalog.Item(id: "youtube-no-shorts", name: "Hide Shorts", intent: "Hide YouTube Shorts shelves and Shorts links.",
                          sites: ["www.youtube.com"], host: "youtube.com", rung: "Look", rights: "Change how youtube.com looks. No code runs.",
                          revision: nil, commit: nil, by: "Yab", picks: true, added: nil, fixed: nil, check: check, kept: nil, pictures: nil, versions: nil, reviewed: nil)
    }

    @Test func readsTheContractsCatalog() throws {
        let json = """
        {"format":1,"generated":"2026-10-04T06:10:00Z","items":[{"id":"youtube-no-shorts","name":"Hide Shorts",
        "intent":"Hide YouTube Shorts shelves and Shorts links.","sites":["www.youtube.com"],"host":"youtube.com","rung":"Look",
        "rights":"Change how youtube.com looks. No code runs.","revision":"\(String(repeating: "a", count: 64))","commit":"4ac91e2","by":"Yab",
        "picks":true,"added":"2026-10-03","fixed":null,"check":{"state":"works","at":"2026-10-04T06:10:00Z","note":null},"kept":2340,
        "pictures":{"before":"/store/p/youtube-no-shorts/before.webp","after":"/store/p/youtube-no-shorts/after.webp"},
        "versions":[{"commit":"4ac91e2","date":"2026-10-03","note":"First version"}]}]}
        """
        let items = try #require(StoreCatalog.decode(Data(json.utf8)))
        #expect(items.count == 1)
        #expect(items[0].kept == 2340)
        #expect(items[0].check?.state == "works")
        #expect(items[0].pictures?.after == "/store/p/youtube-no-shorts/after.webp")
        #expect(!items[0].plugin)
        #expect(StoreCatalog.decode(Data(#"{"format":2,"items":[]}"#.utf8)) == nil)
        #expect(StoreCatalog.decode(Data("not json".utf8)) == nil)
    }

    @Test func saysWhatTheCheckFoundInWords() {
        let catalog = StoreCatalog.shared
        #expect(catalog.checked(item(.init(state: "works", at: Date().addingTimeInterval(-3600)))) == "Works today")
        #expect(catalog.checked(item(.init(state: "works", at: Date().addingTimeInterval(-40 * 3600)))) == nil)
        #expect(catalog.checked(item(.init(state: "fix", at: Date()))) == "Needs Fix")
        #expect(catalog.checked(item(.init(state: "unchecked", at: Date(), note: "needs sign-in"))) == "Not checked: needs sign-in")
        #expect(catalog.checked(item(nil)) == nil)
    }

    @Test func theShippedShelfStandsInWithoutClaims() {
        let shelf = StoreCatalog.bundled
        #expect(shelf.count == BoostCatalog.entries.count)
        #expect(shelf.allSatisfy { $0.check == nil && $0.kept == nil && $0.rights.hasSuffix("No code runs.") })
        #expect(shelf.first { $0.id == "youtube-no-shorts" }?.host == "youtube.com")
    }

    private static let site = URL(string: "https://yetanotherbrowser.com/store/catalog.json")

    private func plugin(_ revision: String, reviewed: StoreCatalog.Reviewed? = .init(by: "samrivera", date: "2026-10-04", commit: "4ac91e2")) -> StoreCatalog.Item {
        StoreCatalog.Item(id: "sponsor-skip", name: "Sponsor skip", intent: "Skip sponsored segments.", sites: ["example.com"], host: "example.com",
                          rung: "Page", rights: "Run code on example.com. It can read and change these pages. Talks to api.example.com.",
                          revision: revision, commit: "4ac91e2", by: "samrivera", picks: nil, added: nil, fixed: nil, check: nil, kept: nil,
                          pictures: nil, versions: nil, reviewed: reviewed)
    }

    /// A Page package as the Store serves it, with its revision.
    private func envelope() throws -> (data: Data, revision: String) {
        let files = BoostTests.pageFiles(hosts: ["api.example.com"])
        let payload = BoostShare.Payload(format: 1, id: "sponsor-skip", sites: ["example.com"], files: files)
        let revision = try BoostShare.digest(payload)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try encoder.encode(BoostShare.Envelope(revision: revision, payload: payload)), revision)
    }

    @Test func readsReviewedReleases() throws {
        let json = """
        {"format":1,"items":[{"id":"sponsor-skip","name":"Sponsor skip","intent":"Skip.","sites":["www.youtube.com"],"host":"youtube.com",
        "rung":"Page","rights":"Run code on youtube.com.","revision":"\(String(repeating: "b", count: 64))","by":"Yab",
        "reviewed":{"by":"samrivera","date":"2026-10-04","commit":"4ac91e2"}}]}
        """
        let items = try #require(StoreCatalog.decode(Data(json.utf8)))
        #expect(items[0].reviewed == .init(by: "samrivera", date: "2026-10-04", commit: "4ac91e2"))
        #expect(items[0].plugin)
    }

    @Test func codeInstallsOnlyAsTheReviewedReleaseFromTheSite() throws {
        let (data, revision) = try envelope()
        let item = plugin(revision)
        #expect(StoreCatalog.codeRefusal(item, origin: Self.site, listed: [item]) == nil)
        // No review, another origin, plain HTTP, or the shelf shipped with Yab.
        #expect(StoreCatalog.codeRefusal(plugin(revision, reviewed: nil), origin: Self.site, listed: [plugin(revision, reviewed: nil)]) != nil)
        for origin in [URL(string: "http://yetanotherbrowser.com/store/catalog.json"), URL(string: "https://127.0.0.1:8443/store/catalog.json"),
                       URL(string: "https://yetanotherbrowser.com.evil.test/store/catalog.json"), nil] {
            #expect(StoreCatalog.codeRefusal(item, origin: origin, listed: [item]) != nil)
        }
        // The catalog lists another revision of it.
        #expect(StoreCatalog.codeRefusal(item, origin: Self.site, listed: [plugin(String(repeating: "c", count: 64))]) != nil)
        // The package: code only with the revision the listing names.
        #expect(throws: Error.self) { try BoostShare.read(data) }
        #expect(throws: Error.self) { try BoostShare.read(data, reviewed: String(repeating: "c", count: 64)) }
        let package = try BoostShare.read(data, reviewed: revision)
        #expect(package.rung == .page)
        #expect(package.id == "shared-" + revision.prefix(16))
        #expect(try BoostShare.read(data, id: "kept-skip", reviewed: revision).id == "kept-skip")
    }

}
