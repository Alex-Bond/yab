import Foundation
import Network
import CryptoKit

/// An ephemeral test endpoint; records received bytes independently of JS errors.
final class LocalNetworkFixture: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: String
        let body: Data
        let at: Date
    }
    struct Reply {
        var status = "200 OK"
        var type = "text/html"
        var headers = ""
        var cacheControl = "no-store"
        var body: Data
        init(_ text: String, status: String = "200 OK", headers: String = "") {
            self.body = Data(text.utf8); self.status = status; self.headers = headers
        }
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-network-fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var received: [Request] = []
    private var incoming: [ObjectIdentifier: Int] = [:]
    private var packets: [Data] = []
    private var routes: [String: Reply] = [:]
    private var accepted = 0
    private(set) var port: UInt16 = 0
    var root: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { locked { received } }
    var messages: [Data] { locked { packets } }
    var tcpConnections: Int { locked { accepted } }

    init() throws {
        let parameters = NWParameters.tcp
        let selected = NWEndpoint.Port(rawValue: 0)!
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: selected)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed(let error) = state { print("LNA_LISTENER_FAILED \(error)"); ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.locked { self.accepted += 1; self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let assigned = listener.port else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
        port = assigned.rawValue
    }
    func route(_ path: String, _ reply: Reply) { locked { routes[path] = reply } }
    func stop() {
        listener.cancel()
        locked { connections.forEach { $0.cancel() }; connections.removeAll() }
    }
    deinit { stop() }
    private func locked<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    private func read(_ connection: NWConnection, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, finished, error in
            guard let self else { return }
            var data = accumulated; if let bytes { data.append(bytes) }
            guard data.count <= 1 << 20 else { connection.cancel(); return }
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<end.lowerBound], encoding: .utf8),
                  let line = head.components(separatedBy: "\r\n").first else {
                if !finished && error == nil { self.read(connection, data) } else { connection.cancel() }
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count == 3 else { connection.cancel(); return }
            let path = String(parts[1])
            // Count headers immediately, even if the sender never completes
            // its POST body. Negative assertions must catch partial requests.
            let index = self.locked { () -> Int in
                let identity = ObjectIdentifier(connection)
                if let index = self.incoming[identity] { return index }
                let index = self.received.count
                self.incoming[identity] = index
                self.received.append(Request(method: String(parts[0]), path: path, headers: head, body: Data(), at: Date()))
                return index
            }
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
            guard length >= 0, length <= 1 << 20 else { connection.cancel(); return }
            guard data.count - end.upperBound >= length else {
                if !finished && error == nil { self.read(connection, data) } else { connection.cancel() }
                return
            }
            let body = Data(data[end.upperBound..<(end.upperBound + length)])
            self.locked { self.received[index] = Request(method: String(parts[0]), path: path, headers: head, body: body, at: self.received[index].at) }
            if let keyLine = head.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) {
                let key = keyLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
                let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                let accept = Data(digest).base64EncodedString()
                let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { error in
                    if error == nil { self.socket(connection, Data(data.dropFirst(end.upperBound))) } else { connection.cancel() }
                })
                return
            }
            let reply = self.locked { self.routes[path] ?? self.routes[String(path.split(separator: "?")[0])] ?? Reply("fixture") }
            var response = Data("HTTP/1.1 \(reply.status)\r\nContent-Type: \(reply.type)\r\nContent-Length: \(reply.body.count)\r\nConnection: close\r\nCache-Control: \(reply.cacheControl)\r\n\(reply.headers)\r\n".utf8)
            response.append(reply.body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    private func socket(_ connection: NWConnection, _ data: Data) {
        var buffer = data
        while buffer.count >= 2 {
            let bytes = Array(buffer)
            let count = Int(bytes[1] & 127)
            // Fixtures only exchange short test messages, including real masking.
            guard count < 126, bytes[1] & 128 != 0 else { connection.cancel(); return }
            guard bytes.count >= 6 + count else { break }
            let payload = Data((0..<count).map { bytes[6 + $0] ^ bytes[2 + $0 % 4] })
            if bytes[0] & 15 == 8 { connection.cancel(); return }
            if [1, 2].contains(bytes[0] & 15) {
                locked { packets.append(payload) }
                var frame = Data([0x81, UInt8(payload.count)]); frame.append(payload)
                connection.send(content: frame, completion: .contentProcessed { _ in })
            }
            buffer.removeFirst(6 + count)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, finished, error in
            guard let self, !finished, error == nil, let bytes else { connection.cancel(); return }
            buffer.append(bytes)
            guard buffer.count <= 65536 else { connection.cancel(); return }
            self.socket(connection, buffer)
        }
    }
}
