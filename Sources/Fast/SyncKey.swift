import YabStore
import Foundation
import Security
import SyncKit

// Where the sync key lives on this Mac (docs/sync.md, "The key and the
// account"). Two copies: one that says this Mac is in sync, kept on this Mac
// alone, and one in iCloud Keychain that a new Mac on the same Apple ID
// finds by itself. Turning sync off here forgets the first; the second stays
// for the other devices. Builds not signed to use iCloud Keychain simply
// have no second copy: the code or the Recovery Key does instead.

enum SyncKey {
    private static var service: String { "\(Store.name) · sync" }
    private static let account = "key"
    private static let tokenAccount = "token"

    /// This Mac's copy: the key sync runs with.
    static var local: Seal? {
        read(account, synced: false).flatMap(Seal.init(raw:))
    }

    /// The copy iCloud Keychain brought, if any: offered when this Mac
    /// turns sync on, so it joins the account instead of making another.
    static var shared: Seal? {
        read(account, synced: true).flatMap(Seal.init(raw:))
    }

    static func keep(_ seal: Seal) {
        write(seal.raw, account, synced: false)
        write(seal.raw, account, synced: true)
    }

    /// Off on this Mac; the iCloud copy stays for the others, unless
    /// `everywhere`, when the account itself is gone.
    static func forget(everywhere: Bool = false) {
        delete(account, synced: false)
        delete(tokenAccount, synced: false)
        if everywhere { delete(account, synced: true) }
    }

    static var token: String? {
        get { read(tokenAccount, synced: false).flatMap { String(data: $0, encoding: .utf8) } }
        set {
            if let newValue { write(Data(newValue.utf8), tokenAccount, synced: false) } else { delete(tokenAccount, synced: false) }
        }
    }

    // MARK: Keychain

    static func query(_ name: String, synced: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        if synced {
            // iCloud Keychain lives in the data protection keychain only.
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            query[kSecUseDataProtectionKeychain as String] = true
        } else {
            query[kSecUseDataProtectionKeychain as String] = false
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        }
        return query
    }

    /// What iCloud Keychain brings a test world (evals/sync): nothing writes
    /// this copy but the eval that stands in for iCloud.
    static func testShared(_ seal: Seal?) {
        guard Store.testing else { return }
        if let seal { try? seal.raw.write(to: testFile(account, synced: true), options: .atomic) }
        else { try? FileManager.default.removeItem(at: testFile(account, synced: true)) }
    }

    /// A test world keeps its key in a file of its own: no keychain item
    /// is left behind by a run, and no other world's is found.
    private static func testFile(_ name: String, synced: Bool) -> URL {
        Store.file("sync-\(name)\(synced ? "-shared" : "").test")
    }

    private static func read(_ name: String, synced: Bool) -> Data? {
        if Store.testing { return try? Data(contentsOf: testFile(name, synced: synced)) }
        var query = query(name, synced: synced)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = synced ? Keychain.copyMatching(query as CFDictionary, &out) : Keychain.copySaved(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    private static func write(_ data: Data, _ name: String, synced: Bool) -> Bool {
        if Store.testing {
            guard !synced else { return false }
            return (try? data.write(to: testFile(name, synced: false), options: .atomic)) != nil
        }
        let base = query(name, synced: synced)
        if !synced {
            return Keychain.save(base as CFDictionary, data: data, attributes: [
                kSecAttrLabel as String: "\(Store.name) Sync",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]) == errSecSuccess
        }
        let update: [String: Any] = [kSecValueData as String: data]
        var status = Keychain.update(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(Store.name) Sync"
            add[kSecAttrAccessible as String] = synced ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = Keychain.add(add as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    private static func delete(_ name: String, synced: Bool) {
        if Store.testing { try? FileManager.default.removeItem(at: testFile(name, synced: synced)); return }
        if synced { Keychain.delete(query(name, synced: true) as CFDictionary) }
        else { Keychain.removeSaved(query(name, synced: false) as CFDictionary) }
    }
}
