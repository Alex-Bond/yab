import Foundation

/// Morning checks need their own deliberate opt-in. General agent access,
/// old watch preferences and a one-time context Allow do not grant it.
enum BackgroundConsent {
    private static let lock = NSRecursiveLock()
    private static func atomic<T>(_ work: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return work() }
    static let key = "agents.morning.explicit.v1"
    static let morningEpoch = "agents.morning.generation.v1"
    static let mailEpoch = "mail.ahead.generation.v1"
    /// Never while AI in Yab is When Asked or Off (AIUse): nothing in the background.
    static func canStartMorning(settings: UserDefaults = Store.settings) -> Bool {
        atomic { settings.bool(forKey: key) && AIUse.allows(.background, in: settings) }
    }
    static func enableMorning(settings: UserDefaults = Store.settings) { atomic { settings.set(UUID().uuidString, forKey: morningEpoch); settings.set(true, forKey: key) } }
    static func revokeMorning(settings: UserDefaults = Store.settings) { atomic { settings.set(false, forKey: key); settings.set(UUID().uuidString, forKey: morningEpoch) } }
    static func mailChanged(settings: UserDefaults = Store.settings) { atomic { settings.set(UUID().uuidString, forKey: mailEpoch) } }

    /// Replies written ahead is a separate, existing permission. A morning
    /// opt-in never grants mail access, and mail doesn't require mornings.
    static func canStartMailReply(settings: UserDefaults = Store.settings) -> Bool {
        atomic { settings.bool(forKey: MailConsent.aheadKey) && settings.bool(forKey: MailConsent.agentsKey) && AIUse.allows(.background, in: settings) }
    }
    static func permit(mail: Bool = false, settings: UserDefaults = Store.settings) -> BackgroundPermit? {
        atomic {
            guard mail ? canStartMailReply(settings: settings) : canStartMorning(settings: settings) else { return nil }
            let key = mail ? mailEpoch : morningEpoch
            let epoch = settings.string(forKey: key) ?? UUID().uuidString
            settings.set(epoch, forKey: key)
            return BackgroundPermit(mail: mail, epoch: epoch, settings: settings)
        }
    }
    static func valid(_ permit: BackgroundPermit) -> Bool {
        atomic {
            permit.settings.string(forKey: permit.mail ? mailEpoch : morningEpoch) == permit.epoch
                && (permit.mail ? canStartMailReply(settings: permit.settings) : canStartMorning(settings: permit.settings))
        }
    }
}

struct BackgroundPermit: @unchecked Sendable {
    let mail: Bool
    let epoch: String
    let settings: UserDefaults
    var valid: Bool { BackgroundConsent.valid(self) }
}
