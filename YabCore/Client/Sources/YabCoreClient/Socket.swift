import Foundation
import Darwin
import CryptoKit


/// Transport facts ONLY. No peer/document/native phase authority. Constructor
/// is confined to the actual Socket; caller JSON cannot manufacture this ticket.
final class SocketWriteTicket: @unchecked Sendable {
    enum Phase: String, Sendable { case created, enqueued, allWritten, notEnqueued, unknown }
    struct Snapshot: Equatable, Sendable {
        let connection, request, frameSHA256: String
        let total, written: Int
        let phase: Phase
    }
    private let lock = NSLock()
    private let connection, request, frameSHA256: String
    private let total: Int
    private var written = 0
    private var phase: Phase = .created
    private let changed: @Sendable () -> Void
    fileprivate init(connection: String, request: String, frame: Data, changed: @escaping @Sendable () -> Void) {
        self.connection = connection; self.request = request; self.total = frame.count
        self.frameSHA256 = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
        self.changed = changed
    }
    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(connection: connection, request: request, frameSHA256: frameSHA256,
                        total: total, written: written, phase: phase)
    }
    fileprivate func queued() {
        lock.lock(); let before = phase
        if phase == .created { phase = .enqueued }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
    fileprivate func advance(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock(); let before = phase
        if phase == .enqueued, bytes <= total - written {
            written += bytes; if written == total { phase = .allWritten }
        }
        let transitioned = before != phase; lock.unlock()
        // Partial writes update their own byte count without scheduling actor
        // work; only the queued→allWritten transition needs notification.
        if transitioned { changed() }
    }
    fileprivate func refusedBeforeQueue() {
        lock.lock(); let before = phase
        if phase == .created { phase = .notEnqueued }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
    fileprivate func lost() {
        lock.lock(); let before = phase
        if phase != .allWritten && phase != .notEnqueued { phase = .unknown }
        let transitioned = before != phase; lock.unlock()
        if transitioned { changed() }
    }
}
/// Relative to the CURRENT output buffer, never a global byte dispatch counter.
private struct SocketWriteSpan {
    var before: Int
    let ticket: SocketWriteTicket
    mutating func consumed(_ count: Int) {
        let skipped = min(before, count); before -= skipped
        let remaining = ticket.snapshot().total - ticket.snapshot().written
        ticket.advance(min(count - skipped, remaining))
    }
}

/// All descriptor and buffer access is confined to this queue. No blocking reads
/// or writes run on the UI thread or on the client's actor.
final class Socket: @unchecked Sendable {
    static let limit = 4 * 1024 * 1024
    /// Queued bytes the helper has not read yet. Overflow disconnects, and a
    /// disconnect ends the helper and every Chromium page: with 138 tabs
    /// loading, each page's scripts outran a busy helper past 8 MB (run
    /// 3c40191600534aee, "Outgoing buffer limit exceeded"). The bytes are
    /// in this process's memory either way.
    static let outgoingLimit = 256 * 1024 * 1024
    private let queue = DispatchQueue(label: "com.yab.core.socket")
    private var fd: Int32
    private let maxWriteBatchBytes: Int
    private let originalLaunch: NativePeerIdentity.LaunchWitness?
    private let originalPeer: NativePeerIdentity?
    private let originalConnection = UUID().uuidString.lowercased()
    private var originalPeerUncertain = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var input = Data()
    private var output = Data()
    private var trackedWrites: [SocketWriteSpan] = []
    let messages: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation

    init(path: String, originalLaunch: NativePeerIdentity.LaunchWitness? = nil, maxWriteBatchBytes: Int = 262_144) throws {
        guard (1...262_144).contains(maxWriteBatchBytes) else { throw YabCoreError.protocolViolation("Invalid socket write batch") }
        self.maxWriteBatchBytes = maxWriteBatchBytes
        self.originalLaunch = originalLaunch
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw YabCoreError.transport("Unix socket path is too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw YabCoreError.transport(String(cString: strerror(errno))) }
        fd = descriptor
        let status = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let message = String(cString: strerror(errno)); Darwin.close(descriptor)
            throw YabCoreError.transport(message)
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(descriptor); throw YabCoreError.transport("Socket peer is not the current user")
        }
        // Optional strict witness failure never changes ordinary routes.
        originalPeer = originalLaunch?.bind(socket: descriptor)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var sink: AsyncThrowingStream<Data, Error>.Continuation!
        messages = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8_192)) { sink = $0 } // a backlog past this ends the helper and every page (see Client.events)
        continuation = sink
    }
    var originalHandshakeParameters: [String: JSONValue] {
        originalPeer == nil ? [:] : ["originalPeerClientNonce": .string(originalConnection)]
    }
    func acceptedOriginalCounterpart(_ hello: JSONValue) async -> NativeOriginalGroupCounterpart? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard fd >= 0, !originalPeerUncertain, let launch = originalLaunch, let peer = originalPeer else { continuation.resume(returning: nil); return }
                continuation.resume(returning: launch.acceptedCounterpart(socket: fd, original: peer, hello: hello, clientNonce: originalConnection))
            }
        }
    }
    func originalPeerObservation() async -> NativeOriginalPeerObservation {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let launch = originalLaunch, let peer = originalPeer else { continuation.resume(returning: .unavailable); return }
                guard fd >= 0, !originalPeerUncertain else { continuation.resume(returning: .unknown); return }
                guard launch.reobserve(socket: fd, original: peer) == .current else {
                    originalPeerUncertain = true; continuation.resume(returning: .unknown); return
                }
                continuation.resume(returning: .observed(NativeOriginalPeerSource(evidence: peer.evidence, connection: originalConnection)))
            }
        }
    }
    func start() {
        queue.async { [self] in
            guard fd >= 0, readSource == nil else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readReady() }
            readSource = source; source.resume()
        }
    }
    func send(_ data: Data) {
        queue.async { [self] in
            guard fd >= 0 else { return }
            guard data.count <= Self.limit, output.count + data.count < Self.outgoingLimit else {
                finish(YabCoreError.protocolViolation("Outgoing buffer limit exceeded")); return
            }
            output.append(data); output.append(10); writeReady()
        }
    }
    /// Actual stream ticket; even allWritten means ONLY this frame's bytes
    /// (including LF) reached Darwin.write, never helper/native application.
    func prepareTracked(_ data: Data, request: String, changed: @escaping @Sendable () -> Void = {}) -> SocketWriteTicket {
        let frame: Data = { var bytes = data; bytes.append(10); return bytes }()
        return SocketWriteTicket(connection: originalConnection, request: request, frame: frame, changed: changed)
    }
    func enqueueTracked(_ data: Data, ticket: SocketWriteTicket) {
        let frame: Data = { var bytes = data; bytes.append(10); return bytes }()
        queue.async { [self] in
            let own = ticket.snapshot()
            let hash = SHA256.hash(data: frame).map { String(format: "%02x", $0) }.joined()
            guard own.phase == .created, own.connection == originalConnection,
                  own.total == frame.count, own.frameSHA256 == hash else {
                ticket.refusedBeforeQueue(); return
            }
            guard fd >= 0, data.count <= Self.limit, trackedWrites.count < 32,
                  frame.count <= Self.outgoingLimit - output.count else {
                ticket.refusedBeforeQueue(); return
            }
            trackedWrites.append(SocketWriteSpan(before: output.count, ticket: ticket))
            output.append(frame); ticket.queued(); writeReady()
        }
    }
    /// Ordinary transport testing/diagnostics. Does NOT grant original authority.
    @discardableResult func sendTracked(_ data: Data, request: String) -> SocketWriteTicket {
        let ticket = prepareTracked(data, request: request)
        enqueueTracked(data, ticket: ticket); return ticket
    }
    func close() { queue.async { [self] in finish(nil) } }
    private func finish(_ error: Error?) {
        guard fd >= 0 else { return }
        originalPeerUncertain = true
        trackedWrites.forEach { $0.ticket.lost() }; trackedWrites.removeAll()
        output.removeAll(keepingCapacity: false)
        readSource?.cancel(); writeSource?.cancel()
        readSource = nil; writeSource = nil
        Darwin.close(fd); fd = -1
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
    private func readReady() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<16 {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n == 0 { finish(nil); return }
            if n < 0 {
                if errno != EAGAIN && errno != EINTR { finish(YabCoreError.transport(String(cString: strerror(errno)))) }
                return
            }
            input.append(contentsOf: buffer.prefix(n))
            while let end = input.firstIndex(of: 10) {
                guard input.distance(from: input.startIndex, to: end) <= Self.limit else {
                    finish(YabCoreError.protocolViolation("Incoming message is too large")); return
                }
                let data = Data(input[..<end]); input.removeSubrange(...end)
                switch continuation.yield(data) {
                case .dropped: finish(YabCoreError.protocolViolation("Incoming message backlog exceeded")); return
                case .terminated: finish(nil); return
                case .enqueued: break
                @unknown default: break
                }
            }
            if input.count > Self.limit { finish(YabCoreError.protocolViolation("Incoming message is too large")); return }
        }
    }
    private func writeReady() {
        guard fd >= 0 else { return }
        while !output.isEmpty {
            let n = output.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min($0.count, maxWriteBatchBytes)) }
            if n > 0 {
                // Account this exact write against EACH frame's own span. Older
                // queued bytes can never count as this request's forwarding.
                for index in trackedWrites.indices { trackedWrites[index].consumed(n) }
                trackedWrites.removeAll { $0.ticket.snapshot().phase == .allWritten }
                output.removeFirst(n)
            }
            else if n < 0 && errno == EINTR { continue }
            else if n < 0 && errno == EAGAIN {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                    source.setEventHandler { [weak self] in self?.writeReady() }
                    writeSource = source; source.resume()
                }
                return
            } else { finish(YabCoreError.transport("Socket write failed")); return }
        }
        writeSource?.cancel(); writeSource = nil
    }
    deinit { if fd >= 0 { Darwin.close(fd) } }
}
