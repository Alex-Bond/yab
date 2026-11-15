import AppKit
import YabCoreClient

extension ChromiumPage {
    /// Origin and request identity come from the browser-process callback.
    /// Script messages cannot reach this path.
    func receiveQuestion(_ p: [String: JSONValue]) {
        guard let token = p["request"]?.string, let remote = remoteID,
              let core = ChromiumProcess.shared.connectedClient else { return }
        let generation = ChromiumProcess.shared.connectionGeneration
        let owner = ChromiumQuestionRequests.Owner(client: ObjectIdentifier(core), generation: generation,
                                                    remote: remote, profile: profile)
        let kind = p["kind"]?.string ?? ""
        // The helper owns the original native callback. Never look up a new
        // helper while completing this one, even if it reuses tab/request IDs.
        guard let request = questionRequests.begin(token: token, kind: kind, owner: owner, reject: {
            Task { @MainActor in
                guard ChromiumProcess.shared.isCurrent(core, generation: generation) else { return }
                _ = try? await core.request("question.reply", params: ["tab": .string(remote),
                    "request": .string(token), "allow": .bool(false)])
            }
        }) else { return }
        let finish: @MainActor ([String: JSONValue]) -> Void = { [weak self] values in
            Task { @MainActor [weak self] in
                guard let self, self.remoteID == remote, self.profile == owner.profile,
                      ChromiumProcess.shared.isCurrent(core, generation: generation),
                      self.questionRequests.finish(request, owner: owner) else { return }
                let reply = ChromiumQuestionDelivery.reply(values, token: token, remote: remote)
                _ = try? await core.request("question.reply", params: reply)
            }
        }
        guard p["profile"] == nil || p["profile"] == .string(profile) else { finish(["allow": .bool(false)]); return }
        guard let events else { finish(["allow": .bool(false)]); return }
        let previous = questionRequests.presentingPermission
        questionRequests.presentingPermission = request.lifetime
        defer { questionRequests.presentingPermission = previous }
        ChromiumQuestionDelivery.send(p, page: self, events: events, finish: finish)
    }

    func receiveQuestionClosed(_ p: [String: JSONValue]) {
        guard let remote = remoteID, p["tab"]?.string == remote, p["profile"]?.string == profile,
              let token = p["request"]?.string, let core = ChromiumProcess.shared.connectedClient else { return }
        let owner = ChromiumQuestionRequests.Owner(client: ObjectIdentifier(core),
            generation: ChromiumProcess.shared.connectionGeneration, remote: remote, profile: profile)
        questionRequests.nativeClosed(token: token, owner: owner)
    }
}

/// Presentation after receiveQuestion's original-client/generation/request admission.
/// Calling this adapter is not evidence of a live native callback or document.
@MainActor
enum ChromiumQuestionDelivery {
    static func reply(_ values: [String: JSONValue], token: String, remote: String) -> [String: JSONValue] {
        var reply = values
        // The captured original continuation owns these IDs, never UI values.
        reply["request"] = .string(token); reply["tab"] = .string(remote)
        return reply
    }

    static func send(_ p: [String: JSONValue], page: ChromiumPage, events: any PageEvents,
                     finish: @escaping @MainActor ([String: JSONValue]) -> Void) {
        let source = p["origin"]?.string.flatMap(URL.init(string:))
        let origin = PageOrigin(scheme: source?.scheme ?? "", host: source?.host ?? "", port: source?.port ?? 0)
        switch p["kind"]?.string ?? "" {
        case "certificate":
            page.receiveCertificate(p, finish: finish)
        case "auth":
            let auth = PageAuthentication(host: p["host"]?.string ?? "", realm: p["realm"]?.string,
                                          scheme: source?.scheme, method: ["basic": NSURLAuthenticationMethodHTTPBasic, "digest": NSURLAuthenticationMethodHTTPDigest,
                                                   "ntlm": NSURLAuthenticationMethodNTLM][p["scheme"]?.string?.lowercased() ?? ""] ?? (p["scheme"]?.string ?? ""),
                                          previousFailureCount: Int(p["failures"]?.number ?? 0),
                                          proposedUser: nil, proposedPasswordIsEmpty: p["failures"]?.number == 0)
            events.page(page, authenticate: auth) { reply in
                switch reply {
                case .credential(let user, let password):
                    finish(["allow": .bool(true), "user": .string(user), "password": .string(password)])
                case .cancel, .performDefaultHandling: finish(["allow": .bool(false)])
                }
            }
        case "capture":
            let camera = p["camera"] == .bool(true), microphone = p["microphone"] == .bool(true)
            guard camera || microphone else { finish(["allow": .bool(false)]); return }
            let type: PageCapture = camera && microphone ? .cameraAndMicrophone : camera ? .camera : .microphone
            events.page(page, capture: type, origin: origin) { finish(["allow": .bool($0 == .grant)]) }
        case "location":
            events.page(page, locate: origin) { finish(["allow": .bool($0 == .grant)]) }
        case "notifications":
            events.page(page, notify: origin) { finish(["allow": .bool($0)]) }
        default: finish(["allow": .bool(false)])
        }
    }
}
