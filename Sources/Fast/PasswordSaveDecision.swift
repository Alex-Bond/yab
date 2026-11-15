import Foundation
import CryptoKit

/// Both page engines deliver settled submissions to this comparison. A manager
/// lookup must finish before a Save/Update card can be chosen.
@MainActor
enum PasswordSaveDecision: Equatable {
    case none, save, update

    private struct Write {
        var count = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private static var writes: [String: Write] = [:]

    static func beginSave(_ login: Login) {
        writes[key(host: login.host, user: login.user), default: Write()].count += 1
    }

    static func endSave(_ login: Login) {
        let id = key(host: login.host, user: login.user)
        guard var write = writes[id] else { return }
        write.count -= 1
        if write.count == 0 {
            writes[id] = nil
            write.waiting.forEach { $0.resume() }
        } else {
            writes[id] = write
        }
    }

    static func waitForSave(_ login: Login) async {
        let id = key(host: login.host, user: login.user)
        guard writes[id] != nil else { return }
        await withCheckedContinuation { continuation in
            writes[id]?.waiting.append(continuation)
        }
    }

    // Exact secrets already read from or successfully written to Apple this
    // launch. Hashes avoid retaining fill secrets and another authentication
    // just to compare the password the person has submitted. Never persisted.
    private static var confirmed: [String: SHA256.Digest] = [:]

    private static func key(host: String, user: String) -> String {
        Vault.registrable(host.lowercased()) + "\u{1}" + user
    }

    static func remember(host: String, user: String, password: String) {
        confirmed[key(host: host, user: user)] = SHA256.hash(data: Data(password.utf8))
    }

    static func check(_ submitted: Login, known: [Login], apple: (any ManagerAdapter)?) async -> Self {
        let local = known.filter {
            Vault.registrable($0.host.lowercased()) == Vault.registrable(submitted.host.lowercased()) && $0.user == submitted.user
        }
        if local.contains(where: { Data($0.password.utf8) == Data(submitted.password.utf8) }) { return .none }
        guard let apple else { return local.isEmpty ? .save : .update }
        let id = key(host: submitted.host, user: submitted.user)
        let remembered = confirmed[id]
        if remembered == SHA256.hash(data: Data(submitted.password.utf8)) { return .none }
        do {
            let accounts = try await apple.logins(for: submitted.host).filter {
                $0.user == submitted.user && ManagerVault.matches($0.urls, host: submitted.host)
            }
            for account in accounts {
                let secret = try await apple.secret(account)
                if secret.user == submitted.user && Data(secret.password.utf8) == Data(submitted.password.utf8) {
                    remember(host: submitted.host, user: submitted.user, password: submitted.password)
                    return .none
                }
            }
            return local.isEmpty && accounts.isEmpty && remembered == nil ? .save : .update
        } catch {
            // Locked, refused or unavailable is not evidence of a new password.
            // Do not put a misleading Save card over a successful sign-in.
            return .none
        }
    }
}
