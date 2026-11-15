import WebKit

/// A worker at work stays, as in Chrome. Chrome starts a worker's 30 s
/// again on every call it makes to an extension API; WebKit lets a worker
/// go 30 s after its last event unless it holds an open port it was active
/// on in the last two minutes (unloadBackgroundContentIfPossible). The shim
/// (`yab.keep` in extension-shims.js) opens a port to here every 10 s from a
/// worker that called storage, tabs.query, getPlatformInfo and the like in
/// the last 30 s, each one in place of the last; here the port is only held,
/// nothing is said back. NordPass's worker, which saves a heartbeat every
/// 20 s for this, keeps its unlocked vault instead of starting again locked.
/// YAB_WORKER_KEEP=0 leaves it to WebKit.
@MainActor
enum ExtensionKeep {
    static let portName = ExtensionShims.application + ".keep"
    private static var held: [ObjectIdentifier: WKWebExtension.MessagePort] = [:]
    /// Each extension's last port and how many, for the bench.
    static var lastWord: [String: Date] = [:]
    static var words: [String: Int] = [:]

    static func hold(_ port: WKWebExtension.MessagePort, from id: String) {
        let key = ObjectIdentifier(port)
        held[key] = port
        lastWord[id] = Date()
        words[id, default: 0] += 1
        port.messageHandler = { [weak port] message, _ in
            // The shim asks whether a port has arrived before its first
            // word goes, on ports it can't tell from an app's.
            guard let body = message as? [String: Any], (body["__yabNative"] as? String) == "here?" else { return }
            MainActor.assumeIsolated {
                guard let port, !port.isDisconnected else { return }
                port.sendMessage(["__yabNative": "here"]) { _ in }
            }
        }
        port.disconnectHandler = { _ in
            MainActor.assumeIsolated { _ = held.removeValue(forKey: key) }
        }
    }
}
