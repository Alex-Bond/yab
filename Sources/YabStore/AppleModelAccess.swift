import Foundation

/// Yab's choice to use Apple's on-device model, separate from macOS availability.
public enum AppleModelAccess {
    public static let disabledKey = "models.mac.disabled"
    /// Enable in Yab, pressed: on even with a plan connected.
    public static let keptKey = "models.mac.kept"
    public static let changed = Notification.Name("YabAppleModelAccessChanged")

    public static var enabled: Bool {
        get { enabled(in: Store.settings) }
        set { setEnabled(newValue, in: Store.settings) }
    }

    /// Off on its row, or stood aside for a connected plan until Enable in
    /// Yab is pressed: a plan does what the Mac's model did where it can.
    public static func enabled(in defaults: UserDefaults) -> Bool {
        !defaults.bool(forKey: disabledKey) && (defaults.bool(forKey: keptKey) || !planConnected(in: defaults))
    }

    /// Who was connected in Settings › AI (ProviderConsent), in the same
    /// settings, so mail's engine and every thread can read it.
    private static func planConnected(in defaults: UserDefaults) -> Bool {
        let revoked = defaults.stringArray(forKey: "agents.revoked-connections.v1") ?? []
        return (defaults.stringArray(forKey: "agents.explicit-connections.v1") ?? []).contains { !revoked.contains($0) }
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        let previous = self.enabled(in: defaults)
        defaults.set(!enabled, forKey: disabledKey)
        defaults.set(enabled, forKey: keptKey)
        if previous != enabled { NotificationCenter.default.post(name: changed, object: nil) }
    }

    /// Whether the Mac's model may be asked for this use now: its own
    /// row in Settings › AI › Models, and AI in Yab (AIUse).
    public static func usable(for use: AIUse.Use = .asked, in defaults: UserDefaults = Store.settings) -> Bool {
        enabled(in: defaults) && AIUse.allows(use, in: defaults)
    }

    /// Read the current choice before consulting a possibly cached hardware answer.
    public static func permits(_ use: AIUse.Use = .asked, in defaults: UserDefaults = Store.settings, availability: () -> Bool) -> Bool {
        usable(for: use, in: defaults) && availability()
    }
}
