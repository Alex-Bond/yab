import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct FirstEditionTests {
    let token = String(repeating: "a", count: 64)

    @Test func onlyMatchingGiftPageCanClaim() {
        #expect(FirstEdition.allows(token: token, page: URL(string: "https://yetanotherbrowser.com/gift/\(token)"), clicked: true))
        #expect(!FirstEdition.allows(token: token, page: URL(string: "https://evil.example/gift/\(token)"), clicked: true))
        #expect(!FirstEdition.allows(token: token, page: URL(string: "https://yetanotherbrowser.com/gift/\(token)"), clicked: false))
        #expect(!FirstEdition.allows(token: token, page: URL(string: "https://yetanotherbrowser.com/gift/other"), clicked: true))
        #expect(!FirstEdition.allows(token: token, page: URL(string: "http://yetanotherbrowser.com/gift/\(token)"), clicked: true))
        #expect(Dress.read(URL(string: "yab-dress:gift/\(token)")!) == .gift(token))
        #expect(Dress.read(URL(string: "yab-dress:gift/short")!) == nil)
    }

    @Test func onlyCompleteReceiptUnlocksIcon() {
        let before = Store.settings.object(forKey: FirstEdition.key)
        let selection = Store.settings.object(forKey: AppIconStyle.key)
        defer {
            if let before { Store.settings.set(before, forKey: FirstEdition.key) } else { Store.settings.removeObject(forKey: FirstEdition.key) }
            if let selection { Store.settings.set(selection, forKey: AppIconStyle.key) } else { Store.settings.removeObject(forKey: AppIconStyle.key) }
        }
        Store.settings.removeObject(forKey: FirstEdition.key)
        #expect(!AppIconStyle.firstEdition.unlocked)
        #expect(!AppIconStyle.choices.contains(.firstEdition))
        let saved = AppIconStyle.saved
        AppIconStyle.firstEdition.choose()
        #expect(AppIconStyle.saved == saved)
        #expect(FirstEdition.receipt(in: ["icon": "20-first-edition", "receipt": "short"]) == nil)
        #expect(FirstEdition.receipt(in: ["icon": "unknown", "receipt": token]) == nil)
        #expect(FirstEdition.receipt(in: ["icon": "20-first-edition", "receipt": token]) == token)
        Store.settings.set(token, forKey: FirstEdition.key)
        #expect(AppIconStyle.firstEdition.unlocked)
        #expect(AppIconStyle.choices.contains(.firstEdition))
        #expect(SyncShapes.syncs(FirstEdition.key))
        #expect(!SyncShapes.syncs("gift.firstEdition.delivery"))
    }
}
