import AppKit
import Security
import YabCoreClient

/// Device mode and the connection's facts, kept here for the same questions
/// WebKit's view answers by itself.
extension ChromiumPage {
    /// The page's certificate, read when it finishes loading: Site Controls
    /// asks a plain property, and a Chromium page answers over a socket.
    func readCertificate() {
        guard url?.scheme?.lowercased() == "https" else { serverTrust = nil; return }
        Task { @MainActor [weak self] in
            guard let self, let value = try? await self.navigationRequest("page.certificate"),
                  case .array(let chain) = value["chain"] else { return }
            let certificates = chain.compactMap { $0.string.flatMap { Data(base64Encoded: $0) } }
                .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
            guard !certificates.isEmpty else { return }
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, self.url?.host() as CFString?), &trust) == errSecSuccess else { return }
            self.serverTrust = trust
        }
    }

    /// Chrome's own setting, for the space's whole profile, as Yab's is the
    /// same for every page.
    func minimumFont(_ size: Int) {
        guard size != minimumFontAsked else { return }
        minimumFontAsked = size
        command("page.minimumFont", ["size": .number(Double(size))])
    }

    /// The profile's generic families (PageFamilies), Chrome's own font
    /// settings, sent when they change.
    func pageFamilies(_ names: PageFamilies.Names) {
        guard names != familiesAsked else { return }
        familiesAsked = names
        command("page.fonts", ["standard": .string(names.standard), "serif": .string(names.serif),
                               "sans": .string(names.sans), "fixed": .string(names.fixed),
                               "fixedSize": names.fixedSize.map { JSONValue.number(Double($0)) } ?? JSONValue.null])
    }

    /// As `device`, or as itself with nil. Asked at every layout: only a
    /// change reaches the helper.
    func emulate(_ device: DeviceMode?, scale: CGFloat) {
        let wanted = device.map { [Double($0.width), Double($0.height), Double(scale)] }
        guard wanted != emulated || device?.userAgent != emulatedAgent else { return }
        emulated = wanted
        emulatedAgent = device?.userAgent
        let mobile = device?.userAgent?.contains("Mobile") == true
        command("page.emulate", ["width": .number(Double(device?.width ?? 0)), "height": .number(Double(device?.height ?? 0)),
                              "scale": .number(Double(scale)), "mobile": .bool(mobile), "userAgent": .string(device?.userAgent ?? "")])
    }
}
