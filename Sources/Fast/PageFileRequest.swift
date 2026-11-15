import Foundation

/// The lifetime of one retained native upload callback. UI work may finish
/// later than its requesting document; cancellation must reach it first.
@MainActor
final class PageFileRequest {
    private enum State { case active, completed, cancelled }
    private var state = State.active
    private var cancellation: [() -> Void] = []
    var isActive: Bool { state == .active }

    func whenCancelled(_ action: @escaping () -> Void) {
        if state == .cancelled { action() }
        else if state == .active { cancellation.append(action) }
    }

    @discardableResult func finish() -> Bool {
        guard isActive else { return false }
        state = .completed
        cancellation.removeAll()
        return true
    }

    func cancel() {
        guard isActive else { return }
        state = .cancelled
        let actions = cancellation
        cancellation.removeAll()
        for action in actions { action() }
    }
}

/// Request IDs alone may be reused after a helper reconnect. Retain the
/// lifetime object as well, so an old completion cannot consume a new one.
@MainActor
final class PageFileRequests {
    private var pending: (token: String, lifetime: PageFileRequest)?

    func begin(_ token: String) -> PageFileRequest {
        cancel()
        let lifetime = PageFileRequest()
        pending = (token, lifetime)
        return lifetime
    }

    func finish(_ token: String, _ lifetime: PageFileRequest) -> Bool {
        guard let current = pending, current.token == token, current.lifetime === lifetime else { return false }
        pending = nil
        return lifetime.finish()
    }

    func cancel(_ token: String? = nil) {
        guard let current = pending, token == nil || token == current.token else { return }
        pending = nil
        current.lifetime.cancel()
    }
}
