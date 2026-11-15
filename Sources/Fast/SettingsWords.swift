import Foundation

/// Settings alone uses this table. Missing entries keep their English text;
/// account names, persisted values and setting IDs never pass through it.
enum SettingsWords {
    static let table = "Settings"

    static func text(_ english: String, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: english, value: english, table: table)
    }

    /// An explicit bundle lets tests exercise a language without changing the
    /// user's language or the process defaults. Foundation formats the values.
    static func format(_ english: String, _ arguments: [CVarArg], bundle: Bundle = .main) -> String {
        String(format: text(english, bundle: bundle), arguments: arguments)
    }
}
