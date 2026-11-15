import AppKit
import AuthenticationServices
import YabCoreClient

// Passkey autofill on Chromium pages: WebAuthn's conditional mediation.
//
// A sign-in page asks navigator.credentials.get({mediation: "conditional"})
// as it loads and marks its name box autocomplete="username webauthn".
// Chrome on the Mac keeps that request pending with no UI and no timeout
// (content/browser/webauth, WebAuthnConditionalRequest), reads the site's
// passkeys from iCloud Keychain once, when the Mac lets it read them
// (device/fido/mac/icloud_keychain.mm, platformCredentialsForRelyingParty),
// and lists them in its autofill dropdown when the box gets the caret, next
// to saved passwords ("Passkey • Apple Passwords"). A pick runs the
// assertion for that one credential through the Mac's sheet, Touch ID and
// all; a sheet dismissed leaves the request pending, as Chromium restarts it.
//
// Yab does the same with CEF 0127: Chromium hands the conditional get over
// with mediation "conditional" and keeps it pending; it is kept here, the
// site's passkeys are read once, and they are rows of Yab's own list under
// the box (ManagerSuggestions, SuggestRow.Kind.passkey). A pick goes through
// Passkeys.perform, the path the modal sheet takes, for that credential
// alone. The page's abort, or its document going away, ends it
// (webauthn.cancel).

/// One of the site's passkeys, offered under the box for a pending
/// conditional get.
struct ConditionalPasskey: Equatable {
    /// The conditional get a pick answers.
    let request: String
    /// The credential's ID, base64url.
    let id: String
    let user: String
    /// Who keeps it: Apple Passwords, or a passkey app the Mac lets in.
    let provider: String

    /// The row's second line, Chrome's words in Yab's separator.
    var detail: String { "Passkey · " + provider }
}

/// What the box with the caret is offered for a pending conditional get:
/// the site's passkeys, and the way to another device's (Chrome's footer
/// "Use Passkey from another device", shown once the passkeys are read,
/// with none of them or with some).
struct ConditionalOffer: Equatable {
    let request: String
    let passkeys: [ConditionalPasskey]
}

extension ChromiumWebAuthn {
    struct Conditional {
        let client: YabCoreClient
        let request: String
        let token: String
        let options: [String: Any]
        let rp: String
        let origin: String
        let topOrigin: String
        let crossOrigin: Bool
        let mainFrame: Bool
        weak var page: ChromiumPage?
        let at: Date
        /// The site's passkeys, nil until read.
        var passkeys: [ConditionalPasskey]? = nil
        /// A pick's sheet is up for it.
        var picking = false
    }

    /// Pending conditional gets, by request.
    static var conditional: [String: Conditional] = [:]
    /// A test world's passkeys (bench passkey-stage), never the Mac's own:
    /// [(id, user, provider)].
    static var staged: [(id: String, user: String, provider: String)]?
    /// More than a person has sign-in frames open: the newest past it is refused.
    static let mostConditional = 32

    /// Whether Yab can serve one: passkeys on, and a build that can ask the
    /// Mac for them (a test run rehearses).
    static var servesConditional: Bool {
        FormRelay.passkeysOffered && (PasskeyHint.possible || Store.testing)
    }

    static func keepConditional(_ p: [String: JSONValue], request: String, client: YabCoreClient, page: ChromiumPage?) {
        let refusal = "The operation either timed out or was not allowed."
        conditional = conditional.filter { ChromiumProcess.shared.isCurrent($0.value.client) }
        guard servesConditional, conditional.count < mostConditional,
              let options = (p["options"]?.string).flatMap({ $0.data(using: .utf8) })
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
              let rp = (options["rpId"] as? String)?.lowercased(), !rp.isEmpty,
              body(kind: "get", options: options, token: "chromium-\(request)") != nil,
              let origin = p["origin"]?.string, URL(string: origin)?.host() != nil
        else {
            return respond(client, request, error: "NotAllowedError", message: refusal)
        }
        let entry = Conditional(client: client, request: request, token: "chromium-\(request)", options: options, rp: rp,
                                origin: origin, topOrigin: p["topOrigin"]?.string ?? origin,
                                crossOrigin: p["sameOriginWithAncestors"] == .bool(false),
                                mainFrame: p["mainFrame"] != .bool(false), page: page, at: Date())
        conditional[request] = entry
        Passkeys.note("chromium conditional \(request) for \(rp) kept")
        read(entry)
    }

