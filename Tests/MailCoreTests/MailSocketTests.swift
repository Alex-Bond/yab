import Darwin
import Foundation
import Testing
@testable import MailCore

// Crash #107 (row 1140): a stream task's read that timed out before its
// line was set up was answered a second time by CFNetwork once the task
// was cancelled, so MailSocket's read woke twice (or CFNetwork reached a
// freed object). Hundreds of lines to a server that takes the connection
// and never finishes TLS, each read timing out and the line closed at
// once, or closed as the read gives up, while the server drops lines
// under them.

/// A listener on this Mac that takes connections and says nothing, or
/// greets once and then stays quiet; each line dropped after a while.
final class QuietServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init(greeting: String? = nil, drop: ClosedRange<Double>? = 0.05...0.6) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 512)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = Int(UInt16(bigEndian: addr.sin_port))
        self.fd = fd
        Thread.detachNewThread {
            while true {
                let line = accept(fd, nil, nil)
                if line < 0 { if errno == EINTR { continue } else { return } }
                if let greeting { _ = greeting.withCString { send(line, $0, strlen($0), 0) } }
                guard let drop else { continue }
                DispatchQueue.global().asyncAfter(deadline: .now() + Double.random(in: drop)) {
                    if Bool.random() {
                        var hard = linger(l_onoff: 1, l_linger: 0)
                        setsockopt(line, SOL_SOCKET, SO_LINGER, &hard, socklen_t(MemoryLayout<linger>.size))
                    }
                    Darwin.close(line)
                }
            }
        }
    }

    func stop() { Darwin.close(fd) }
}

@Suite("Mail socket")
struct MailSocketTests {
    @Test("Reads timed out before TLS, lines closed at once: no second answer")
    func timedOutBeforeSetup() async throws {
        let server = QuietServer()
        defer { server.stop() }
        var timedOut = 0
        for _ in 0..<8 {
            timedOut += await withTaskGroup(of: Int.self) { group in
                for _ in 0..<50 {
                    group.addTask {
                        guard let socket = try? MailSocket(host: "127.0.0.1", port: server.port, security: .tls) else { return 0 }
                        let wait = Double.random(in: 0.01...0.1)
                        await socket.set(timeout: wait)
                        // Closed about when the read gives up, as the account's
                        // close meets an IDLE read or a sign-in's wait.
                        let closing = Task {
                            try? await Task.sleep(nanoseconds: UInt64((wait + Double.random(in: -0.005...0.005)) * 1e9))
                            await socket.close()
                        }
                        var out = 0
                        do { _ = try await socket.line() } catch MailServerTrouble.timedOut { out = 1 } catch {}
                        await closing.value
                        await socket.close()
                        return out
                    }
                }
                return await group.reduce(0, +)
            }
        }
        // Late answers from lines the server drops after the reads gave up.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(timedOut > 0)
    }

    @Test("A wait that passes before the line is set up ends it")
    func deadlineEndsUnsettledLine() async throws {
        let server = QuietServer(drop: nil)
        defer { server.stop() }
        let socket = try MailSocket(host: "127.0.0.1", port: server.port, security: .tls)
        await socket.set(timeout: 0.1)
        await #expect(throws: MailServerTrouble.timedOut("read")) { _ = try await socket.line() }
        #expect(await socket.isOpen == false)
    }

    @Test("A wait that passes on a line already talking is still the server's silence")
    func timeoutKeepsSettledLine() async throws {
        let server = QuietServer(greeting: "* OK ready\r\n", drop: nil)
        defer { server.stop() }
        let socket = try MailSocket(host: "127.0.0.1", port: server.port, security: .none)
        let greeting = try await socket.line()
        #expect(String(decoding: greeting, as: UTF8.self) == "* OK ready")
        await #expect(throws: MailServerTrouble.timedOut("read")) { _ = try await socket.line(timeout: 0.1) }
        await socket.close()
    }
}
