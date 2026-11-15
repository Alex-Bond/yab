import Foundation

let app = URL(fileURLWithPath: CommandLine.arguments[1])
let baseline = CommandLine.arguments.contains("--baseline")
guard let bundle = Bundle(url: app),
      bundle.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String == "en"
else { fatalError("Native app English development region is missing") }
let expected = baseline ? ["en", "ja", "es"] : ["en"]
precondition(Set(bundle.localizations) == Set(expected), "Unexpected packaged languages: \(bundle.localizations)")
precondition(bundle.object(forInfoDictionaryKey: "CFBundleLocalizations") as? [String] == expected)
func word(_ key: String) -> String {
    bundle.localizedString(forKey: key, value: key, table: "Settings")
}
if baseline {
    guard let path = bundle.path(forResource: "ja", ofType: "lproj"), let japanese = Bundle(path: path)
    else { fatalError("Main is missing its Japanese Settings table") }
    precondition(japanese.localizedString(forKey: "Search", value: "Search", table: "Settings") == "\u{691c}\u{7d22}")
    print("PASS: main contains working Japanese Settings translations")
} else {
    for code in ["ja", "es"] {
        precondition(!FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/\(code).lproj").path))
        precondition(Set(Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [code])) == ["en"])
    }
    for key in ["Search", "Privacy", "Search with", "Default browser", "Unknown setting"] {
        precondition(word(key) == key, "Settings must remain English: \(key)")
    }
    precondition(String(format: word("Opens %@"), "Spaces") == "Opens Spaces")
    precondition(String(format: word("%ld cards"), 3) == "3 cards")
    print("PASS: packaged Settings stays English with Japanese and Spanish language preferences")
}
