import CryptoKit
import Foundation

/// Joining by a code the other way round (docs/sync.md, "The key and the
/// account", 2): a device already in the account shows a code, as text and
/// as a QR (a Mac's Add a Device), and a new device scans or types it (an
/// iPhone's Scan QR). The new device posts its one-time key under the code
/// in the same pairing box Joining uses, both screens show four digits
/// worked out from that key, and the device already in seals the account's
/// key to it only once the person says the digits match: whoever saw the
/// code (over a shared screen, say) and posted first gets nothing without
/// that yes. The QR holds the code and nothing else; the code names the
/// box, and nothing opens with it.
public enum JoinInvite {
    /// What the QR says: `yab://join/ABCD-EFGH`. Yab for iPhone opens on it
    /// from the Camera too.
    public static func link(_ code: String) -> String { "yab://join/" + (pretty(code) ?? code) }

    /// A new code to show.
    public static func make() -> String { Joining.makeCode() }

    /// The code in what was scanned or typed: the link above, or the eight
    /// letters and digits alone, any case, dashes and spaces ignored. Nil
    /// for anything else (another QR, a web address).
    public static func code(scanned text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("yab:") {
            guard let url = URL(string: body), url.scheme?.lowercased() == "yab", url.host?.lowercased() == "join" else { return nil }
            body = url.path
        } else if body.contains(":") || body.contains("/") || body.contains(".") {
            return nil
        }
        return pretty(body)
    }

    /// "ABCD-EFGH" for a code made of Joining's letters, else nil.
    static func pretty(_ text: String) -> String? {
        let letters = Joining.normalize(text)
        guard letters.count == 8, letters.allSatisfy({ Joining.alphabet.contains($0) }) else { return nil }
        return String(letters.prefix(4)) + "-" + String(letters.suffix(4))
    }

    /// The four digits both screens show for a key posted under a code.
    public static func check(code: String, publicKey: Data) -> String {
        var data = Data("yab sync check v1".utf8)
        data.append(0)
        data.append(Data(Joining.normalize(code).utf8))
        data.append(0)
        data.append(publicKey)
        let bytes = Array(SHA256.hash(data: data))
        let number = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 10_000
        return String(format: "%04u", number)
    }
}

/// The device already in, showing an invite: it waits for a new device's
/// key under the code, says its digits, and seals the account's key to it
/// once told to (`letIn`). Everything on its own queue; events on any.
public final class JoinInviteHost: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// A device posted its key: the four digits it shows.
        case arrived(check: String)
        /// The key went to it.
        case letIn
        /// Ten minutes and nobody came.
        case expired
        /// The box was answered by someone else, or sealing or sending failed.
        case failed
    }

    public let code: String
    private let base: URL
    private let transport: any Transport
    private let timeout: TimeInterval
    private let every: TimeInterval
    private let queue = DispatchQueue(label: "sync.invite")
    private var events: (@Sendable (Event) -> Void)?
    private var until = Date.distantFuture
    private var key: Data?

    public init(code: String = JoinInvite.make(), base: URL, transport: (any Transport)? = nil,
                timeout: TimeInterval = 600, every: TimeInterval = 2) {
        self.code = JoinInvite.pretty(code) ?? code
        self.base = base
        self.transport = transport ?? WebTransport()
        self.timeout = timeout
        self.every = every
    }

    /// What the QR says.
    public var link: String { JoinInvite.link(code) }

    /// Waits for a device; `events` until the last one (letIn, expired, failed).
    public func start(_ events: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            self.events = events
            until = Date().addingTimeInterval(timeout)
            poll(after: 0)
        }
    }

    /// Nothing more is read or sent, and nothing more is said.
    public func cancel() {
        queue.async { [self] in events = nil }
    }

    /// The person said the digits match: the account's key, sealed to the
    /// device that posted under the code.
    public func letIn(_ seal: Seal) {
        queue.async { [self] in
            guard events != nil, let key, let envelope = try? Joining.seal(seal, to: key, code: code) else { return finish(.failed) }
            var put = URLRequest(url: base.appendingPathComponent("v1/pair/\(Joining.box(code))"))
            put.httpMethod = "PUT"
            put.setValue("application/json", forHTTPHeaderField: "Content-Type")
            put.httpBody = try? JSONSerialization.data(withJSONObject: ["envelope": envelope.base64EncodedString()])
            transport.request(put) { [self] status, _ in
                queue.async { [self] in finish(status == 204 || status == 200 ? .letIn : .failed) }
            }
        }
    }

    private func poll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard events != nil, key == nil else { return }
            guard Date() < until else { return finish(.expired) }
            transport.request(URLRequest(url: base.appendingPathComponent("v1/pair/\(Joining.box(code))"))) { [self] status, data in
                queue.async { [self] in heard(status, data) }
            }
        }
    }

    private func heard(_ status: Int?, _ data: Data?) {
        guard events != nil, key == nil else { return }
        guard status == 200, let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Nobody yet (404), or no network for a moment: again shortly.
            return poll(after: every)
        }
        // Answered already: not by this device, so not the person's device.
        if body["envelope"] != nil { return finish(.failed) }
        // A key whose tag the code didn't make: swapped in, or an older Yab.
        guard let pub = Joining.verified(body["pub"] as? String, code: code) else { return finish(.failed) }
        key = pub
        events?(.arrived(check: JoinInvite.check(code: code, publicKey: pub)))
    }

    private func finish(_ event: Event) {
        guard let events else { return }
        self.events = nil
        events(event)
    }
}
