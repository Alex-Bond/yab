import Foundation
import Security
import Testing
@testable import Fast
@testable import YabStore

struct SavedKeychainTests {
    private func query(_ service: String = "test service", _ account: String = "key", protected: Bool = false) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: protected]
    }

    private final class StandIn {
        var items: [String: Data] = [:]
        var denied: Set<String> = []
        var routes: [String: String] = [:]
        var reads: [[String: Any]] = []
        var adds: [[String: Any]] = []
        var updates: [[String: Any]] = []
        var removals = 0
        var addFailure: OSStatus?
        var freshAddFailure: OSStatus?
        var updateFailure: OSStatus?
        var updateDenial = errSecInteractionNotAllowed
        var hideOnFirstUpdate = false
        var allowUpdateAfterDuplicate = false
        var updateWithoutReadAccess = false
        var attributesRemainAccessible = false

        func identity(_ query: [String: Any]) -> String {
            [query[kSecAttrService as String] as? String ?? "",
             query[kSecAttrAccount as String] as? String ?? "",
             query[kSecUseDataProtectionKeychain as String] as? Bool == true ? "protected" : "login"]
                .joined(separator: "|")
        }

        func put(_ query: [String: Any], _ value: String, inaccessible: Bool = false) {
            let id = identity(query)
            items[id] = Data(value.utf8)
            if inaccessible { denied.insert(id) }
        }

        func storage() -> Keychain.SavedItems {
            Keychain.SavedItems(copy: { query, result in
                self.reads.append(query)
                let id = self.identity(query)
                let metadataOnly = query[kSecReturnData as String] as? Bool != true
                guard !self.denied.contains(id) || (self.attributesRemainAccessible && metadataOnly)
                else { return errSecInteractionNotAllowed }
                guard let data = self.items[id] else { return errSecItemNotFound }
                if query[kSecReturnData as String] as? Bool == true { result?.pointee = data as CFData }
                else { result?.pointee = [kSecAttrAccount as String: query[kSecAttrAccount as String]!] as CFDictionary }
                return errSecSuccess
            }, update: { query, fields in
                self.updates.append(query)
                if let status = self.updateFailure { return status }
                if self.hideOnFirstUpdate {
                    self.hideOnFirstUpdate = false
                    return errSecItemNotFound
                }
                let id = self.identity(query)
                guard !self.denied.contains(id) || self.updateWithoutReadAccess else { return self.updateDenial }
                guard self.items[id] != nil else { return errSecItemNotFound }
                self.items[id] = fields[kSecValueData as String] as? Data
                return errSecSuccess
            }, add: { item in
                self.adds.append(item)
                if let status = self.addFailure { return status }
                let id = self.identity(item)
                if self.items[id] != nil {
                    if self.allowUpdateAfterDuplicate { self.denied.remove(id) }
                    return errSecDuplicateItem
                }
                if let status = self.freshAddFailure { return status }
                self.items[id] = item[kSecValueData as String] as? Data
                return errSecSuccess
            }, remove: { query in
                self.removals += 1
                let id = self.identity(query)
                guard !self.denied.contains(id) else { return errSecInteractionNotAllowed }
                return self.items.removeValue(forKey: id) == nil ? errSecItemNotFound : errSecSuccess
            }, route: { self.routes[$0] }, keepRoute: { self.routes[$0] = $1 })
        }

        func read(_ query: [String: Any], using storage: Keychain.SavedItems) -> (OSStatus, Data?) {
            var query = query
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = storage.copyMatching(query, &result)
            return (status, result as? Data)
        }
    }

    @Test func reenteredValuesSurviveAReopenForEveryLocalItem() {
        let identities = [
            ("dev.serafim.fast.agent-key", "claude"),
            ("dev.serafim.fast.agent-key", "account-id"),
            ("dev.serafim.fast.openrouter", "field-requests"),
            ("dev.serafim.fast.openrouter", "key.second"),
            ("Yab · assistants", "secret"), ("Yab · assistants", "token"),
            ("Yab · sync", "key"), ("Yab · sync", "token"),
            ("Yab Invites", "installation"), ("Yab · web push", "state"),
            ("Yab · context provenance · test", "journal-v1"),
        ]
        for (service, account) in identities {
            let query = query(service, account)
            let stand = StandIn()
            stand.put(query, "old", inaccessible: true)
            #expect(stand.read(query, using: stand.storage()).0 == errSecInteractionNotAllowed)
            #expect(stand.storage().save(query, data: Data("reentered".utf8)) == errSecSuccess)
            #expect(stand.adds.count == 2)
            #expect(stand.removals == 0)
            #expect(stand.items[stand.identity(query)] == Data("old".utf8))
            #expect(stand.routes.count == 1)
            #expect(stand.routes.values.first?.hasPrefix(account + ".yab.") == true)
            for key in stand.routes.keys { #expect(!SyncShapes.syncs(key)) }
            let (status, data) = stand.read(query, using: stand.storage())
            #expect(status == errSecSuccess)
            #expect(data == Data("reentered".utf8))
            #expect(stand.reads.last?[kSecAttrAccount as String] as? String != account)
        }
    }

    @Test func writableOldItemsAreUpdatedWithoutDeletionOrRotation() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old")
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.read(query, using: stand.storage()).1 == Data("new".utf8))
        #expect(stand.adds.isEmpty)
        #expect(stand.routes.isEmpty)
        #expect(stand.removals == 0)
    }

    @Test func aSuccessfulUpdateMustLeaveTheSecretReadable() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        stand.updateWithoutReadAccess = true
        stand.attributesRemainAccessible = true
        var metadata = query
        metadata[kSecReturnAttributes as String] = true
        #expect(stand.storage().copyMatching(metadata, nil) == errSecSuccess)
        #expect(stand.read(query, using: stand.storage()).0 == errSecInteractionNotAllowed)
        #expect(stand.storage().save(query, data: Data("reentered".utf8)) == errSecSuccess)
        #expect(stand.routes.count == 1)
        #expect(stand.routes.values.first?.hasPrefix("key.yab.") == true)
        #expect(stand.read(query, using: stand.storage()).1 == Data("reentered".utf8))
        #expect(stand.storage().delete(query) == errSecSuccess)
        stand.denied.removeAll()
        #expect(stand.read(query, using: stand.storage()).0 == errSecItemNotFound)
    }

    @Test func anUpdatedReplacementCanStillNeedAnotherSigningRotation() throws {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().save(query, data: Data("first".utf8)) == errSecSuccess)
        let first = try #require(stand.adds.last)
        let previous = stand.routes
        stand.denied.insert(stand.identity(first))
        stand.updateWithoutReadAccess = true
        #expect(stand.storage().save(query, data: Data("second".utf8)) == errSecSuccess)
        #expect(stand.routes != previous)
        #expect(stand.read(query, using: stand.storage()).1 == Data("second".utf8))
    }

    @Test func aDuplicateAfterNotFoundRetriesTheUpdate() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old")
        stand.hideOnFirstUpdate = true
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.updates.count == 2)
        #expect(stand.adds.count == 1)
        #expect(stand.routes.isEmpty)
        #expect(stand.read(query, using: stand.storage()).1 == Data("new".utf8))
    }

    @Test func aDuplicateThatStillDeniesTheUpdateUsesAFreshAccount() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        stand.hideOnFirstUpdate = true
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.routes.count == 1)
        #expect(stand.read(query, using: stand.storage()).1 == Data("new".utf8))
    }

    @Test func aDuplicateCanBecomeWritableWithoutRotation() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        stand.allowUpdateAfterDuplicate = true
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.routes.isEmpty)
        #expect(stand.read(query, using: stand.storage()).1 == Data("new".utf8))
    }

    @Test func anotherSigningChangeCanRotateTheSelectedAccountAgain() throws {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().save(query, data: Data("first".utf8)) == errSecSuccess)
        let first = try #require(stand.adds.last)
        stand.denied.insert(stand.identity(first))
        #expect(stand.storage().save(query, data: Data("second".utf8)) == errSecSuccess)
        #expect(stand.read(query, using: stand.storage()).1 == Data("second".utf8))
        #expect(stand.adds.last?[kSecAttrAccount as String] as? String != first[kSecAttrAccount as String] as? String)
    }

    @Test func missingOrDeniedReplacementsNeverUncoverTheOldValue() throws {
        for missing in [false, true] {
            let stand = StandIn()
            let query = query()
            stand.put(query, "old", inaccessible: true)
            #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
            let selected = try #require(stand.adds.last)
            stand.denied.removeAll()
            if missing { stand.items[stand.identity(selected)] = nil }
            else { stand.denied.insert(stand.identity(selected)) }
            let (status, data) = stand.read(query, using: stand.storage())
            #expect(status == (missing ? errSecItemNotFound : errSecInteractionNotAllowed))
            #expect(data == nil)
            #expect(stand.reads.count == 1)
            #expect(stand.reads.last?[kSecAttrAccount as String] as? String == selected[kSecAttrAccount as String] as? String)
        }
    }

    @Test func removalPersistsEvenWhenTheOldItemCannotBeDeleted() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().delete(query) == errSecInteractionNotAllowed)
        stand.denied.removeAll()
        #expect(stand.read(query, using: stand.storage()).0 == errSecItemNotFound)
        #expect(stand.reads.isEmpty)
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.read(query, using: stand.storage()).1 == Data("new".utf8))
        #expect(stand.items[stand.identity(query)] == Data("old".utf8))
    }

    @Test func removingAReplacementNeverUncoversTheOldItem() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        #expect(stand.storage().delete(query) == errSecSuccess)
        stand.denied.removeAll()
        #expect(stand.read(query, using: stand.storage()).0 == errSecItemNotFound)
        #expect(stand.reads.isEmpty)
    }

    @Test func aFailedFreshWriteDoesNotPublishARoute() {
        for denial in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem] {
            let stand = StandIn()
            let query = query()
            stand.put(query, "old", inaccessible: true)
            stand.updateDenial = denial
            stand.freshAddFailure = errSecNotAvailable
            #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecNotAvailable)
            #expect(stand.adds.count == 2)
            #expect(stand.routes.isEmpty)
            #expect(stand.items.count == 1)
        }
    }

    @Test func aFailedRotationKeepsThePreviouslySelectedAccount() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().save(query, data: Data("first".utf8)) == errSecSuccess)
        let routes = stand.routes
        stand.denied.formUnion(stand.items.keys)
        stand.freshAddFailure = errSecNotAvailable
        #expect(stand.storage().save(query, data: Data("second".utf8)) == errSecNotAvailable)
        #expect(stand.routes == routes)
        stand.denied.removeAll()
        #expect(stand.read(query, using: stand.storage()).1 == Data("first".utf8))
    }

    @Test func unavailableOrUnentitledKeychainsDoNotRotate() {
        for failure in [errSecNotAvailable, errSecMissingEntitlement] {
            let stand = StandIn()
            stand.updateFailure = failure
            #expect(stand.storage().save(query(), data: Data("new".utf8)) == failure)
            #expect(stand.adds.isEmpty)
            #expect(stand.routes.isEmpty)
        }
        let stand = StandIn()
        stand.addFailure = errSecNotAvailable
        #expect(stand.storage().save(query(), data: Data("new".utf8)) == errSecNotAvailable)
        #expect(stand.adds.count == 1)
        #expect(stand.routes.isEmpty)
    }

    @Test func freshItemsKeepTheirProtectionAndLabels() {
        let stand = StandIn()
        let query = query(protected: true)
        stand.put(query, "old", inaccessible: true)
        let attributes: [String: Any] = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecAttrLabel as String: "Test label"]
        #expect(stand.storage().save(query, data: Data("new".utf8), attributes: attributes) == errSecSuccess)
        #expect(stand.adds.last?[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(stand.adds.last?[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(stand.adds.last?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(stand.adds.last?[kSecAttrLabel as String] as? String == "Test label")
    }

    @Test func routesAreScopedToTheirServiceAccountAndKeychain() {
        let stand = StandIn()
        let queries = [query("one", "key"), query("two", "key"), query("one", "token"), query("one", "key", protected: true)]
        for (index, query) in queries.enumerated() {
            stand.put(query, "old", inaccessible: true)
            #expect(stand.storage().save(query, data: Data("new-\(index)".utf8)) == errSecSuccess)
        }
        #expect(stand.routes.count == queries.count)
        for (index, query) in queries.enumerated() {
            #expect(stand.read(query, using: stand.storage()).1 == Data("new-\(index)".utf8))
        }
    }

    @Test func presenceUsesTheReplacementWithoutRequestingTheSecret() {
        let stand = StandIn()
        var query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecSuccess)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        #expect(stand.storage().copyMatching(query, &result) == errSecSuccess)
        #expect(result as? Data == nil)
        #expect(stand.reads.last?[kSecReturnData as String] == nil)
        #expect(stand.reads.last?[kSecReturnAttributes as String] as? Bool == true)
    }

    @Test func aPassiveReadNeverCreatesOrRotatesAnItem() {
        let stand = StandIn()
        let query = query()
        stand.put(query, "old", inaccessible: true)
        #expect(stand.read(query, using: stand.storage()).0 == errSecInteractionNotAllowed)
        #expect(stand.routes.isEmpty)
        #expect(stand.adds.isEmpty)
        #expect(stand.updates.isEmpty)
    }

    @Test func cloudItemsCannotUseDeviceLocalRoutes() {
        let stand = StandIn()
        var query = query(protected: true)
        query[kSecAttrSynchronizable as String] = true
        #expect(stand.storage().save(query, data: Data("new".utf8)) == errSecParam)
        #expect(stand.read(query, using: stand.storage()).0 == errSecParam)
        #expect(stand.storage().delete(query) == errSecParam)
        #expect(stand.adds.isEmpty)
        #expect(stand.routes.isEmpty)
    }
}
