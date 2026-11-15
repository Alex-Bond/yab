import CryptoKit
import Network
import SyncKit
import XCTest

/// Bounded HTTP/WebSocket protocol framing for one owned disposable account.
final class ChatWireSite: @unchecked Sendable {
    let seal = Seal.make()
    private let queue = DispatchQueue(label: "yab.tests.chat-wire")
    private let listener: NWListener
    private let mac: Journal
    private let chat: String
    private var port: UInt16 = 0, started = false, registered = false
    private var clients: [Connection] = []
    private var records: [String: (record: Record, version: Int64, seq: Int64)] = [:]
    private var cursor: Int64 = 0
    private var errors: [String] = []
    private var magentaPage = false
    private final class Connection {
        let wire: NWConnection
        var buffer = Data(), fragment = Data()
        var upgraded = false, hello = false
        init(_ wire: NWConnection) { self.wire = wire }
    }
    var ready: Bool { queue.sync { started } }
    var phoneRegistered: Bool { queue.sync { registered } }
    var base: URL { queue.sync { URL(string: "http://127.0.0.1:\(port)")! } }
    var failures: [String] { queue.sync { errors } }
    var sends: [Record] { queue.sync { records.values.map(\.record).filter { $0.collection == "send" } } }

    init(chat: String) throws {
        self.chat = chat; mac = try Journal(path: nil, device: "owned-mac")
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] wire in
            guard let self else { wire.cancel(); return }
            let client = Connection(wire); self.clients.append(client)
            wire.start(queue: self.queue); self.receive(client)
        }
    }
    func start(_ ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state { self.port = self.listener.port!.rawValue; self.started = true; ready() }
            else if case .failed = state { self.errors.append("listener failed") }
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.sync {
            listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
            clients.forEach { $0.wire.cancel() }; clients = []
        }
    }
    /// Owned render fixtures through the real encrypted sync wire, no executor.
    func transcript(_ text: String, title: String = "Owned readable chat") throws {
        try queue.sync { try publish(mac.change(.init(collection: "chat", id: chat),
            ["device": "owned-mac", "kind": "agent", "title": .string(title), "cli": "codex", "state": "done",
             "answer": .string(text), "updated": .number(Date().timeIntervalSince1970)])) }
    }
    /// Terminal task notices through the same checked, encrypted production path.
    /// The request is authored by this disposable phone, the observation by its Mac.
    func taskNotice(_ status: TaskRecords.Status, title: String, progress: String = "") throws {
        try queue.sync {
            let space = SyncCollection.firstSpace
            try publish(mac.change(.init(collection: OpenOnMac.capability, id: "owned-mac"),
                                   ["device": "owned-mac", "taskRecords": 1]))
            try publish(mac.change(.init(collection: SyncCollection.space, id: space),
                                   SyncSpace(id: space, name: "Owned public", icon: "").fields))
            let phone = try Journal(path: nil, device: "owned-phone")
            let request = try TaskRecords.Request(account: seal.account, phone: "owned-phone", mac: "owned-mac",
                                                  space: space, words: "Read the public page",
                                                  readOnlyEpoch: "00000000-0000-0000-0000-000000000081")
            try publish(phone.change(.init(collection: TaskRecords.requestCollection, id: request.id), request.fields()))
            let observation = try TaskRecords.Observation(request: request, revision: 1, session: "owned-notice-session", status: status,
                                                          title: title, progress: progress,
                                                          result: status == .done ? "Owned retained result" : nil)
            try publish(mac.change(.init(collection: TaskRecords.observationCollection, id: request.id), observation.fields()))
        }
    }

    func useMagentaPage() { queue.sync { magentaPage = true } }
    private func publish(_ record: Record) throws {
        let name = seal.name(record.key), version = (records[name]?.version ?? 0) + 1
        cursor += 1; records[name] = (record, version, cursor)
        let item = try encoded(name, record: record, version: version, seq: cursor)
        for client in clients where client.upgraded && client.hello { send(["t": "changes", "items": [item], "cursor": cursor, "more": false], to: client) }
    }
    private func encoded(_ name: String, record: Record, version: Int64, seq: Int64) throws -> [String: Any] {
        ["name": name, "blob": try seal.seal(record).base64EncodedString(), "version": version, "seq": seq]
    }
    private func receive(_ client: Connection) {
        client.wire.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, done, error in
            guard let self, let client else { return }
            if let data { client.buffer.append(data) }
            guard error == nil, client.buffer.count <= 524_288 else { client.wire.cancel(); return }
            if client.upgraded { self.frames(client) } else { self.http(client) }
            if !done { self.receive(client) }
        }
    }
    private func http(_ client: Connection) {
        guard let end = client.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if client.buffer.count > 32_768 { errors.append("HTTP headers exceeded bound"); client.wire.cancel() }; return
        }
        guard let text = String(data: client.buffer[..<end.lowerBound], encoding: .utf8) else { client.wire.cancel(); return }
        let lines = text.components(separatedBy: "\r\n"), request = lines[0].components(separatedBy: " ")
        guard request.count >= 2 else { client.wire.cancel(); return }
        let method = request[0], path = request[1]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        let size = headers["content-length"].flatMap(Int.init) ?? 0
        guard size >= 0, size <= 65_536 else { client.wire.cancel(); return }
        guard client.buffer.count >= end.upperBound + size else { return }
        let body = client.buffer.subdata(in: end.upperBound..<(end.upperBound + size))
        client.buffer = Data(client.buffer.dropFirst(end.upperBound + size))
        if path == "/v1/accounts/\(seal.account)/socket", headers["upgrade"]?.lowercased() == "websocket",
           headers["authorization"] == "Bearer owned-phone-token", let key = headers["sec-websocket-key"] {
            let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = Data(digest).base64EncodedString()
            write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8), to: client)
            client.upgraded = true; frames(client)
        } else if path == "/v1/accounts/\(seal.account)/devices", method == "POST",
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any], json["secret"] as? String == seal.secret,
                  let device = json["device"] as? [String: Any], device["id"] as? String == "owned-phone" {
            registered = true; reply(["token": "owned-phone-token"], to: client)
        } else if path == "/v1/accounts/\(seal.account)/devices", method == "GET", headers["authorization"] == "Bearer owned-phone-token" {
            var devices: [[String: Any]] = [["id": "owned-mac", "name": "Owned Mac", "model": "Mac16,1", "revoked": false,
                                               "lastSeen": Date().timeIntervalSince1970 * 1000]]
            if registered { devices.append(["id": "owned-phone", "name": "Owned iPhone", "model": "iPhone", "revoked": false]) }
            reply(["devices": devices], to: client)
        } else if path == "/owned-page" {
            let tint = magentaPage ? "<style>html,body{background:#ff00ff;min-height:100vh}</style>" : ""
            let action = magentaPage ? "<button onclick=\"this.textContent='Owned page touch worked'\">Owned page action</button>" : ""
            response(Data(("<!doctype html><meta name=viewport content=width=device-width><title>Owned page</title>" + tint + "<h1>Owned page</h1>" + action).utf8), type: "text/html", to: client)
        } else { response(Data(), type: "application/json", status: 404, to: client) }
    }
    private func reply(_ json: [String: Any], to client: Connection) { response((try? JSONSerialization.data(withJSONObject: json)) ?? Data(), type: "application/json", to: client) }
    private func response(_ body: Data, type: String, status: Int = 200, to client: Connection) {
        let header = Data("HTTP/1.1 \(status) OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        client.wire.send(content: header + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in client.wire.cancel() })
    }
    private func frames(_ client: Connection) {
        while client.buffer.count >= 2 {
            let bytes = [UInt8](client.buffer), opcode = bytes[0] & 15, final = bytes[0] & 128 != 0
            guard bytes[0] & 112 == 0, bytes[1] & 128 != 0 else { errors.append("invalid masked frame"); client.wire.cancel(); return }
            var length = UInt64(bytes[1] & 127), offset = 2
            if length == 126 { guard bytes.count >= 4 else { return }; length = UInt64(bytes[2]) << 8 | UInt64(bytes[3]); offset = 4 }
            else if length == 127 { guard bytes.count >= 10 else { return }; length = bytes[2..<10].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; offset = 10 }
            guard length <= 524_288 else { errors.append("frame exceeded bound"); client.wire.cancel(); return }
            guard bytes.count >= offset + 4 + Int(length) else { return }
            let mask = Array(bytes[offset..<(offset + 4)]); offset += 4
            let payload = Data(bytes[offset..<(offset + Int(length))].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            client.buffer = Data(client.buffer.dropFirst(offset + Int(length)))
            if opcode == 8 { client.wire.cancel(); return }
            if opcode == 9 { frame(payload, opcode: 10, to: client); continue }
            guard opcode == 1 || opcode == 0, client.fragment.count + payload.count <= 524_288 else { errors.append("unsupported data frame"); client.wire.cancel(); return }
            client.fragment.append(payload)
            if final { message(client.fragment, from: client); client.fragment = Data() }
        }
    }
    private func message(_ payload: Data, from client: Connection) {
        guard let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any], let kind = message["t"] as? String else { errors.append("invalid JSON frame"); return }
        if kind == "hello" {
            client.hello = true
            let after = (message["cursor"] as? NSNumber)?.int64Value ?? 0
            let items = records.sorted { $0.value.seq < $1.value.seq }.filter { $0.value.seq > after }
                .compactMap { try? encoded($0.key, record: $0.value.record, version: $0.value.version, seq: $0.value.seq) }
            send(["t": "changes", "items": items, "cursor": cursor, "more": false], to: client)
        } else if kind == "push" {
            var accepted: [[String: Any]] = [], conflicts: [[String: Any]] = []
            for change in message["changes"] as? [[String: Any]] ?? [] {
                guard let name = change["name"] as? String, let blob = change["blob"] as? String,
                      let data = Data(base64Encoded: blob), let record = try? seal.open(data, name: name) else { errors.append("unopenable owned envelope"); continue }
                let base = (change["base"] as? NSNumber)?.int64Value ?? 0
                if (records[name]?.version ?? 0) != base {
                    if let had = records[name], let item = try? encoded(name, record: had.record, version: had.version, seq: had.seq) { conflicts.append(item) }; continue
                }
                cursor += 1; records[name] = (record, base + 1, cursor)
                accepted.append(["name": name, "version": base + 1, "seq": cursor])
            }
            send(["t": "pushed", "id": message["id"] ?? "", "accepted": accepted, "conflicts": conflicts], to: client)
        }
    }
    private func send(_ json: [String: Any], to client: Connection) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { errors.append("unencodable JSON"); return }
        frame(data, opcode: 1, to: client)
    }
    private func frame(_ body: Data, opcode: UInt8, to client: Connection) {
        var header = Data([128 | opcode])
        if body.count < 126 { header.append(UInt8(body.count)) }
        else if body.count <= 65_535 { header.append(126); header.append(UInt8(body.count >> 8)); header.append(UInt8(body.count & 255)) }
        else { header.append(127); for shift in stride(from: 56, through: 0, by: -8) { header.append(UInt8((UInt64(body.count) >> shift) & 255)) } }
        write(header + body, to: client)
    }
    private func write(_ data: Data, to client: Connection) { client.wire.send(content: data, completion: .contentProcessed { error in if error != nil { client.wire.cancel() } }) }
}
