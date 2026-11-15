import Foundation
import Security

extension Keychain {
    /// Local items can outlive the signature that wrote them. Only the account
    /// route goes in settings; the value always stays in the same keychain.
    final class SavedItems {
        private let lock = NSRecursiveLock()
        private let copy: ([String: Any], UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
        private let update: ([String: Any], [String: Any]) -> OSStatus
        private let add: ([String: Any]) -> OSStatus
        private let remove: ([String: Any]) -> OSStatus
        private let route: (String) -> String?
        private let keepRoute: (String, String) -> Void

        init(copy: @escaping ([String: Any], UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = {
            Keychain.copyMatching($0 as CFDictionary, $1)
        }, update: @escaping ([String: Any], [String: Any]) -> OSStatus = {
            Keychain.update($0 as CFDictionary, $1 as CFDictionary)
        }, add: @escaping ([String: Any]) -> OSStatus = {
            Keychain.add($0 as CFDictionary, nil)
        }, remove: @escaping ([String: Any]) -> OSStatus = {
            Keychain.delete($0 as CFDictionary)
        }, route: @escaping (String) -> String? = {
            Store.settings.string(forKey: $0)
        }, keepRoute: @escaping (String, String) -> Void = {
            Store.settings.set($1, forKey: $0)
        }) {
            self.copy = copy
            self.update = update
            self.add = add
            self.remove = remove
            self.route = route
            self.keepRoute = keepRoute
        }

        func copyMatching(_ query: [String: Any], _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            result?.pointee = nil
            guard let key = routeKey(query) else { return errSecParam }
            var query = query
            if let account = route(key) {
                guard !account.isEmpty else { return errSecItemNotFound }
                query[kSecAttrAccount as String] = account
            }
            // A selected account is authoritative, even if it is now missing
            // or inaccessible. Never fall back to a superseded secret.
            return copy(query, result)
        }

        func save(_ query: [String: Any], data: Data, attributes: [String: Any] = [:]) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            guard let key = routeKey(query), let original = query[kSecAttrAccount as String] as? String else { return errSecParam }
            var target = query
            let account = route(key)
            if let account {
                target[kSecAttrAccount as String] = account.isEmpty ? fresh(original) : account
            }
            var status = replace(target, data: data)
            if status != errSecSuccess {
                guard status == errSecItemNotFound || denied(status) else { return status }
                status = insert(target, data: data, attributes: attributes)
                if status == errSecDuplicateItem { status = replace(target, data: data) }
                if denied(status) {
                    target[kSecAttrAccount as String] = fresh(original)
                    status = insert(target, data: data, attributes: attributes)
                }
            }
            if status == errSecSuccess, let selected = target[kSecAttrAccount as String] as? String, selected != original {
                keepRoute(key, selected)
            }
            return status
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.lock(); defer { lock.unlock() }
            guard let key = routeKey(query) else { return errSecParam }
            let account = route(key)
            // A removal must not uncover an old value, even if its ACL keeps
            // us from deleting it. An empty route is a persistent tombstone.
            keepRoute(key, "")
            if account == "" { return errSecItemNotFound }
            var query = query
            if let account { query[kSecAttrAccount as String] = account }
            return remove(query)
        }

        private func insert(_ query: [String: Any], data: Data, attributes: [String: Any]) -> OSStatus {
            var item = attributes
            item.merge(query) { _, identity in identity }
            item[kSecValueData as String] = data
            return add(item)
        }

        private func replace(_ query: [String: Any], data: Data) -> OSStatus {
            let status = update(query, [kSecValueData as String: data])
            guard status == errSecSuccess else { return status }
            // The file keychain can accept an update across a signing change
            // while still refusing to read the value back. Metadata alone
            // does not prove access to the secret. Rotate on that denial too.
            var ask = query
            ask[kSecReturnData as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: CFTypeRef?
            return copy(ask, &found)
        }

        private func denied(_ status: OSStatus) -> Bool {
            status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecNoAccessForItem
        }

        private func fresh(_ account: String) -> String { account + ".yab." + UUID().uuidString }

        private func routeKey(_ query: [String: Any]) -> String? {
            guard query[kSecClass as String] as? String == kSecClassGenericPassword as String,
                  let service = query[kSecAttrService as String] as? String,
                  let account = query[kSecAttrAccount as String] as? String,
                  query[kSecAttrSynchronizable as String] as? Bool != true else { return nil }
            let identity = [service, account, query[kSecAttrAccessGroup as String] as? String ?? "",
                            query[kSecUseDataProtectionKeychain as String] as? Bool == true ? "protected" : "login"]
            return "keychain.accounts.v1." + identity.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
        }
    }
}
