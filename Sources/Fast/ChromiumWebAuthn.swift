import AppKit
import YabCoreClient

// Passkeys and security keys on Chromium pages, one path.
//
// Chromium's own WebAuthn runs unchanged: a page's navigator.credentials
// is Chromium's (or a password manager's, which takes it over as it does in
// Chromium), and Chromium checks the request, the RP ID against the origin,
// related origins, another site's frame and its publickey-credentials
// permission, an extension's host permissions. Only then CEF patch 0113 hands
// it to YabCore instead of showing Chromium's authenticator dialog, which
// would stand in a window nobody sees (#1843), and YabCore to here
// (webauthn.request). Yab answers with its own ceremony, the Mac's sheet
// (Passkeys.perform), with the origin Chromium verified, never a page
// script's word. The answer goes back as WebAuthn JSON for Chromium to turn
// into the page's credential.
@MainActor
enum ChromiumWebAuthn {
    private struct Pending { let client: YabCoreClient; let token: String }
    private static var pending: [String: Pending] = [:]

    /// The last requests as they arrived, for the bench and evals.
    private(set) static var heard: [[String: String]] = []

    static func receive(_ event: YabCoreEvent, from client: YabCoreClient?) -> Bool {
        switch event.name {
        case "webauthn.cancel":
            if let request = event.params["request"]?.string, let old = pending.removeValue(forKey: request) {
                Passkeys.shared.cancel(token: old.token)
            }
            // A conditional get the page aborted, or whose document went
            // (CEF 0127): its rows go, and a sheet a pick opened for it.
            if let request = event.params["request"]?.string, let old = conditional.removeValue(forKey: request) {
                if old.picking { Passkeys.shared.cancel(token: old.token) }
                Passkeys.note("chromium conditional \(request) ended by the page")
                refresh(old)
            }
            return true
        case "webauthn.request":
            guard let client, let request = event.params["request"]?.string else { return true }
            handle(event.params, request: request, client: client)
            return true
        default:
            return false
        }
    }

    private static func handle(_ p: [String: JSONValue], request: String, client: YabCoreClient) {
        let kind = p["kind"]?.string ?? ""
        let origin = p["origin"]?.string ?? ""
        heard.append(["kind": kind, "origin": origin, "topOrigin": p["topOrigin"]?.string ?? "",
                      "sameOriginWithAncestors": p["sameOriginWithAncestors"] == .bool(false) ? "false" : "true",
                      "viewType": p["viewType"]?.string ?? "", "popup": p["popup"]?.string == nil ? "false" : "true",
                      "mediation": p["mediation"]?.string ?? ""])
        if heard.count > 40 { heard.removeFirst(heard.count - 40) }
        Passkeys.note("chromium asked \(kind)\(p["mediation"]?.string.map { " " + $0 } ?? "") by \(origin) top=\(p["topOrigin"]?.string ?? "") view=\(p["viewType"]?.string ?? "")")

        // Whether this Mac can answer at all: as Chromium says when it can.
        // passkeysOffered is on only with the entitlement, or in a test run
        // that rehearses (Browser.swift), which answers create and get too:
        // a wallet asks this first and hides its Touch ID unlock on a no
        // (Rabby's and OKX's unlock pages).
        if kind == "isUvpaa" {
            return respond(client, request, response: FormRelay.passkeysOffered ? "true" : "false")
        }
        // isConditionalMediationAvailable() (CEF 0127): Chrome on the Mac
        // says true, its autofill listing iCloud Keychain's passkeys. Yab
        // lists them in its own rows under the box, when it can serve them.
        if kind == "isConditional" {
            return respond(client, request, response: servesConditional ? "true" : "false")
        }
        let page = (p["tab"]?.string).flatMap { remote in ChromiumProcess.shared.livePages.first { $0.remoteID == remote } }
        // A conditional get (CEF 0127): no sheet. Kept, with no timeout,
        // until the person picks one of the site's passkeys in the rows
        // under a box marked autocomplete="… webauthn", or the page aborts
        // or goes; as Chromium's autofill keeps it (WebAuthnConditionalRequest).
        if kind == "get", p["mediation"]?.string == "conditional" {
            return keepConditional(p, request: request, client: client, page: page)
        }
        // A page that wanted a passkey where this build can't give one.
        if !PasskeyHint.possible, let tab = page?.navigationTab {
            tab.onPasskeysMissing?(tab, .request)
        }
        guard let options = (p["options"]?.string).flatMap({ $0.data(using: .utf8) })
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let body = body(kind: kind, options: options, token: "chromium-\(request)"),
              let url = URL(string: origin), let scheme = url.scheme, let host = url.host()
        else {
            return respond(client, request, error: "NotAllowedError", message: "The operation either timed out or was not allowed.")
        }

        // An extension's action popup is the key window while it is up, and
        // closes as the Mac's sheet takes the focus: held open until the
        // answer comes, and the sheet over it.
        let popupToken = p["popup"]?.string
        var window = page?.window
        if popupToken != nil {
            window = [ChromiumPopupHost.shared.popoverWindow, page?.window].compactMap { $0 }.first { $0.isKeyWindow }
                ?? ChromiumPopupHost.shared.popoverWindow ?? page?.window
        }
        let release = popupToken.flatMap { ChromiumPopupHost.shared.holdForPasskey($0) }
        let caller = Passkeys.Caller(
            origin: PageOrigin(scheme: scheme, host: host, port: url.port ?? 0),
            mainFrame: p["mainFrame"] != .bool(false), pageHost: nil, window: window,
            chromium: .init(origin: origin, topOrigin: p["topOrigin"]?.string ?? origin,
                            crossOrigin: p["sameOriginWithAncestors"] == .bool(false)))
        pending[request] = Pending(client: client, token: "chromium-\(request)")
        Passkeys.shared.perform(body, from: caller) { reply in
            release?()
            guard pending.removeValue(forKey: request) != nil else { return }
            if let name = reply["error"] as? String {
                respond(client, request, error: name, message: reply["message"] as? String ?? "")
            } else if let json = response(kind: kind, reply: reply, options: options) {
                respond(client, request, response: json)
            } else {
                respond(client, request, error: "NotAllowedError", message: "The authenticator answered with something else.")
            }
        }
    }

