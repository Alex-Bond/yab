import Foundation
import Security

/// A self-signed HTTPS page on an ephemeral loopback port. No user
/// certificates, keychain items or trust settings are changed.
final class TLSSiteFixture {
    let port: Int
    let trust: SecTrust
    private let server = Process()
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tls-site-\(UUID().uuidString)")

    init(port: Int = 0) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let key = folder.appendingPathComponent("key.pem").path
        let cert = folder.appendingPathComponent("cert.pem").path
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        make.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                          "-subj", "/CN=localhost", "-days", "1"]
        make.standardOutput = FileHandle.nullDevice
        make.standardError = FileHandle.nullDevice
        try make.run(); make.waitUntilExit()
        guard make.terminationStatus == 0 else { throw URLError(.cannotLoadFromNetwork) }
        let pem = try String(contentsOfFile: cert, encoding: .utf8)
        let encoded = pem.components(separatedBy: .newlines).filter { !$0.hasPrefix("---") }.joined()
        guard let data = Data(base64Encoded: encoded), let leaf = SecCertificateCreateWithData(nil, data as CFData) else { throw URLError(.cannotDecodeContentData) }
        var made: SecTrust?
        guard SecTrustCreateWithCertificates(leaf, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &made) == errSecSuccess,
              let made else { throw URLError(.cannotDecodeContentData) }
        trust = made
        _ = SecTrustEvaluateWithError(trust, nil)
        let script = """
        import http.server, ssl, sys
        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version='HTTP/1.1'
            def do_GET(self):
                body=b'<title>TLS fixture</title>fixture'
                self.send_response(200)
                self.send_header('Content-Length',str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self,*args): pass
        listener=http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[3])),Handler)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1],sys.argv[2])
        listener.socket=context.wrap_socket(listener.socket,server_side=True)
        print(listener.server_port,flush=True)
        listener.serve_forever()
        """
        let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "-c", script, cert, key, String(port)]
        server.standardOutput = output
        server.standardError = FileHandle.nullDevice
        try server.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let found = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw URLError(.cannotConnectToHost) }
        self.port = found
    }

    func stop() {
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        try? FileManager.default.removeItem(at: folder)
    }
    deinit { stop() }
}
