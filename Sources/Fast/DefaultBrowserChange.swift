import Foundation

/// One system question at a time. Launch Services can change the handler
/// before delivering its callback, or omit the callback altogether.
@MainActor
final class DefaultBrowserChange {
    typealias Request = (String, @escaping (Bool) -> Void) -> Void
    private let current: (String) -> Bool
    private let request: Request
    private let html: () -> Void
    private var completion: ((Bool) -> Void)?
    private var remaining = ["http", "https"]
    private var pending: String?
    private var timer: Timer?
    private let deadline: Date

    init(timeout: TimeInterval = 60, current: @escaping (String) -> Bool,
         request: @escaping Request, html: @escaping () -> Void,
         completion: @escaping (Bool) -> Void) {
        self.current = current
        self.request = request
        self.html = html
        self.completion = completion
        deadline = Date().addingTimeInterval(timeout)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        advance()
    }

    /// Also used by tests to observe a changed handler without waiting.
    func check(now: Date = Date()) {
        guard completion != nil else { return }
        if let pending, current(pending) {
            answered(pending, success: true)
        }
        if completion != nil, now >= deadline { finish(false) }
    }

    private func advance() {
        guard completion != nil else { return }
        while let scheme = remaining.first, current(scheme) { remaining.removeFirst() }
        guard let scheme = remaining.first else { finish(true); return }
        pending = scheme
        request(scheme) { [weak self] success in self?.answered(scheme, success: success) }
    }

    private func answered(_ scheme: String, success: Bool) {
        guard completion != nil, pending == scheme else { return }
        guard success || current(scheme) else { finish(false); return }
        pending = nil
        remaining.removeFirst()
        advance()
    }

    private func finish(_ success: Bool) {
        guard let done = completion else { return }
        completion = nil
        timer?.invalidate()
        timer = nil
        // File associations are separate from accepting web links. They
        // must never hold the welcome screen open after the user said yes.
        if success { html() }
        done(success)
    }
}