    /// The site's passkeys, read once, as Chromium reads iCloud Keychain's at
    /// the request: only when the Mac already lets Yab read them (no
    /// question for a page that merely loaded), filtered by the request's
    /// allowCredentials as Chromium filters them.
    private static func read(_ entry: Conditional) {
        let allowed = Set((entry.options["allowCredentials"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        func keep(_ found: [(id: String, user: String, provider: String)]) {
            guard conditional[entry.request] != nil else { return }
            let list = found.filter { allowed.isEmpty || allowed.contains($0.id) }
                .map { ConditionalPasskey(request: entry.request, id: $0.id, user: $0.user, provider: $0.provider.isEmpty ? "Apple Passwords" : $0.provider) }
            conditional[entry.request]?.passkeys = list
            Passkeys.note("chromium conditional \(entry.request): \(list.count) passkeys for \(entry.rp)")
            refresh(entry)
        }
        if Store.testing, let found = staged { return keep(found) }
        guard Passkeys.access == .authorized else { return keep([]) }
        Task { @MainActor in
            let found = await ASAuthorizationWebBrowserPublicKeyCredentialManager().platformCredentials(forRelyingParty: entry.rp)
            keep(found.map { (id: Passkeys.text($0.credentialID), user: $0.name, provider: $0.providerName) })
        }
    }

    /// The box with the caret asks again, so rows that came or went show.
    static func refresh(_ entry: Conditional) {
        guard let tab = entry.page?.navigationTab, let spot = tab.fieldSpot else { return }
        tab.onField?(tab, spot)
    }

    /// What to list under the box the caret is in: a box marked webauthn,
    /// in a frame of the origin a pending conditional get came from, on
    /// this page, once its passkeys are read (as Chromium's list waits for
    /// them). The newest request answers.
    static func offer(for tab: Tab) -> ConditionalOffer? {
        guard tab.fieldWebAuthn, servesConditional, let page = tab.builtPage as? ChromiumPage else { return nil }
        let address = tab.fieldAddress
        let mine = conditional.values.filter {
            $0.page === page && !$0.picking && ChromiumProcess.shared.isCurrent($0.client) && sameOrigin($0.origin, address)
        }
        guard let newest = mine.max(by: { $0.at < $1.at }), let passkeys = newest.passkeys else { return nil }
        return ConditionalOffer(request: newest.request, passkeys: passkeys)
    }

    /// Chromium's serialized origin (https://example.com, http://localhost:8080)
    /// against a page's address.
    static func sameOrigin(_ origin: String, _ url: URL?) -> Bool {
        guard let a = URL(string: origin), let b = url else { return false }
        func parts(_ u: URL) -> (String, String, Int)? {
            guard let scheme = u.scheme?.lowercased(), let host = u.host()?.lowercased() else { return nil }
            return (scheme, host, u.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0))
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        return x == y
    }

    /// What a pick asks the Mac's sheet: the conditional get as it came,
    /// for the one credential picked, from the Mac's passkeys alone (Chrome
    /// dispatches a picked iCloud Keychain passkey to it with that
    /// allowCredentials, nothing else).
    static func pickedBody(_ options: [String: Any], id: String, token: String) -> [String: Any]? {
        var asked = options
        asked["allowCredentials"] = [["type": "public-key", "id": id]]
        guard var made = body(kind: "get", options: asked, token: token) else { return nil }
        made["platformOnly"] = true
        return made
    }

    /// A passkey row taken: the assertion through the Mac's sheet, as the
    /// modal path, and its answer to the pending get. A sheet dismissed or
    /// failing leaves the request pending, as Chromium's autofill restarts it
    /// ("Conditional UI requests are never cancelled").
    static func choose(_ key: ConditionalPasskey) {
        guard let entry = conditional[key.request], let body = pickedBody(entry.options, id: key.id, token: entry.token) else { return }
        Passkeys.note("chromium conditional \(key.request): picked a passkey of \(key.provider)")
        ceremony(entry, body)
    }

    /// What "Use Passkey from another device" asks: the conditional get as
    /// it came, on the modal sheet (Chrome's LaunchSecurityKeyOrHybridFlow
    /// opens its modal dialog for the same request): the Mac's sheet offers
    /// a phone nearby, a security key and the Mac's own passkeys.
    static func otherDeviceBody(_ options: [String: Any], token: String) -> [String: Any]? {
        body(kind: "get", options: options, token: token)
    }

    /// The footer row taken.
    static func chooseOtherDevice(_ request: String) {
        guard let entry = conditional[request], let body = otherDeviceBody(entry.options, token: entry.token) else { return }
        Passkeys.note("chromium conditional \(request): another device's passkey")
        ceremony(entry, body)
    }

    /// The modal sheet for a pending conditional get, and its answer to it.
    private static func ceremony(_ entry: Conditional, _ body: [String: Any]) {
        let request = entry.request
        guard !entry.picking, ChromiumProcess.shared.isCurrent(entry.client),
              let url = URL(string: entry.origin), let scheme = url.scheme, let host = url.host()
        else { return }
        let caller = Passkeys.Caller(
            origin: PageOrigin(scheme: scheme, host: host, port: url.port ?? 0),
            mainFrame: entry.mainFrame, pageHost: nil, window: entry.page?.window,
            chromium: .init(origin: entry.origin, topOrigin: entry.topOrigin, crossOrigin: entry.crossOrigin))
        conditional[request]?.picking = true
        Passkeys.shared.perform(body, from: caller) { reply in
            // Aborted or gone meanwhile: the page has had its answer.
            guard let current = conditional[request] else { return }
            if reply["error"] == nil, let json = response(kind: "get", reply: reply, options: current.options) {
                conditional[request] = nil
                respond(current.client, request, response: json)
            } else {
                conditional[request]?.picking = false
                Passkeys.note("chromium conditional \(request) stays: \(reply["error"] as? String ?? "no answer")")
            }
        }
    }

    /// For the bench: what is pending, without credentials.
    static var conditionalReport: [[String: Any]] {
        conditional.values.sorted { $0.at < $1.at }.map {
            ["request": $0.request, "rp": $0.rp, "origin": $0.origin, "picking": $0.picking,
             "passkeys": $0.passkeys.map { $0.count } ?? -1]
        }
    }
}
