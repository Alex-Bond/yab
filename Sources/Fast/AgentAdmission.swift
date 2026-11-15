import Foundation

/// A turn's callbacks retain this object. Renewing the Session for a later
/// deliberate request never revives callbacks belonging to the old turn.
final class AgentTurnPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var admitted = true
    var valid: Bool { lock.withLock { admitted } }
    func revoke() { lock.withLock { admitted = false } }
}

struct AgentAdmission: @unchecked Sendable {
    let turn: AgentTurnPermit
    let provider: ProviderLaunchPermit?
    let external: Bool
    let background: BackgroundPermit?
    let epoch: String
    let context: ContextGrant?
    var valid: Bool { turn.valid && authorityValid }
    /// Completion may schedule a separately admitted follow-up, but it must
    /// retain the producer's original authorities and Memory generation.
    var authorityValid: Bool {
        (external || provider?.valid == true) && (background?.valid ?? true)
            && ContextPrivacy.shared.current(epoch) && (context == nil || ContextPrivacy.shared.valid(context))
    }
}
