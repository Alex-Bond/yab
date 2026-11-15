import SyncKit
import XCTest
@testable import YabPhone

/// Join Your Mac › Scan QR: only a Mac's code is taken, and joining by it
/// waits for the Mac's yes on the digits both screens show.
@MainActor
final class ScanJoinTests: PhoneLinkTestCase {
    // MARK: - Scan QR

    func testScanQRTakesOnlyAMacsCode() throws {
        let app = try miraApp()
        app.sync.pretend(.joining(.code("ABCD-EFGH")))
        app.sync.showScanner(true)
        XCTAssertEqual(app.sync.phase, .joining(.scan))
        XCTAssertFalse(app.sync.joinWithInvite("https://example.com/join/K7QM-4XTD"))
        XCTAssertNotNil(app.sync.joinError)
        XCTAssertEqual(app.sync.phase, .joining(.scan))
        XCTAssertTrue(app.sync.joinWithInvite("yab://join/K7QM-4XTD"))
        guard case .joining(.invite(let code, _)) = app.sync.phase else { return XCTFail("\(app.sync.phase)") }
        XCTAssertEqual(code, "K7QM-4XTD")
        XCTAssertTrue(app.sync.openJoinLink(URL(string: "yab://join/K7QM-4XTD")!))
        XCTAssertFalse(app.sync.openJoinLink(URL(string: "yab://task/1/open")!))
    }

    /// The right button's Scan QR Code reading a Mac's Add a Device code joins,
    /// as Join Your Mac's own Scan QR does, instead of putting it in the field.
    func testTheFieldsCodeScannerHandsAMacsCodeToJoining() throws {
        let app = try miraApp()
        app.sync.pretend(.joining(.code("ABCD-EFGH")), sheet: false)
        app.scanner.useStandIn("yab://join/K7QM-4XTD", waits: true)
        app.surfaces.openField(.newTab)
        app.scanner.open()
        app.scanner.found("yab://join/K7QM-4XTD")
        XCTAssertFalse(app.scanner.shown)
        app.scanner.closed()
        guard case .joining(.invite(let code, _)) = app.sync.phase else { return XCTFail("\(app.sync.phase)") }
        XCTAssertEqual(code, "K7QM-4XTD")
        XCTAssertEqual(CodeScanner.route("yab://join/K7QM-4XTD"), .words("yab://join/K7QM-4XTD"), "the route itself is unchanged")
    }

    func testJoiningByTheMacsCodeWaitsForTheDigitsAndThenItIsIn() async throws {
        let memory = SyncMemoryServer(), seal = Seal.make()
        let server = PairingServer(memory)
        let mac = try await mac(memory, seal)
        defer { mac.client.stop() }
        // The Mac shows its code (Add a Device).
        let host = JoinInviteHost(base: URL(string: "https://sync.test")!, transport: server, every: 0.05)
        let arrived = Arrived()
        host.start { event in arrived.set(event) }
        // An iPhone with no key, showing its own code.
        let app = AppModel(world: World(name: "test", space: "home", spaces: [Space(id: "home", name: "Home", emoji: "🏠", tint: RGB(238, 233, 226))]))
        app.sync.attach(app, setup: setup(server))
        let asking = await until { if case .joining(.code) = app.sync.phase { return true }; return false }
        XCTAssertTrue(asking)
        // Scan QR reads the Mac's code.
        XCTAssertTrue(app.sync.joinWithInvite(host.link))
        guard case .joining(.invite(_, let check)) = app.sync.phase else { return XCTFail("\(app.sync.phase)") }
        let heard = await until { arrived.event == .arrived(check: check) }
        XCTAssertTrue(heard, "the Mac shows the same digits: \(String(describing: arrived.event)) vs \(check)")
        XCTAssertNotEqual(app.sync.phase, .on, "nothing until the Mac's yes")
        host.letIn(seal)
        let joined = await until(8) { app.sync.phase == .on && app.sync.line == .live }
        XCTAssertTrue(joined, "\(app.sync.phase) \(app.sync.line)")
        XCTAssertEqual(SyncKeychain.testing(folder: folder.appendingPathComponent("keys")).local?.raw, seal.raw)
        app.sync.end()
    }
}

/// What the Mac's invite heard last, read from the test.
private final class Arrived: @unchecked Sendable {
    private let lock = NSLock()
    private var last: JoinInviteHost.Event?
    func set(_ event: JoinInviteHost.Event) { lock.lock(); last = event; lock.unlock() }
    var event: JoinInviteHost.Event? { lock.lock(); defer { lock.unlock() }; return last }
}

/// The memory server with the pairing box beside it, as sync-server has.
final class PairingServer: Transport, @unchecked Sendable {
    let memory: SyncMemoryServer
    private let lock = NSLock()
    private var boxes: [String: (pub: String, envelope: String?)] = [:]

    init(_ memory: SyncMemoryServer) { self.memory = memory }

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        let path = request.url?.path ?? ""
        guard path == "/v1/pair" || path.hasPrefix("/v1/pair/") else { return memory.request(request, done) }
        lock.lock()
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var status = 404
        var body: [String: Any] = [:]
        if path == "/v1/pair", request.httpMethod == "POST", let code = json?["code"] as? String, let pub = json?["pub"] as? String {
            if boxes[code] != nil { status = 409 } else { boxes[code] = (pub, nil); status = 204 }
        } else {
            let code = String(path.dropFirst("/v1/pair/".count))
            if let box = boxes[code] {
                if request.httpMethod == "PUT", let envelope = json?["envelope"] as? String {
                    if box.envelope != nil { status = 409 } else { boxes[code]?.envelope = envelope; status = 204 }
                } else {
                    status = 200
                    body = ["pub": box.pub]
                    if let envelope = box.envelope { body["envelope"] = envelope }
                }
            }
        }
        lock.unlock()
        DispatchQueue.global().async { done(status, try? JSONSerialization.data(withJSONObject: body)) }
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
        memory.open(request, received: received, closed: closed)
    }
}
