import Foundation

/// Local measurements only: no URLs, prompts, page text or account data.
@MainActor
enum BoostMetrics {
    struct Event: Codable { let at: Date; let boost: String; let action: String; let seconds: Double?; let attempts: Int? }
    private static var file: URL { Store.file("boosts/events.json") }
    static func note(_ action: String, _ id: String, seconds: Double? = nil, attempts: Int? = nil) {
        var events = (try? JSONDecoder().decode([Event].self, from: Data(contentsOf: file))) ?? []
        events.append(Event(at: Date(), boost: id, action: action, seconds: seconds, attempts: attempts))
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(events.suffix(500))).write(to: file, options: .atomic)
        } catch { NSLog("yab: could not save boost measurements") }
    }
}
