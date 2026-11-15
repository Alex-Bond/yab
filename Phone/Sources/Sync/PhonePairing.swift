import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

// The iPhone joining by a code (docs/sync.md, "The key and the account", 2):
// it shows eight characters, you type them on a Mac in Settings › Sync ›
// Add a Device, and that Mac seals the key to this iPhone's one-time X25519
// key through the server's pairing box (POST /v1/pair, GET and PUT
// /v1/pair/<name stretched from the code>). SyncKit's Joining does the sealing; this
// is the waiting, made to last the box's ten minutes.
//
// The deployed server forgets a box after 20 reads of any kind, and a read
// every 2 s spends them in 40 s, after which a code typed on the Mac finds
// nothing; SyncKit's Pairing.ask gives up there. sync-server now counts only
// the reads that carry the envelope away (R1, sync-ios.md), and until the
// deployed Worker has it this keeps the same code on screen for the ten
// minutes: after 18 reads of its own it reads the box out at once and puts
// it back, so a box is never left a read or two from its end, where the
// Mac's read would delete it. A server that never forgets (R1) is noticed
// and read at the usual pace; then this can go.

public nonisolated final class PhonePairing: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        /// Ten minutes and no Mac answered.
        case expired
        case cancelled
        /// The server wouldn't take the box (its answer, nil for none).
        case server(Int?)
        /// An answer came that this iPhone can't open: not sealed to it.
        case unreadable
    }

    /// What the iPhone shows: "ABCD-EFGH".
    public var code: String { joining.code }
    /// Waiting under a code a Mac showed (JoinInvite), not this iPhone's own.
    public let invited: Bool
    /// The four digits the Mac asks about for this iPhone's key (JoinInvite).
    public var check: String { JoinInvite.check(code: joining.code, publicKey: joining.publicKey) }

    private let joining: Joining
    private let base: URL
    private let transport: any Transport
    private let timeout: TimeInterval
    private let every: TimeInterval
    private let queue = DispatchQueue(label: "phone.sync.pairing")
    private var done: (@Sendable (Result<Seal, Failure>) -> Void)?
    private var until = Date.distantFuture
    /// How many times the box was put back; for tests and logs.
    public private(set) var reposts = 0
    /// This iPhone's reads of the box as it stands now.
    private var reads = 0
    /// Reads before the box is read out and put back: two short of the
    /// server's 20, one for the Mac and one to spare.
    private static let budget = 18

    public init(base: URL = PhoneSync.defaultBase, transport: (any Transport)? = nil, timeout: TimeInterval = 600, every: TimeInterval = 2,
                code: String? = nil, invited: Bool = false) {
        joining = Joining(code: code)
        self.invited = invited
        self.base = base
        self.transport = transport ?? WebTransport()
        self.timeout = timeout
        self.every = every
    }

    /// Puts the box up and waits for a Mac to answer; `done` once, on any queue.
    public func start(_ done: @escaping @Sendable (Result<Seal, Failure>) -> Void) {
        queue.async { [self] in
            self.done = done
            until = Date().addingTimeInterval(timeout)
            post(first: true)
        }
    }

    public func cancel() {
        queue.async { [self] in finish(.failure(.cancelled)) }
    }

    private func post(first: Bool) {
        var request = URLRequest(url: base.appendingPathComponent("v1/pair"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["code": joining.box, "pub": joining.posted])
        transport.request(request) { [self] status, _ in
            queue.async { [self] in
                guard done != nil else { return }
                switch status {
                case 204?, 200?: reads = 0; poll(after: every)
                // Still there after all (another read put it back between):
                // keep reading it.
                case 409? where !first: poll(after: every)
                // Taken, or a box the server won't keep: said at once.
                case 409?, 400?: first ? finish(.failure(.server(status))) : poll(after: every)
                // No network for a moment, or the door busy (429): the
                // same box again a little later, within the ten minutes.
                // Before, the first of these ended joining by a Mac's code
                // with "couldn't let this iPhone in" (register 1659).
                default:
                    guard Date() < until else { return finish(.failure(.expired)) }
                    queue.asyncAfter(deadline: .now() + every * 2) { [self] in
                        guard done != nil else { return }
                        post(first: first)
                    }
                }
            }
        }
    }

    private func poll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard done != nil else { return }
            guard Date() < until else { return finish(.failure(.expired)) }
            transport.request(URLRequest(url: base.appendingPathComponent("v1/pair/\(joining.box)"))) { [self] status, data in
                queue.async { [self] in read(status, data) }
            }
        }
    }

    private func read(_ status: Int?, _ data: Data?) {
        guard done != nil else { return }
        switch status {
        case 200?:
            guard let data, let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return poll(after: every) }
            if let envelope = (body["envelope"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                if let seal = try? joining.open(envelope) { finish(.success(seal)) } else { finish(.failure(.unreadable)) }
                return
            }
            reads += 1
            switch reads {
            // Near the end: read it out now, back to back, then put it back.
            case PhonePairing.budget..<(PhonePairing.budget + 3): poll(after: 0)
            // A server that never forgets a box: back to the usual pace.
            case (PhonePairing.budget + 3)...: reads = 0; poll(after: every)
            default: poll(after: every)
            }
        case 404?:
            // Read out, or swept: the same code again, a fresh box.
            reposts += 1
            post(first: false)
        default:
            // No network for a moment: try again, a little later.
            poll(after: every * 2)
        }
    }

    private func finish(_ result: Result<Seal, Failure>) {
        guard let done else { return }
        self.done = nil
        done(result)
    }
}
