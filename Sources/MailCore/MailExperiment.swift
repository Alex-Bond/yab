import Foundation

/// Mail is available only after an explicit experimental opt-in. The old
/// switch alone must not keep it visible after an upgrade.
public enum MailExperiment {
    public static let key = "experimental.mail"
    public static func enabled(in defaults: UserDefaults = Store.settings) -> Bool {
        defaults.bool(forKey: key) && defaults.bool(forKey: "mail")
    }

    /// IMAP and SMTP share Mail's opt-in. Ignore the retired
    /// experimental.mail.imap preference, including an old false value.
    public static func otherAccounts(in defaults: UserDefaults = Store.settings) -> Bool {
        enabled(in: defaults)
    }
}
