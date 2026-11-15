import Foundation
import Security
import Testing
@testable import MailCore

// Mail's tokens on this Mac only (docs/casa.md, open item 3): the data
// protection keychain where the build is entitled to it, the login
// keychain otherwise, and an older Yab's items moved over without anyone
// signed out. Each test keeps its items under a service of its own.
@Suite(.serialized)
struct MailKeychainTests {
    let service = "Fast Mail (keychain test \(UUID().uuidString.prefix(8)))"

    /// An item as Yab kept it until October 2026: login keychain, AfterFirstUnlock.
    func oldItem(_ token: String, for account: String) -> OSStatus {
        var item = MailKeychain.identity(account, in: .login, service: service)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return Keychain.quietly { SecItemAdd(item as CFDictionary, nil) }
    }

    func clean(_ accounts: [String]) {
        for account in accounts {
            MailKeychain.forget(account, in: .login, service: service)
            MailKeychain.forget(account, in: .thisDevice, service: service)
        }
    }

    /// Each place is named in the query: one without the flag reaches both
    /// keychains in an entitled build, and the delete of the login copy
    /// after a save or a move took the new token too (0.32.0-0.33.0).
    @Test func eachPlaceIsAskedAlone() {
        let flag = kSecUseDataProtectionKeychain as String
        #expect(MailKeychain.identity("a@example.com", in: .login, service: service)[flag] as? Bool == false)
        #expect(MailKeychain.identity("a@example.com", in: .thisDevice, service: service)[flag] as? Bool == true)
    }

    @Test func savesReadsAndForgetsWhereTheBuildMay() {
        let account = "Keychain.Test@example.com"
        defer { clean([account]) }
        let home = MailKeychain.home
        #expect(home == (MailKeychain.entitled ? .thisDevice : .login))
        #expect(MailKeychain.save("first", for: account, in: home, service: service))
        #expect(MailKeychain.token(for: account, in: home, service: service) == "first")
        #expect(MailKeychain.save("second", for: account, in: home, service: service))
        #expect(MailKeychain.token(for: account.lowercased(), in: home, service: service) == "second")
        #expect(MailKeychain.accounts(in: home, service: service) == [account.lowercased()])
        if MailKeychain.entitled {
            // This Mac only, and nothing left behind in the login keychain.
            var ask = MailKeychain.identity(account, in: .thisDevice, service: service)
            ask[kSecReturnAttributes as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            #expect(SecItemCopyMatching(ask as CFDictionary, &out) == errSecSuccess)
            let accessible = (out as? [String: Any])?[kSecAttrAccessible as String] as? String
            #expect(accessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
            #expect(MailKeychain.token(for: account, in: .login, service: service) == nil)
        }
        MailKeychain.forget(account, in: home, service: service)
        #expect(MailKeychain.token(for: account, in: home, service: service) == nil)
    }

    /// A build without the entitlement (this test run, unless signed with
    /// Yab's profile) can't add to this Mac's keychain: the old item stays,
    /// read as before. With it, the item moves and the login copy goes.
    @Test func anOldItemMovesOrStaysReadable() {
        let account = "old@example.com"
        defer { clean([account]) }
        #expect(oldItem("refresh-old", for: account) == errSecSuccess)
        let moved = MailKeychain.moveToThisDevice(.keychain(service: service))
        if MailKeychain.entitled {
            #expect(moved == [account])
            #expect(MailKeychain.token(for: account, in: .thisDevice, service: service) == "refresh-old")
            #expect(MailKeychain.token(for: account, in: .login, service: service) == nil)
        } else {
            #expect(moved.isEmpty)
            #expect(MailKeychain.token(for: account, in: .login, service: service) == "refresh-old")
        }
    }

    /// The default move does nothing on a build that can't keep items on
    /// this Mac only, and touches no item of the person's.
    @Test func noMoveWithoutTheEntitlement() {
        guard !MailKeychain.entitled else { return }
        #expect(MailKeychain.moveToThisDevice().isEmpty)
    }

    /// The order, with a stand-in keychain: the old item goes only after
    /// the new one is read back; any step failing keeps it.
    @Test func theOldItemGoesOnlyAfterTheNewReadsBack() {
        var old = ["a@x.com": "ta", "b@x.com": "tb", "c@x.com": "tc", "d@x.com": "td"]
        var new: [String: String] = ["d@x.com": "newer"]
        var steps: [String] = []
        let move = MailKeychain.Move(
            accounts: { old.keys.sorted() + ["gone@x.com"] },
            read: { account in steps.append("read \(account)"); return old[account] },
            add: { token, account in
                steps.append("add \(account)")
                if account == "b@x.com" { return false }
                // Never over a token saved there since.
                if new[account] == nil, account != "c@x.com" { new[account] = token }
                return true
            },
            readBack: { account in steps.append("readBack \(account)"); return new[account] },
            drop: { account in steps.append("drop \(account)"); old[account] = nil })
        let moved = MailKeychain.moveToThisDevice(move)
        #expect(moved == ["a@x.com", "d@x.com"])
        // b: not added, c: not read back; both still where they were.
        #expect(old == ["b@x.com": "tb", "c@x.com": "tc"])
        #expect(new == ["a@x.com": "ta", "d@x.com": "newer"])
        #expect(steps == ["read a@x.com", "add a@x.com", "readBack a@x.com", "drop a@x.com",
                          "read b@x.com", "add b@x.com",
                          "read c@x.com", "add c@x.com", "readBack c@x.com",
                          "read d@x.com", "add d@x.com", "readBack d@x.com", "drop d@x.com",
                          "read gone@x.com"])
    }
}
