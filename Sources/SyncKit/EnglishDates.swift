import Foundation

/// Yab speaks English, so its dates do too: "Oct 15", never "15 oct." on a
/// Mac or iPhone set to another language (a member card's date said so, 0.0.25). The
/// locale's language is English and its region stays the user's, with its
/// week and its measures; the languages pages, translation and search are
/// asked in (`Locale.preferredLanguages`, AppleLanguages) are left alone.
public enum EnglishDates {
    /// First thing at launch, before anything reads `Locale.current`: the
    /// app's own AppleLocale stands over the system's for this app only.
    public static func apply() {
        let system = CFPreferencesCopyValue("AppleLocale" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        guard let wanted = identifier(system: system) else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "AppleLocale") != wanted { defaults.set(wanted, forKey: "AppleLocale") }
    }

    /// The system's locale with English as its language: ru_RU is en_RU,
    /// sr_Latn_RS is en_RS, an English one stays as it is. Keywords after @
    /// (a calendar, a numbering) are kept.
    public static func identifier(system: String?) -> String? {
        guard let system, !system.isEmpty else { return nil }
        let parts = system.split(separator: "@", maxSplits: 1).map(String.init)
        let locale = Locale(identifier: parts[0])
        if locale.language.languageCode?.identifier == "en" { return system }
        let base = locale.region.map { "en_" + $0.identifier } ?? "en"
        return parts.count > 1 ? base + "@" + parts[1] : base
    }
}
