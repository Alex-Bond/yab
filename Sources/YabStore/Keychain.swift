import Foundation
import Security
import LocalAuthentication

/// One boundary for the app's keychain calls, including the old file keychain.
public enum Keychain {
    private static let interaction = Interaction()
    private static let saved = SavedItems()

    // Keep the lock order the same inside and outside a quiet transaction.
    @discardableResult
    public static func copySaved(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        quietly { saved.copyMatching(query as! [String: Any], result) }
    }

    @discardableResult
    public static func save(_ query: CFDictionary, data: Data, attributes: [String: Any] = [:]) -> OSStatus {
        quietly { saved.save(query as! [String: Any], data: data, attributes: attributes) }
    }

    @discardableResult
    public static func removeSaved(_ query: CFDictionary) -> OSStatus {
        quietly { saved.delete(query as! [String: Any]) }
    }

    public static func quietly<T>(_ body: () -> T) -> T {
        interaction.withoutUI { _ in body() }
    }

    /// Keep the item's existing home. Changing a login query to data protection
    /// without moving its item would hide a saved password or encryption key.
    static func noninteractive(_ query: CFDictionary) -> CFDictionary {
        var query = query as! [String: Any]
        let context = LAContext()
        context.interactionNotAllowed = true
        query.removeValue(forKey: kSecUseAuthenticationUI as String)
        query[kSecUseAuthenticationContext as String] = context
        return query as CFDictionary
    }

    @discardableResult
    public static func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform("read") { SecItemCopyMatching(noninteractive(query), result) }
    }

    /// A read the person asked for, such as Import's Allow for another
    /// browser's Safe Storage item, which only that browser reads unasked:
    /// the system may show its window. No quiet call has the switch off
    /// meanwhile.
    @discardableResult
    public static func copyMatchingAsking(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        report("read", interaction.asking { SecItemCopyMatching(query, result) })
    }

    @discardableResult
    public static func add(_ attributes: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        perform("add") { SecItemAdd(noninteractive(attributes), result) }
    }

    @discardableResult
    public static func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        perform("update") { SecItemUpdate(noninteractive(query), attributes) }
    }

    @discardableResult
    public static func delete(_ query: CFDictionary) -> OSStatus {
        perform("delete") { SecItemDelete(noninteractive(query)) }
    }

    private static func perform(_ operation: String, _ body: () -> OSStatus) -> OSStatus {
        report(operation, interaction.perform(body))
    }

    private static func report(_ operation: String, _ status: OSStatus) -> OSStatus {
        if status != errSecSuccess, status != errSecItemNotFound, status != errSecDuplicateItem {
            // Never include the query, account, service, or secret in a log.
            NSLog("Yab: keychain %@ failed (%d)", operation, status)
        }
        return status
    }

    /// The file keychain ignores a context's interactionNotAllowed. Its
    /// process-wide switch must stay off until the outermost call finishes.
    final class Interaction {
        private let lock = NSRecursiveLock()
        private var depth = 0
        private var disabled = false
        private var previous = false
        private let read: () -> (OSStatus, Bool)
        private let set: (Bool) -> OSStatus

        init(read: @escaping () -> (OSStatus, Bool) = {
            var allowed: DarwinBoolean = false
            let status = SecKeychainGetUserInteractionAllowed(&allowed)
            return (status, allowed.boolValue)
        }, set: @escaping (Bool) -> OSStatus = { SecKeychainSetUserInteractionAllowed($0) }) {
            self.read = read
            self.set = set
        }

        func asking<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        func perform(_ body: () -> OSStatus) -> OSStatus {
            withoutUI { disabled in disabled ? body() : errSecInteractionNotAllowed }
        }

        func withoutUI<T>(_ body: (Bool) -> T) -> T {
            lock.lock()
            if depth == 0 {
                let (status, allowed) = read()
                previous = allowed
                disabled = status == errSecSuccess && set(false) == errSecSuccess
            }
            depth += 1
            defer {
                depth -= 1
                if depth == 0, disabled {
                    let status = set(previous)
                    if status != errSecSuccess { NSLog("Yab: keychain interaction restore failed (%d)", status) }
                    disabled = false
                }
                lock.unlock()
            }
            return body(disabled)
        }
    }
}
