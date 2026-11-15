import CryptoKit
import Foundation
import LocalAuthentication
import Security
import os

/// Signs a yes on this iPhone: Face ID first, then a key that never leaves
/// the phone signs the request's digest. On an iPhone the key lives in the
/// Secure Enclave and only opens for the face it was made with; the
/// simulator has no enclave, so it signs with a key of its own made at
/// launch only for fixture runs. The Mac checks the signature against what it asked before it
/// presses the site's button.
@MainActor
protocol YesSigner: AnyObject {
    /// The key the Mac learns at pairing.
    var publicKey: P256.Signing.PublicKey { get }
    /// Face ID, then the signature. Throws when the face isn't recognized or
    /// the person cancels.
    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes
    /// Whether the system shows its own Face ID panel while signing; when it
    /// doesn't, Yab draws the panel itself.
    var showsSystemPanel: Bool { get }
}

enum YesSignerError: Error, Equatable {
    case notRecognized
    case cancelled
    case unavailable(String)
}

/// Task execution is unavailable in live mode, so it needs neither the
/// person's signing key nor a Face ID prompt.
@MainActor
final class UnavailableYesSigner: YesSigner {
    private let key = P256.Signing.PrivateKey()
    var publicKey: P256.Signing.PublicKey { key.publicKey }
    var showsSystemPanel: Bool { false }
    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes {
        throw YesSignerError.unavailable("Tasks on your Mac aren’t available yet")
    }
}

/// Face ID through LocalAuthentication, the signature from the Secure
/// Enclave. A real device never falls back to a software key.
@MainActor
final class FaceIDSigner: YesSigner {
    private let key: SigningKey
    private let allowsFixtureRequests: Bool
    let showsSystemPanel = true

    private enum SigningKey {
        case enclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case let .enclave(key): key.publicKey
            case let .software(key): key.publicKey
            }
        }
    }

    init(allowsFixtureRequests: Bool = false) throws {
        self.allowsFixtureRequests = allowsFixtureRequests
        key = try Self.makeKey(allowsFixtureRequests: allowsFixtureRequests)
    }

    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes {
        _ = try request.approvalDigest(task: task, key: publicKey, allowsFixture: allowsFixtureRequests)
        let context = LAContext()
        context.localizedCancelTitle = "Not Now"
        var problem: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &problem) else {
            throw YesSignerError.unavailable(problem?.localizedDescription ?? "Face ID isn’t set up")
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Sign this exact \(request.noun) for your Mac")
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            throw YesSignerError.cancelled
        } catch {
            Logger(subsystem: "dev.serafim.fast.iphone", category: "tasks").info("Face ID: \(String(describing: error), privacy: .public)")
            throw YesSignerError.notRecognized
        }
        let digest = try request.approvalDigest(task: task, key: publicKey, allowsFixture: allowsFixtureRequests)
        let signature: Data
        switch key {
        case let .enclave(enclaveKey):
            // The enclave key opens with this context's Face ID: no second prompt.
            let opened = (try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: enclaveKey.dataRepresentation, authenticationContext: context)) ?? enclaveKey
            signature = try opened.signature(for: digest).rawRepresentation
        case let .software(softwareKey):
            signature = try softwareKey.signature(for: digest).rawRepresentation
        }
        return SignedYes(digest: digest, signature: signature)
    }

    /// The enclave key kept in the Keychain from the first launch, else a new
    /// one; no enclave (the simulator): a key for this launch.
    private static func makeKey(allowsFixtureRequests: Bool) throws -> SigningKey {
        #if targetEnvironment(simulator)
        // Software keys are only for an explicit fixture run in a simulator.
        guard allowsFixtureRequests else { throw YesSignerError.unavailable("Secure Enclave isn’t available") }
        return .software(P256.Signing.PrivateKey())
        #else
        guard SecureEnclave.isAvailable else { throw YesSignerError.unavailable("Secure Enclave isn’t available") }

        if let data = Keychain.read(), let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
            return .enclave(key)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) else {
            throw YesSignerError.unavailable("Couldn’t create the Face ID signing key")
        }
        guard Keychain.write(key.dataRepresentation) else { throw YesSignerError.unavailable("Couldn’t save the Face ID signing key") }
        return .enclave(key)
        #endif
    }

    /// The enclave key's handle (not the key: that never leaves the enclave).
    private enum Keychain {
        static let service = "dev.serafim.fast.iphone.yes"

        static func read() -> Data? {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }

        static func write(_ data: Data) -> Bool {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
    }
}

/// For test runs without a face to show: `-YabFaceID match` signs after the
/// panel's 0.65 s, `-YabFaceID nomatch` doesn't. Yab draws the panel itself.
@MainActor
final class StandInSigner: YesSigner {
    private let key = P256.Signing.PrivateKey()
    let match: Bool
    let showsSystemPanel = false

    init(match: Bool) {
        self.match = match
    }

    var publicKey: P256.Signing.PublicKey { key.publicKey }

    func sign(_ request: YesRequest, task: TaskRun.ID) async throws -> SignedYes {
        try? await Task.sleep(for: .seconds(Metrics.FaceIDPanel.looks))
        guard match else { throw YesSignerError.notRecognized }
        let digest = request.digest(task: task)
        return SignedYes(digest: digest, signature: try key.signature(for: digest).rawRepresentation)
    }
}
