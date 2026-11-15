import Foundation
import Testing
@testable import Fast

/// A local http address nobody takes gets one look at https (feedback #82).
struct LocalHTTPSTests {
    @Test func onlyALocalHttpAddressThatWasRefusedIsLookedAtOverHttps() {
        func look(_ address: String, _ code: Int = NSURLErrorCannotConnectToHost) -> String? {
            LocalHTTPS.candidate(for: URL(string: address)!, code: code)?.absoluteString
        }
        // A phone's or router's page, typed as 192.168.1.20.
        #expect(look("http://192.168.1.20/") == "https://192.168.1.20/")
        #expect(look("http://10.0.0.5/admin?tab=1") == "https://10.0.0.5/admin?tab=1")
        #expect(look("http://printer.local/") == "https://printer.local/")
        #expect(look("http://nas:5000/") == "https://nas:5000/")
        #expect(look("http://[fe80::1]/") == "https://[fe80::1]/")
        // A port that speaks TLS hangs up on plain http, or answers in TLS.
        #expect(look("http://192.168.1.20:8443/", NSURLErrorNetworkConnectionLost) == "https://192.168.1.20:8443/")
        #expect(look("http://192.168.1.20:8443/", NSURLErrorCannotParseResponse) == "https://192.168.1.20:8443/")
        // :80 is http's port; https is looked for on its own.
        #expect(look("http://192.168.1.20:80/") == "https://192.168.1.20/")

        // Already https, a public site, or a failure that says nothing of https.
        #expect(look("https://192.168.1.20/") == nil)
        #expect(look("http://example.com/") == nil)
        #expect(look("http://8.8.8.8/") == nil)
        #expect(look("http://192.168.1.20/", NSURLErrorTimedOut) == nil)
        #expect(look("http://printer.local/", NSURLErrorCannotFindHost) == nil)
        #expect(look("http://192.168.1.20/", NSURLErrorNotConnectedToInternet) == nil)
    }

    /// A device's self-signed certificate is an answer; a closed port and a
    /// plain http server are not.
    @Test func theLookIsAnsweredByTLSAloneTrustedOrNot() async throws {
        let device = try TLSDevice()
        defer { device.stop() }
        #expect(await LocalHTTPS.answers(URL(string: "https://127.0.0.1:\(device.port)/")!))

        let plain = try LocalNetworkFixture()
        defer { plain.stop() }
        plain.route("/", .init("plain http"))
        #expect(!(await LocalHTTPS.answers(URL(string: "https://127.0.0.1:\(plain.port)/")!)))

        let closed = try LocalNetworkFixture()
        let port = closed.port
        closed.stop()
        let started = Date()
        #expect(!(await LocalHTTPS.answers(URL(string: "https://127.0.0.1:\(port)/")!)))
        #expect(Date().timeIntervalSince(started) < 3.5)
    }
}

/// A device's own https page on 127.0.0.1: a self-signed certificate and a
/// TLS handshake, nothing more.
private final class TLSDevice {
    let port: Int
    private let server = Process()
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-https-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = folder.appendingPathComponent("key.pem").path, cert = folder.appendingPathComponent("cert.pem").path
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        make.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                          "-subj", "/CN=phone.local", "-days", "1"]
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        try make.run()
        make.waitUntilExit()
        guard make.terminationStatus == 0 else { throw URLError(.cannotLoadFromNetwork) }

        let script = """
        import socket, ssl, sys
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1], sys.argv[2])
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        print(listener.getsockname()[1], flush=True)
        while True:
            connection, _ = listener.accept()
            try:
                context.wrap_socket(connection, server_side=True).close()
            except Exception:
                connection.close()
        """
        let said = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "-c", script, cert, key]
        server.standardOutput = said
        server.standardError = FileHandle.nullDevice
        try server.run()
        let line = String(decoding: said.fileHandleForReading.availableData, as: UTF8.self)
        guard let port = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            server.terminate()
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func stop() {
        if server.isRunning { server.terminate() }
        try? FileManager.default.removeItem(at: folder)
    }
}
