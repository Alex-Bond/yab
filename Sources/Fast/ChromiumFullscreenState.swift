/// Chromium's latest element-fullscreen request and the native presentation
/// that is carrying it. A presentation may still be returning when a newer
/// request arrives; its lifetime must never stand in for that newer target.
struct ChromiumFullscreenState: Equatable {
    enum Phase: String { case waiting, entering, fullscreen, exiting, windowed, finished }
    enum Action: Equatable { case none, enter, exit, returnPage }

    let ownsWindow: Bool
    private(set) var requested = true
    private(set) var phase: Phase

    init(ownsWindow: Bool) {
        self.ownsWindow = ownsWindow
        phase = ownsWindow ? .waiting : .fullscreen
    }

    mutating func request(_ fullscreen: Bool) {
        guard phase != .finished else { return }
        requested = fullscreen
    }

    /// Exactly one native operation for each transition. Requests made
    /// during an operation change its target, not the in-flight operation.
    mutating func next(visible: Bool) -> Action {
        guard phase != .finished else { return .none }
        if !ownsWindow {
            guard !requested else { return .none }
            phase = .finished
            return .returnPage
        }
        switch phase {
        case .waiting, .windowed:
            if !requested { phase = .finished; return .returnPage }
            guard visible else { phase = .waiting; return .none }
            phase = .entering
            return .enter
        case .fullscreen:
            guard !requested else { return .none }
            phase = .exiting
            return .exit
        case .entering, .exiting, .finished:
            return .none
        }
    }

    mutating func entered() {
        guard phase == .entering else { return }
        phase = .fullscreen
    }

    /// A native green button / menu exit is an input to this same owner.
    /// Our own exit was already requested by Chromium; do not send it twice
    /// or erase a newer renderer request while that exit is starting.
    mutating func windowAskedToExit() -> Bool {
        guard phase != .finished, phase != .exiting else { return false }
        requested = false
        phase = .exiting
        return true
    }

    mutating func exited() {
        guard phase != .finished else { return }
        phase = .windowed
    }

    mutating func failedToEnter() {
        guard phase != .finished else { return }
        requested = false
        phase = .windowed
    }
}
