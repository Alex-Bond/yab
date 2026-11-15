import AppKit
import Security
import SecurityInterface

/// Private keys stay in Keychain (WebKit) or Chromium. Only the person's
/// selection of one of the server's candidates crosses the engine boundary.
@MainActor
final class ClientCertificates: NSObject {
    private static var pending: [ObjectIdentifier: ClientCertificates] = [:]
    private let panel = SFChooseIdentityPanel()
    private weak var parent: NSWindow?
    private weak var owner: NSView?
    private var closed: NSObjectProtocol?
    private var reply: ((SecIdentity?) -> Void)?

    nonisolated static func identities(issuers: [Data] = [], checkingPolicy: Bool = true) -> [SecIdentity] {
        var query: [CFString: Any] = [kSecClass: kSecClassIdentity,
                                     kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll]
        if checkingPolicy { query[kSecMatchPolicy] = SecPolicyCreateSSL(false, nil) }
        if !issuers.isEmpty { query[kSecMatchIssuers] = issuers }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        return (result as? [SecIdentity]) ?? []
    }

    nonisolated static func certificate(_ identity: SecIdentity) -> Data? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    static func choose(in view: NSView, host: String, port: Int, issuers: [Data] = [],
                       candidates: [Data]? = nil, reply: @escaping (SecIdentity?) -> Void) {
        // A hidden/background page cannot put up an unowned authentication dialog.
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor, !host.isEmpty else { reply(nil); return }
        let key = ObjectIdentifier(window)
        pending[key]?.finish(nil)
        let request = ClientCertificates()
        request.parent = window
        request.owner = view
        request.reply = reply
        pending[key] = request
        request.closed = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak request] _ in
                MainActor.assumeIsolated { request?.finish(nil) }
            }
        DispatchQueue.global(qos: .userInitiated).async {
            // Chromium already pruned its candidates. Do not apply another
            // engine's trust policy and accidentally hide an accepted identity.
            let identities = Self.identities(issuers: issuers, checkingPolicy: candidates == nil).filter { identity in
                guard let candidates else { return true }
                return Self.certificate(identity).map(candidates.contains) ?? false
            }
            DispatchQueue.main.async {
                guard request.reply != nil else { return }
                guard view.window === window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
                      !identities.isEmpty else { request.finish(nil); return }
                request.panel.setPolicies(SecPolicyCreateSSL(false, nil))
                request.panel.beginSheet(for: window, modalDelegate: request,
                    didEnd: #selector(ClientCertificates.didEnd(_:returnCode:contextInfo:)), contextInfo: nil,
                    identities: identities, message: "Choose a certificate to sign in to \(host):\(port).")
            }
        }
    }

    static func cancel(in view: NSView) {
        for request in Array(pending.values) where request.owner === view { request.finish(nil) }
    }

    @objc private func didEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        guard returnCode == NSApplication.ModalResponse.OK.rawValue else { finish(nil); return }
        finish(panel.identity()?.takeUnretainedValue())
    }

    private func finish(_ identity: SecIdentity?) {
        guard let reply else { return }
        self.reply = nil
        if let closed { NotificationCenter.default.removeObserver(closed); self.closed = nil }
        if let parent {
            Self.pending.removeValue(forKey: ObjectIdentifier(parent))
            if panel.sheetParent != nil { parent.endSheet(panel) }
        }
        panel.orderOut(nil)
        reply(identity)
    }
}
