import Foundation

/// Local store preparation runs once; every page waits for its reply, or for
/// the deadline when WebKit never gives one (a network process lost at
/// launch), so a missed reply costs a kept sign-in, never a blank page.
@MainActor
final class SignInReadiness {
    static let deadline: TimeInterval = 2

    private var started = false
    private var ready = false
    private var waiting: [@MainActor () -> Void] = []
    private let wait: TimeInterval

    init(deadline: TimeInterval = SignInReadiness.deadline) {
        wait = deadline
    }

    func whenReady(prepare: (@escaping @MainActor () -> Void) -> Void,
                   done: @escaping @MainActor () -> Void) {
        if ready { done(); return }
        waiting.append(done)
        guard !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.ready else { return }
                NSLog("Yab: kept sign-ins not ready after %.0f s; pages go on", self.wait)
                self.finish()
            }
        }
        prepare { self.finish() }
    }

    private func finish() {
        guard !ready else { return }
        ready = true
        let waiting = self.waiting
        self.waiting.removeAll()
        for done in waiting { done() }
    }
}
