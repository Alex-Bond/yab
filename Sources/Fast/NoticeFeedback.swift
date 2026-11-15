import AppKit

/// One tactile answer for a newly offered action or a completed action.
/// The system silently ignores it on Macs without a haptic trackpad.
@MainActor
enum NoticeFeedback {
    case offer
    case success

    private static var lastOffer = -Double.infinity
    private static var lastSuccess = -Double.infinity
    private static var successPair: UUID?

    func play() {
        guard NSApp.isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if self == .offer {
            guard now - Self.lastOffer > 0.25 else { return }
            Self.lastOffer = now
        } else {
            guard now - Self.lastSuccess > 0.25 else { return }
            Self.lastSuccess = now
            Self.successPair = nil
        }
        let pattern: NSHapticFeedbackManager.FeedbackPattern = self == .offer ? .alignment : .generic
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// The two strokes of a visible success mark call these at their
    /// actual animation completions. One view owns the pair, even when
    /// several windows show the same result.
    static func beginSuccessPair() -> UUID? {
        guard NSApp.isActive else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSuccess > 0.25 else { return nil }
        lastSuccess = now
        let token = UUID()
        successPair = token
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return token
    }

    static func endSuccessPair(_ token: UUID) {
        guard successPair == token else { return }
        successPair = nil
        guard NSApp.isActive else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    static func cancelSuccessPair(_ token: UUID) {
        if successPair == token { successPair = nil }
    }
}
