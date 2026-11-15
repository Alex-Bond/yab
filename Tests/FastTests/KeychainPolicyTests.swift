import Foundation
import Security
import LocalAuthentication
import Testing
@testable import Fast
@testable import MailCore
@testable import YabStore

struct KeychainPolicyTests {
    private func prepared(_ query: [String: Any]) -> [String: Any] {
        Keychain.noninteractive(query as CFDictionary) as! [String: Any]
    }

    private func expectNoInteraction(_ query: [String: Any]) {
        let attributes = prepared(query)
        #expect((attributes[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(attributes[kSecUseAuthenticationUI as String] == nil)
    }

    @Test func cookieAddsAndUpdatesCannotAskForAKeychain() {
        let query = KeptCookies.query
        expectNoInteraction(query)
        var add = query
        add[kSecValueData as String] = Data("test cookies".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let attributes = prepared(add)
        expectNoInteraction(add)
        #expect(attributes[kSecValueData as String] as? Data == Data("test cookies".utf8))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String)
        #expect(attributes[kSecAttrAccount as String] as? String == query[kSecAttrAccount as String] as? String)
    }

    @Test func syncQueriesKeepTheLocalAndCloudCopiesSeparate() {
        for synced in [false, true] {
            let query = SyncKey.query("key", synced: synced)
            let attributes = prepared(query)
            expectNoInteraction(query)
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == synced)
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool == synced)
        }
    }

    @Test func deviceAndLoginFallbackQueriesStayInTheirOwnKeychains() {
        for protected in [false, true] {
            let query = ManagerUnlock.query("test-manager", protected: protected)
            let attributes = prepared(query)
            expectNoInteraction(query)
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == protected)
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        }
        for place in [MailKeychain.Place.login, .thisDevice] {
            let query = MailKeychain.identity("test@example.com", in: place, service: "test service")
            let attributes = prepared(query)
            expectNoInteraction(query)
            #expect(attributes[kSecUseDataProtectionKeychain as String] as? Bool == (place == .thisDevice))
            #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
        }
    }

    @Test func aCallerCannotAllowAuthenticationUI() {
        let context = LAContext()
        context.interactionNotAllowed = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: "test domain",
            kSecValuePersistentRef as String: Data([1, 2, 3]),
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIAllow,
        ]
        let attributes = prepared(query)
        expectNoInteraction(query)
        #expect(attributes[kSecAttrSecurityDomain as String] as? String == "test domain")
        #expect(attributes[kSecValuePersistentRef as String] as? Data == Data([1, 2, 3]))
        #expect(attributes[kSecUseDataProtectionKeychain as String] == nil)
        #expect(!context.interactionNotAllowed)
    }

    @Test func nestedCallsRestoreInteractionOnlyAfterTheOutermostCall() {
        var allowed = true
        var changes: [Bool] = []
        let interaction = Keychain.Interaction(read: { (errSecSuccess, allowed) }, set: {
            changes.append($0)
            allowed = $0
            return errSecSuccess
        })
        let result = interaction.withoutUI { disabled in
            #expect(disabled)
            #expect(!allowed)
            var nestedAllowed: Bool?
            let status = interaction.perform {
                nestedAllowed = allowed
                return errSecSuccess
            }
            #expect(status == errSecSuccess)
            #expect(nestedAllowed == false)
            #expect(!allowed)
            #expect(changes == [false])
            return 42
        }
        #expect(result == 42)
        #expect(allowed)
        #expect(changes == [false, true])
    }

    @Test func interactionAlreadyDisabledStaysDisabled() {
        var allowed = false
        let interaction = Keychain.Interaction(read: { (errSecSuccess, allowed) }, set: {
            allowed = $0
            return errSecSuccess
        })
        #expect(interaction.perform { errSecSuccess } == errSecSuccess)
        #expect(!allowed)
    }

    @Test func failureToReadOrDisableInteractionNeverCallsSecurity() {
        for readFails in [false, true] {
            var calls = 0
            var changes = 0
            let interaction = Keychain.Interaction(read: {
                (readFails ? errSecNotAvailable : errSecSuccess, true)
            }, set: { _ in changes += 1; return errSecNotAvailable })
            #expect(interaction.perform { calls += 1; return errSecSuccess } == errSecInteractionNotAllowed)
            #expect(calls == 0)
            #expect(changes == (readFails ? 0 : 1))
        }
    }

    @Test func unavailableAndLockedKeychainsReturnTheirStatus() {
        let interaction = Keychain.Interaction(read: { (errSecSuccess, true) }, set: { _ in errSecSuccess })
        for status in [errSecNoSuchKeychain, errSecNotAvailable, errSecInteractionNotAllowed, errSecAuthFailed, errSecMissingEntitlement] {
            #expect(interaction.perform { status } == status)
        }
    }

    @Test func anAskedReadWaitsForAQuietCallToPutTheSwitchBack() {
        var allowed = true
        let interaction = Keychain.Interaction(read: { (errSecSuccess, allowed) }, set: {
            allowed = $0
            return errSecSuccess
        })
        var seen: Bool?
        let status = interaction.asking { () -> OSStatus in
            seen = allowed
            return errSecSuccess
        }
        #expect(status == errSecSuccess)
        #expect(seen == true)
        #expect(allowed)
    }
}
