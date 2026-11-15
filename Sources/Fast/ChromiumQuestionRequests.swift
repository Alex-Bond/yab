import Foundation

/// Local continuation ownership, not proof of the requesting native document.
/// The current media permission wire has no RFH DocumentToken. In particular,
/// this process generation must never be sent as a made-up document identity.
@MainActor
final class ChromiumQuestionRequests {
    struct Owner: Equatable {
        let client: ObjectIdentifier
        let generation: UUID
        let remote: String
        let profile: String
    }

    @MainActor final class Request {
        let token: String
        let kind: String
        let owner: Owner
        let lifetime = PageFileRequest()
        var nativeClosed = false
        // Native frame/document ownership requires the separate CEF audit.
        let nativeDocument: String? = nil

        init(token: String, kind: String, owner: Owner) {
            self.token = token; self.kind = kind; self.owner = owner
        }
    }

    private var pending: [String: Request] = [:]
    /// Read synchronously by Browser's permission adapter during delivery.
    /// The browser retains this exact lifetime across its UI/TCC work.
    var presentingPermission: PageFileRequest?

    func begin(token: String, kind: String, owner: Owner, reject: @escaping () -> Void) -> Request? {
        // A duplicate must not deny the original callback with this token.
        guard pending[token] == nil else { return nil }
        guard !token.isEmpty, token.count <= 256, pending.count < 128 else { reject(); return nil }
        let request = Request(token: token, kind: kind, owner: owner)
        request.lifetime.whenCancelled { [weak request] in
            if request?.nativeClosed == false { reject() }
        }
        pending[token] = request
        return request
    }

    func finish(_ request: Request, owner: Owner) -> Bool {
        guard request.owner == owner, pending[request.token] === request,
              request.lifetime.isActive else { return false }
        pending[request.token] = nil
        return request.lifetime.finish()
    }

    /// Cancellation is synchronous before observers or late UI replies run.
    /// Denials address only the original request on the original connection.
    func cancel(kind: String? = nil) {
        let ending = pending.values.filter { kind == nil || $0.kind == kind }
        for request in ending { pending[request.token] = nil }
        for request in ending { request.lifetime.cancel() }
    }

    /// An authenticated native prompt dismissal already retired its callback.
    /// It withdraws only this exact local UI, without replying to a dead token.
    func nativeClosed(token: String, owner: Owner) {
        guard let request = pending[token], request.owner == owner else { return }
        pending[token] = nil
        request.nativeClosed = true
        request.lifetime.cancel()
    }
}
