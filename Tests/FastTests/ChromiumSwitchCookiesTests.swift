import Foundation
import Testing
@testable import Fast

struct ChromiumSwitchCookiesTests {
    private func cookie(_ value: String) -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "session", .value: value, .domain: "switch.test", .path: "/",
            .discard: "TRUE", .sameSitePolicy: "lax"])!)
    }

    @Test func restartRetainsBothDirectionsOfSignOut() throws {
        let saved = cookie("synthetic-account")
        let map = [saved.key: saved]
        let ledger = ChromiumSwitchCookieLedger(webKit: ChromiumSwitchCookieLedger.fingerprint(map),
                                                chromium: ChromiumSwitchCookieLedger.fingerprint(map))
        let restarted = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(ledger))
        let webKitSignOut = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: map, previous: restarted)
        #expect(webKitSignOut.toWebKit.isEmpty)
        #expect(webKitSignOut.toChromium.count == 1 && webKitSignOut.toChromium[0].cookie == nil)
        let chromiumSignOut = ChromiumDRMCookieMerge.plan(webKit: map, chromium: [:], previous: restarted)
        #expect(chromiumSignOut.toChromium.isEmpty)
        #expect(chromiumSignOut.toWebKit.count == 1 && chromiumSignOut.toWebKit[0].cookie == nil)
    }

    @Test func restartCopiesEditsAndKeepsTheExistingConflictPolicy() {
        let saved = cookie("before"), edited = cookie("after"), remote = cookie("concurrent")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let plan = ChromiumDRMCookieMerge.plan(webKit: [saved.key: edited], chromium: [saved.key: remote], previous: ledger)
        #expect(plan.toWebKit.isEmpty)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].cookie == edited)
        let remoteOnly = ChromiumDRMCookieMerge.plan(webKit: [saved.key: saved], chromium: [saved.key: edited], previous: ledger)
        #expect(remoteOnly.toChromium.isEmpty)
        #expect(remoteOnly.toWebKit.count == 1 && remoteOnly.toWebKit[0].cookie == edited)
    }

    private func cookie(_ name: String, _ value: String = "one", domain: String, path: String = "/", session: Bool = false) -> ChromiumDRMCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .sameSitePolicy: "lax"]
        if session { properties[.discard] = "TRUE" } else { properties[.expires] = Date(timeIntervalSince1970: 2_000_000_000) }
        return ChromiumDRMCookie(HTTPCookie(properties: properties)!)
    }

    @Test func aRefusedCookieIsNeitherRetriedNorTakenForASignOut() {
        let refused = cookie("big", domain: "switch.test")
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        book.record(scope, webKit: [refused.key: refused], chromium: [:])
        let plan = ChromiumDRMCookieMerge.plan(webKit: [refused.key: refused], chromium: [:], previous: book.slice(scope))
        #expect(plan.toChromium.isEmpty && plan.toWebKit.isEmpty)
        // Edited in WebKit it is a new cookie, and Chromium is asked again.
        let edited = cookie("big", "two", domain: "switch.test")
        let again = ChromiumDRMCookieMerge.plan(webKit: [refused.key: edited], chromium: [:], previous: book.slice(scope))
        #expect(again.toChromium.count == 1 && again.toChromium[0].cookie == edited)
    }

    @Test func aHostsSliceLeavesEveryOtherHostAlone() {
        let mine = cookie("a", domain: ".switch.test"), other = cookie("b", domain: "other.test"), deep = cookie("c", domain: "app.switch.test", path: "/deep")
        var book = ChromiumCookieBook()
        let all = [mine.key: mine, deep.key: deep]
        book.record(book.scope(host: "app.switch.test", seen: ["/deep"]), webKit: all, chromium: all)
        book.record(book.scope(host: "other.test", seen: []), webKit: [other.key: other], chromium: [other.key: other])
        // What was seen on a path is looked for on that path again.
        let scope = book.scope(host: "app.switch.test", seen: [])
        #expect(scope.paths == ["/", "/deep"])
        #expect(scope.urls.map(\.absoluteString) == ["https://app.switch.test/", "https://app.switch.test/deep"])
        let slice = book.slice(scope)
        #expect(Set(slice.webKit.keys) == [mine.key, deep.key])
        // The other host isn't read, so it isn't a sign-out.
        #expect(ChromiumDRMCookieMerge.plan(webKit: all, chromium: all, previous: slice).toWebKit.isEmpty)
        #expect(book.ledger.webKit[other.key] != nil)
        // A sign-out on one host stays a sign-out, the rest of the book as it was.
        let plan = ChromiumDRMCookieMerge.plan(webKit: [deep.key: deep], chromium: all, previous: slice)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].key == mine.key && plan.toChromium[0].cookie == nil)
        book.record(scope, webKit: [deep.key: deep], chromium: [deep.key: deep])
        #expect(book.ledger.webKit[mine.key] == nil && book.ledger.webKit[other.key] != nil)
    }

    @Test func aCookieOnAnotherPathIsNotReadSoNotDeleted() {
        let scope = ChromiumCookieScope(host: "switch.test", paths: ["/app"])
        #expect(scope.covers(cookie("a", domain: "switch.test", path: "/app").key))
        #expect(scope.covers(cookie("a", domain: "switch.test", path: "/").key))
        #expect(!scope.covers(cookie("a", domain: "switch.test", path: "/apple").key))
        #expect(!scope.covers(cookie("a", domain: "switch.test", path: "/other").key))
        #expect(!scope.covers(cookie("a", domain: "a.switch.test").key))
        #expect(scope.covers(cookie("a", domain: ".switch.test").key))
    }

    private func row(_ cookie: ChromiumDRMCookie) -> ChromiumCookieImportRow {
        ChromiumCookieImportRow(cookie: cookie, fingerprint: ChromiumSwitchCookieLedger.fingerprint(cookie), payload: cookie.chromium)
    }

    @Test func aNewHelpersLostSessionCookiesGoBackAndStayKnown() throws {
        // A new helper has lasting cookies only. WebKit's session copies go back
        // at once and the ledger is kept, so a sign-out after it is one.
        let session = cookie("sid", domain: "switch.test", session: true), lasting = cookie("keep", domain: "switch.test")
        let both = [session.key: session, lasting.key: lasting]
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        book.record(scope, webKit: both, chromium: both)
        #expect(book.ledger.session == [session.key])
        let relaunched = ChromiumCookieBook(ledger: try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(book.ledger)))
        let lost = relaunched.lostWithHelper([row(session), row(lasting)])
        #expect(lost.back.map(\.cookie) == [session] && lost.forget.isEmpty)
        // Put back, then Chromium signs out on a hop nobody read yet: a deletion, never a copy back.
        let plan = ChromiumDRMCookieMerge.plan(webKit: both, chromium: [lasting.key: lasting], previous: relaunched.slice(scope))
        #expect(plan.toChromium.isEmpty)
        #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].key == session.key && plan.toWebKit[0].cookie == nil)
    }

    @Test func aSessionCookieWebKitChangedOrTheJarsDisagreedOnIsNotPutBackAsItWas() {
        let agreed = cookie("sid", "one", domain: "switch.test", session: true), mine = cookie("own", "chromium", domain: "switch.test", session: true)
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "switch.test", seen: [])
        let theirs = cookie("own", "webkit", domain: "switch.test", session: true)
        book.record(scope, webKit: [agreed.key: agreed, theirs.key: theirs], chromium: [agreed.key: agreed, mine.key: mine])
        // WebKit signed out of `sid` while Chromium was off: nothing to put back, and it stays known.
        let lost = book.lostWithHelper([row(theirs)])
        #expect(lost.back.isEmpty)
        // `own` held different values: Chromium's is gone, so both sides are forgotten.
        #expect(lost.forget == [mine.key])
        book.forget(lost.forget)
        #expect(book.ledger.webKit[mine.key] == nil && book.ledger.webKit[agreed.key] != nil)
    }

    @Test func aFarDateAndChromiumsCapAreOneCookie() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var far = cookie("a", domain: "switch.test"), capped = far
        far.expires = now.timeIntervalSince1970 + 800 * 86_400
        capped.expires = now.timeIntervalSince1970 + 400 * 86_400
        #expect(ChromiumDRMCookie.same(far, capped, now: now))
        var soon = capped
        soon.expires = now.timeIntervalSince1970 + 86_400
        #expect(!ChromiumDRMCookie.same(far, soon, now: now))
    }

    @Test func anImportRowMarksRefusedAndSessionCookies() {
        let session = cookie("sid", domain: "switch.test", session: true), lasting = cookie("keep", domain: "switch.test"), refused = cookie("big", domain: "switch.test")
        var book = ChromiumCookieBook()
        for (made, accepted) in [(session, true), (lasting, true), (refused, false)] {
            book.note(ChromiumCookieImportRow(cookie: made, fingerprint: "h", payload: .null), accepted: accepted)
        }
        book.finishImport()
        #expect(book.ledger.imported == true && book.ledger.session == [session.key])
        #expect(book.ledger.webKit[refused.key] != nil && book.ledger.chromium[refused.key] == nil)
    }

    @Test func aLedgerFromBeforeTheImportStillReads() throws {
        let old = try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: Data(#"{"webKit":{"a":"b"},"chromium":{}}"#.utf8))
        #expect(old.imported == nil && old.webKit == ["a": "b"])
    }

    @Test func savedLedgerContainsNoCookieValuesAndIsPrivate() throws {
        let saved = cookie("synthetic-secret-not-for-ledger")
        let hashes = ChromiumSwitchCookieLedger.fingerprint([saved.key: saved])
        let ledger = ChromiumSwitchCookieLedger(webKit: hashes, chromium: hashes)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = folder.appendingPathComponent("cookie-ledger.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ledger.save(to: file)
        let bytes = try Data(contentsOf: file)
        #expect(!String(decoding: bytes, as: UTF8.self).contains(saved.value))
        #expect(try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: bytes) == ledger)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func aValueChangedOnBothSidesFollowsTheEngineThatUsedTheHostLast() {
        func cookie(_ value: String) -> ChromiumDRMCookie {
            ChromiumDRMCookie(HTTPCookie(properties: [.name: "token", .value: value, .domain: "a.test", .path: "/"])!)
        }
        let old = cookie("1"), seen = ChromiumSwitchCookieLedger.fingerprint(["k": old])
        let ledger = ChromiumSwitchCookieLedger(webKit: seen, chromium: seen)
        let both = (webKit: ["k": cookie("2")], chromium: ["k": cookie("3")])
        let chromiumLast = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium, previous: ledger, usedLast: .chromium)
        #expect(chromiumLast.toWebKit.first?.cookie?.value == "3" && chromiumLast.toChromium.isEmpty)
        let webKitLast = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium, previous: ledger, usedLast: .webKit)
        #expect(webKitLast.toChromium.first?.cookie?.value == "2" && webKitLast.toWebKit.isEmpty)
        // One side changed: it goes across whoever was last.
        let one = ChromiumDRMCookieMerge.plan(webKit: ["k": old], chromium: ["k": cookie("3")], previous: ledger, usedLast: .webKit)
        #expect(one.toWebKit.first?.cookie?.value == "3" && one.toChromium.isEmpty)
        // Nothing known yet: the WebKit sign-in, as ever.
        let first = ChromiumDRMCookieMerge.plan(webKit: both.webKit, chromium: both.chromium,
                                                previous: ChromiumSwitchCookieLedger(webKit: [:], chromium: [:]), usedLast: .chromium)
        #expect(first.toChromium.first?.cookie?.value == "2" && first.toWebKit.isEmpty)
    }

    // A session the site renews on every check (next-auth does): same value, new expiry.
    private func token(_ value: String, renewed: Double = 0) -> ChromiumDRMCookie {
        ChromiumDRMCookie(HTTPCookie(properties: [.name: "session-token", .value: value, .domain: "chat.test", .path: "/",
            .expires: Date(timeIntervalSince1970: 2_000_000_000 + renewed)])!)
    }

    private func agreed(_ cookie: ChromiumDRMCookie) -> ChromiumSwitchCookieLedger {
        let seen = ChromiumSwitchCookieLedger.fingerprint([cookie.key: cookie])
        return ChromiumSwitchCookieLedger(webKit: seen, chromium: seen)
    }

    @Test func aSignOutBeatsTheOtherEnginesRenewalOfThatSession() {
        let old = token("account-a"), renewed = token("account-a", renewed: 60)
        for usedLast in [PageEngineKind.webKit, .chromium, nil] {
            // Chromium signed out while the site, open in WebKit too, renewed it there.
            let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: renewed], chromium: [:], previous: agreed(old), usedLast: usedLast)
            #expect(plan.toChromium.isEmpty)
            #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == nil)
            // And the other way round.
            let other = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [old.key: renewed], previous: agreed(old), usedLast: usedLast)
            #expect(other.toWebKit.isEmpty)
            #expect(other.toChromium.count == 1 && other.toChromium[0].cookie == nil)
        }
    }

    @Test func anotherAccountBeatsARenewalOfTheEndedOne() {
        let old = token("account-a"), renewed = token("account-a", renewed: 60), next = token("account-b")
        for usedLast in [PageEngineKind.webKit, .chromium, nil] {
            let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: renewed], chromium: [old.key: next], previous: agreed(old), usedLast: usedLast)
            #expect(plan.toChromium.isEmpty)
            #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == next)
        }
    }

    @Test func aSignOutOfTheOldAccountLeavesANewSignInAlone() {
        let old = token("account-a"), next = token("account-b")
        // Signed out of A in Chromium while WebKit signed in to B.
        let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: next], chromium: [:], previous: agreed(old), usedLast: .chromium)
        #expect(plan.toWebKit.isEmpty)
        #expect(plan.toChromium.count == 1 && plan.toChromium[0].cookie == next)
    }

    @Test func aDeletionTheBridgeNeverSawIsStillADeletionAfterARelaunch() throws {
        // The last run ended with both jars signed in to A; Chromium signed out on
        // a hop the bridge hadn't read yet. The ledger is read back as written.
        let old = token("account-a")
        var book = ChromiumCookieBook()
        let scope = book.scope(host: "chat.test", seen: [])
        book.record(scope, webKit: [old.key: old], chromium: [old.key: old])
        let relaunched = ChromiumCookieBook(ledger: try JSONDecoder().decode(ChromiumSwitchCookieLedger.self, from: JSONEncoder().encode(book.ledger)))
        let plan = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [:], previous: relaunched.slice(scope))
        #expect(plan.toChromium.isEmpty)
        #expect(plan.toWebKit.count == 1 && plan.toWebKit[0].cookie == nil)
    }

    @Test func aLedgerOfWholePrintsReadsAsBefore() {
        // Before November 2026 a print was the whole cookie's hash alone.
        let old = token("account-a")
        let whole = ChromiumSwitchCookieLedger.whole(ChromiumSwitchCookieLedger.fingerprint(old))!
        #expect(!whole.contains(":") && whole.count == 64)
        #expect(ChromiumSwitchCookieLedger.value(whole) == nil)
        let ledger = ChromiumSwitchCookieLedger(webKit: [old.key: whole], chromium: [old.key: whole])
        // Unchanged on both sides is no change; one side's edit goes over.
        #expect(ChromiumDRMCookieMerge.plan(webKit: [old.key: token("account-b")], chromium: [old.key: old], previous: ledger).toChromium.count == 1)
        let other = ChromiumDRMCookieMerge.plan(webKit: [old.key: old], chromium: [old.key: token("account-c")], previous: ledger)
        #expect(other.toChromium.isEmpty && other.toWebKit.count == 1)
    }

    @Test func aPrintHoldsNoValue() {
        let secret = token("synthetic-secret-not-for-ledger")
        let print = ChromiumSwitchCookieLedger.fingerprint(secret)
        #expect(!print.contains(secret.value))
        #expect(ChromiumSwitchCookieLedger.value(print)?.count == 16)
        #expect(ChromiumSwitchCookieLedger.value(print) == ChromiumSwitchCookieLedger.value(ChromiumSwitchCookieLedger.fingerprint(token("synthetic-secret-not-for-ledger", renewed: 5))))
    }

    @Test func aHostChromiumStillOwesClearingTakesNothingFromIt() {
        // Clear Data emptied WebKit; Chromium's clear failed and is owed. Its
        // script cookie must not come back, though nothing knew of it yet.
        let account = cookie("account", "old", domain: "switch.test", session: true), gone = token("account-a")
        let plan = ChromiumDRMCookieMerge.plan(webKit: [:], chromium: [account.key: account, gone.key: gone],
                                               previous: ChromiumSwitchCookieLedger(webKit: [:], chromium: [:])).owingClearing()
        #expect(plan.toWebKit.isEmpty)
        // A deletion still goes: what Chromium dropped, WebKit drops.
        let deletion = ChromiumDRMCookieMerge.plan(webKit: [gone.key: gone], chromium: [:], previous: agreed(gone)).owingClearing()
        #expect(deletion.toWebKit.count == 1 && deletion.toWebKit[0].cookie == nil)
    }
}