    static func respond(_ client: YabCoreClient, _ request: String, response: String? = nil,
                                error: String? = nil, message: String? = nil) {
        guard ChromiumProcess.shared.isCurrent(client) else { return }
        Passkeys.note("chromium answered \(request): " + (error.map { "\($0) \(message ?? "")" } ?? "\(response?.count ?? 0) bytes"))
        var params: [String: JSONValue] = ["request": .string(request)]
        if let response { params["response"] = .string(response) }
        if let error { params["errorName"] = .string(error); params["errorMessage"] = .string(message ?? "") }
        Task { _ = try? await client.request("webauthn.respond", params: params) }
    }

    // MARK: - WebAuthn JSON, both ways

    /// Chromium's PublicKeyCredentialCreationOptionsJSON or
    /// PublicKeyCredentialRequestOptionsJSON as the request Passkeys.perform
    /// takes. PRF salts arrive raw; macOS hashes them as WebAuthn says.
    static func body(kind: String, options: [String: Any], token: String) -> [String: Any]? {
        guard kind == "create" || kind == "get", let challenge = options["challenge"] as? String else { return nil }
        var body: [String: Any] = ["kind": kind, "challenge": challenge, "token": token]
        let extensions = options["extensions"] as? [String: Any] ?? [:]
        func descriptors(_ value: Any?) -> [[String: Any]] {
            (value as? [[String: Any]] ?? []).compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return ["id": id, "transports": item["transports"] as? [String] ?? []]
            }
        }
        let prf = extensions["prf"] as? [String: Any]
        // Blink lists largeBlob and appid among the extensions this browser
        // takes (getClientCapabilities), as Chromium on the Mac serves them:
        // largeBlob through iCloud Keychain's passkeys, appid through a
        // security key's U2F credential. Carried to the sheet, not dropped.
        let largeBlob = extensions["largeBlob"] as? [String: Any]
        if kind == "create" {
            if let support = largeBlob?["support"] as? String { body["largeBlob"] = ["support": support] }
        } else if let largeBlob {
            if largeBlob["read"] as? Bool == true {
                body["largeBlob"] = ["read": true]
            } else if let write = largeBlob["write"] as? String {
                body["largeBlob"] = ["write": write]
            }
        }
        if kind == "get", let appid = extensions["appid"] as? String, !appid.isEmpty { body["appid"] = appid }
        if kind == "create" {
            guard let rp = options["rp"] as? [String: Any], let user = options["user"] as? [String: Any] else { return nil }
            body["rp"] = rp
            body["user"] = user
            body["algorithms"] = (options["pubKeyCredParams"] as? [[String: Any]] ?? []).compactMap { $0["alg"] as? Int }
            body["excludeCredentials"] = descriptors(options["excludeCredentials"])
            body["attestation"] = options["attestation"] as? String ?? "none"
            let selection = options["authenticatorSelection"] as? [String: Any] ?? [:]
            if let attachment = selection["authenticatorAttachment"] as? String { body["authenticatorAttachment"] = attachment }
            body["residentKey"] = selection["residentKey"] as? String
                ?? (selection["requireResidentKey"] as? Bool == true ? "required" : "discouraged")
            body["userVerification"] = selection["userVerification"] as? String ?? "preferred"
            if let prf { body["prf"] = prf["eval"].map { ["eval": $0] } ?? [String: Any]() }
        } else {
            guard let rp = options["rpId"] as? String else { return nil }
            body["rpId"] = rp
            body["allowCredentials"] = descriptors(options["allowCredentials"])
            body["userVerification"] = options["userVerification"] as? String ?? "preferred"
            if let prf {
                var input: [String: Any] = [:]
                if let eval = prf["eval"] { input["eval"] = eval }
                if let each = prf["evalByCredential"] { input["byCredential"] = each }
                body["prf"] = input
            }
        }
        return body
    }

    /// Passkeys' reply as the RegistrationResponseJSON or
    /// AuthenticationResponseJSON Chromium parses
    /// (components/webauthn/json/value_conversions.cc).
    static func response(kind: String, reply: [String: Any], options: [String: Any]) -> String? {
        guard let id = reply["id"] as? String, let client = reply["clientDataJSON"] as? String else { return nil }
        let extensions = options["extensions"] as? [String: Any] ?? [:]
        let attachment = reply["attachment"] as? String ?? "platform"
        var results: [String: Any] = [:]
        let prf = reply["prf"] as? [String: Any]
        var json: [String: Any] = ["id": id, "rawId": id, "type": "public-key", "authenticatorAttachment": attachment]
        if kind == "create" {
            guard let attestation = reply["attestationObject"] as? String,
                  let auth = reply["authenticatorData"] as? String,
                  let algorithm = reply["publicKeyAlgorithm"] as? Int
            else { return nil }
            var response: [String: Any] = ["clientDataJSON": client, "attestationObject": attestation,
                                           "authenticatorData": auth, "publicKeyAlgorithm": algorithm,
                                           "transports": reply["transports"] as? [String] ?? []]
            if let key = reply["publicKey"] as? String { response["publicKey"] = key }
            json["response"] = response
            if extensions["prf"] != nil {
                var out: [String: Any] = ["enabled": prf?["enabled"] as? Bool ?? false]
                if let first = prf?["first"] as? String {
                    var values = ["first": first]
                    if let second = prf?["second"] as? String { values["second"] = second }
                    out["results"] = values
                }
                results["prf"] = out
            }
            // A passkey is discoverable; a security key is when it was asked to be.
            if extensions["credProps"] as? Bool == true {
                let resident = ((options["authenticatorSelection"] as? [String: Any])?["residentKey"] as? String) == "required"
                results["credProps"] = ["rk": attachment == "platform" || resident]
            }
            // Whether the new credential keeps a blob: only a passkey of the
            // Mac's can, and only when macOS says so.
            if (extensions["largeBlob"] as? [String: Any])?["support"] != nil {
                results["largeBlob"] = ["supported": (reply["largeBlob"] as? [String: Any])?["supported"] as? Bool ?? false]
            }
        } else {
            guard let auth = reply["authenticatorData"] as? String, let signature = reply["signature"] as? String else { return nil }
            var response: [String: Any] = ["clientDataJSON": client, "authenticatorData": auth, "signature": signature]
            if let user = reply["userHandle"] as? String { response["userHandle"] = user }
            json["response"] = response
            if extensions["prf"] != nil, let first = prf?["first"] as? String {
                var values = ["first": first]
                if let second = prf?["second"] as? String { values["second"] = second }
                results["prf"] = ["results": values]
            }
            if let asked = extensions["largeBlob"] as? [String: Any] {
                let got = reply["largeBlob"] as? [String: Any] ?? [:]
                var out: [String: Any] = [:]
                if asked["read"] as? Bool == true, let blob = got["blob"] as? String { out["blob"] = blob }
                if asked["write"] != nil { out["written"] = got["written"] as? Bool ?? false }
                results["largeBlob"] = out
            }
            // Whether the signature is over the U2F AppID rather than the RP ID.
            if extensions["appid"] != nil { results["appid"] = reply["appid"] as? Bool ?? false }
        }
        json["clientExtensionResults"] = results
        return (try? JSONSerialization.data(withJSONObject: json)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
