import Foundation

// EnglishDates relies on an app's own AppleLocale, set before Locale.current
// is first read, standing over the system's for that process. This shows it:
// set fr_FR in this process's domain, read the current locale and a date,
// then take the key away again.
//   swiftc evals/english-dates/probe.swift -o /tmp/english-dates && /tmp/english-dates
let key = "AppleLocale"
let system = CFPreferencesCopyValue(key as CFString, kCFPreferencesAnyApplication,
                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
UserDefaults.standard.set("fr_FR", forKey: key)
let current = Locale.current.identifier
let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: 2026, month: 10, day: 15).date!
let words = day.formatted(.dateTime.day().month(.abbreviated))
UserDefaults.standard.removeObject(forKey: key)
print("system \(system ?? "nil"), current \(current), date \(words), languages \(Locale.preferredLanguages.prefix(2))")
exit(current == "fr_FR" && words.contains("oct") ? 0 : 1)
