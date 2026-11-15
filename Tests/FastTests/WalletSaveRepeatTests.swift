import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct WalletSaveRepeatTests {
    private func address(_ street: String) -> StreetAddress {
        var address = StreetAddress(id: UUID().uuidString)
        address.name = "Client " + UUID().uuidString
        address.street = street
        address.city = "Paris"
        address.postal = "75001"
        return address
    }

    @Test(arguments: [false, true])
    func repeatedSubmissionKeepsTheExistingQuestion(parked: Bool) async throws {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let prefs = browser.prefs
        let old = prefs.savesCards
        prefs.savesCards = true
        let tab = Tab()
        tab.restore(url: URL(string: "https://accounting.example/client")!, title: "Accounting")
        browser.prepare(tab)
        browser.lay([tab]); browser.activeID = tab.id
        defer {
            tab.payOffer = nil
            tab.close()
            browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
            prefs.savesCards = old
            if let id = browser.windowID {
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
        }
        let original = address("17 Fixture Street")
        var offer = PayOffer(address: original, sites: ["accounting.example"])
        offer.parked = parked
        tab.payOffer = offer
        var again = original
        again.id = UUID().uuidString
        browser.paid(tab, card: nil, address: again, host: "accounting.example")
        // The real background Wallet lookup returns on the main queue.
        try await Task.sleep(for: .seconds(1))
        #expect(tab.payOffer?.id == offer.id)
        #expect(tab.payOffer?.parked == parked)

        // Positive control: a different client must still get a new offer.
        // Nothing is written to the test world's keychain.
        let different = address("29 Fixture Street")
        browser.paid(tab, card: nil, address: different, host: "accounting.example")
        for _ in 0..<100 where tab.payOffer?.address?.street != different.street {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(tab.payOffer?.id != offer.id)
        #expect(tab.payOffer?.address?.street == different.street)
        #expect(tab.payOffer?.parked == false)
    }
}
