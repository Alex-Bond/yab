import Foundation
import Security
import XCTest
@testable import Fast

// Who may use the bench's socket in a shipped Yab: only Yab's own code,
// by the caller's code signature, which the kernel names (BenchCaller).
// The caller here is this test process, on a real Unix socket, accepted as
// Bench accepts; "Yab's own code" is whatever signature this process has.

@MainActor
final class BenchCallerTests: XCTestCase {
    // MARK: - no signature to show

    func testACallerTheKernelCantNameIsRefused() throws {
        var ends: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&ends), 0)
        defer { ends.forEach { close($0) } }
        // A pipe has no peer: no audit token, so nothing to trust.
        XCTAssertNil(BenchCaller.token(ends[0]))
        XCTAssertFalse(BenchCaller.yab(ends[0]))
    }

    func testACallerThatIsntYabGetsNoneOfThePersonsData() {
        let mail = ["agent-mail-read", "agent-mail-search", "agent-mail-file", "agent-mail-recall", "agent-mail-draft",
                    "agent-mail-act", "agent-mail-send", "agent-mail-triage", "agent-mail-list", "agent-mail-labels",
                    "agent-mail-accounts", "agent-mail-code", "agent-mail-snippets"]
        let rest = ["agent-attach", "agent-caps", "agents", "agent-run", "agent-memory-read", "agent-memory-search",
                    "agent-routines", "agent-reply", "snapshot", "text", "shot", "open", "act", "nav", "agent-tabs", "app-quit"]
        for verb in mail + rest {
            XCTAssertFalse(Bench.allowed(verb, session: true, yab: false, open: false), verb)
            XCTAssertFalse(Bench.allowed(verb, session: false, yab: false, open: false), verb)
        }
        // Only whether Yab is running.
        XCTAssertTrue(Bench.allowed("app-status", session: false, yab: false, open: false))
        // Yab's own code with a session works on mail as before.
        for verb in mail { XCTAssertTrue(Bench.allowed(verb, session: true, yab: true, open: false), verb) }
    }

    // MARK: - another program's signature

    func testCodeSignedAsAnotherProgramIsRefused() throws {
        let (caller, accepted) = try Self.connected()
        defer { close(caller); close(accepted) }
        let token = try XCTUnwrap(BenchCaller.token(accepted))
        var other: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(
            "identifier \"com.example.not-yab\" and anchor apple generic" as CFString, [], &other), errSecSuccess)
        XCTAssertFalse(BenchCaller.satisfies(token, try XCTUnwrap(other)))
        // Nor is a token that names no process at all.
        XCTAssertFalse(BenchCaller.satisfies(Data(count: token.count), try XCTUnwrap(BenchCaller.own)))
    }

    // MARK: - Yab's own

    func testYabsOwnCodeIsAnswered() throws {
        let own = try XCTUnwrap(BenchCaller.own, "this process has no signature to require")
        let (caller, accepted) = try Self.connected()
        defer { close(caller); close(accepted) }
        let token = try XCTUnwrap(BenchCaller.token(accepted))
        XCTAssertTrue(BenchCaller.satisfies(token, own))
        // And the same answer through the cache, for the next call.
        XCTAssertTrue(BenchCaller.yab(accepted))
        XCTAssertTrue(BenchCaller.yab(accepted))
    }

    func testTheCheckIsQuickEnoughForEveryConnection() throws {
        let own = try XCTUnwrap(BenchCaller.own)
        let (caller, accepted) = try Self.connected()
        defer { close(caller); close(accepted) }
        let token = try XCTUnwrap(BenchCaller.token(accepted))
        let start = Date()
        for _ in 0..<20 { XCTAssertTrue(BenchCaller.satisfies(token, own)) }
        let each = Date().timeIntervalSince(start) / 20
        XCTAssertLessThan(each, 0.05, "\(Int(each * 1000)) ms a check")
    }

    // MARK: - a socket as Bench has one

    /// Both ends of one connection, the second as Bench's accept gets it.
    private static func connected() throws -> (Int32, Int32) {
        // sun_path holds 104 bytes: a short folder, not the test's temporary one.
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("bc-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var address = Self.address(folder.appendingPathComponent("s").path)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) }
        }
        guard bound == 0, Darwin.listen(listener, 4) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { close(fd); throw POSIXError(.ECONNABORTED) }
        return (fd, accepted)
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        return address
    }
}
