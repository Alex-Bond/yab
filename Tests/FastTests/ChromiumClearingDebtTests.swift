import Foundation
import Testing
@testable import Fast

struct ChromiumClearingDebtTests {
    /// Clear Data that reached WebKit but not Chromium is owed for the site
    /// and its subdomains, in that profile only, until it is paid.
    @Test func aSiteIsOwedUntilPaid() {
        var owed = ChromiumClearingDebt.adding("example.test", profile: "A", to: [:])
        owed = ChromiumClearingDebt.adding("example.test", profile: "A", to: owed)
        #expect(owed == ["A": ["example.test"]])
        #expect(ChromiumClearingDebt.owes(host: "example.test", profile: "A", in: owed))
        #expect(ChromiumClearingDebt.owes(host: "Mail.Example.test", profile: "A", in: owed))
        #expect(!ChromiumClearingDebt.owes(host: "notexample.test", profile: "A", in: owed))
        #expect(!ChromiumClearingDebt.owes(host: "example.test", profile: "B", in: owed))
        owed = ChromiumClearingDebt.paying("example.test", profile: "A", in: owed)
        #expect(owed.isEmpty)
        #expect(!ChromiumClearingDebt.owes(host: "example.test", profile: "A", in: owed))
    }

    /// Sign Out everywhere that Chromium didn't finish owes every site there.
    @Test func signingOutEverywhereOwesEverySite() {
        let owed = ChromiumClearingDebt.adding(ChromiumClearingDebt.everything, profile: "A", to: [:])
        #expect(ChromiumClearingDebt.owes(host: "chatgpt.com", profile: "A", in: owed))
        #expect(!ChromiumClearingDebt.owes(host: "chatgpt.com", profile: "B", in: owed))
    }
}
