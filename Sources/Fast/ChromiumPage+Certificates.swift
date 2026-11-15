import AppKit
import Security
import YabCoreClient

extension ChromiumPage {
    func receiveCertificate(_ p: [String: JSONValue], finish: @escaping @MainActor ([String: JSONValue]) -> Void) {
        guard let url = p["origin"]?.string.flatMap(URL.init(string:)), url.scheme == "https",
              let host = url.host, case .array(let encoded) = p["chain"], !encoded.isEmpty, encoded.count <= 16 else {
            finish(["allow": .bool(false)]); return
        }
        let chain = encoded.compactMap { $0.string.flatMap { Data(base64Encoded: $0) } }
        guard chain.count == encoded.count,
              chain.allSatisfy({ !$0.isEmpty && $0.count <= 65536 && SecCertificateCreateWithData(nil, $0 as CFData) != nil }) else {
            finish(["allow": .bool(false)]); return
        }
        let exception = CertificateException(host: host, port: url.port ?? 443, chain: chain, at: Date())
        if CertificateExceptions.contains(exception, in: self) { finish(["allow": .bool(true)]); return }
        // Refuse first. The existing Continue button records the exact chain
        // for this profile and starts a new navigation, as the WebKit path does.
        finish(["allow": .bool(false)])
        guard p["mainFrame"] == .bool(true) else { return }
        let why: String
        switch p["code"]?.number {
        case -201: why = "Its certificate has run out"
        case -200: why = "Its certificate is for another site"
        default: why = "This Mac doesn’t trust whoever signed its certificate"
        }
        let subject = p["subject"]?.string ?? "", issuer = p["issuer"]?.string ?? ""
        let names = subject.isEmpty ? "" : subject == issuer ? "Issued to \(subject), by itself." : "Issued to \(subject), by \(issuer)."
        events?.page(self, rejected: PageCertificate(host: CertificateException.hostName(host), port: url.port ?? 443,
                                                   exception: exception, why: why, names: names, failingURL: url))
    }
}
