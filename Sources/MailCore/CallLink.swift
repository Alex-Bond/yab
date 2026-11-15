import Foundation

/// A link to a call, and which call it is: two links to one meeting are
/// one call, so the second finds the tab the first opened.
public enum CallLink {
    /// "meet:abc-defg-hij", "zoom:123456789", or nil for a page that isn't
    /// a meeting: Meet's home, Zoom's site, a Teams chat.
    public static func key(_ url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased(),
              url.scheme?.lowercased().hasPrefix("http") == true
        else { return nil }
        let parts = url.path.split(separator: "/").map { String($0) }
        if benchHosts.contains(host) { return "bench:" + host + url.path }
        switch host {
        case "meet.google.com":
            // A meeting's code; or /lookup/<name>, a nickname for one.
            if let code = parts.first?.lowercased(),
               code.range(of: #"^[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil {
                return "meet:" + code
            }
            if parts.count >= 2, parts[0] == "lookup" { return "meet:" + parts[1].lowercased() }
            return nil
        case _ where host == "zoom.us" || host.hasSuffix(".zoom.us"):
            // /j/123, /wc/123/join, /wc/join/123, /s/123 and the like, or /my/<name>.
            guard parts.count >= 2 else { return nil }
            if ["j", "wc", "s", "w"].contains(parts[0]), !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber) {
                return "zoom:" + parts[1]
            }
            if parts.count >= 3, parts[0] == "wc", parts[1] == "join", !parts[2].isEmpty, parts[2].allSatisfy(\.isNumber) {
                return "zoom:" + parts[2]
            }
            if parts[0] == "my" { return "zoom:" + parts[1].lowercased() }
            return nil
        // Work and school Teams moved to teams.cloud.microsoft in 2026.
        case "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com":
            if parts.count >= 3, parts[0] == "l", parts[1] == "meetup-join" { return "teams:" + parts[2] }
            if parts.count >= 2, parts[0] == "meet" { return "teams:" + parts[1] }
            return nil
        case "app.slack.com":
            if parts.count >= 3, parts[0] == "huddle" { return "slack:" + parts[1] + "/" + parts[2] }
            return nil
        case _ where host.hasSuffix(".webex.com"):
            if parts.count >= 2, ["meet", "join", "j.php", "wbxmjs"].contains(parts[0]) {
                return "webex:" + host + "/" + parts[1].lowercased()
            }
            return nil
        default:
            return nil
        }
    }

    public static func isCall(_ url: URL?) -> Bool { key(url) != nil }

    /// Hosts the bench counts as meetings: a test world's local call page.
    public nonisolated(unsafe) static var benchHosts: Set<String> = []

    /// Made once and shared, the calendar's queue reading with it.
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    /// A word every call's link has, to pass over the notes that have none
    /// without the detector: most of a day's events.
    private static let hints = ["meet.google", "zoom", "teams.", "slack.com", "webex"]

    /// The first link to a call in some text: an event's place or notes.
    public static func find(in text: String?) -> URL? {
        guard let text, !text.isEmpty, let detector else { return nil }
        let lower = text.lowercased()
        guard !benchHosts.isEmpty || hints.contains(where: lower.contains) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, isCall(url) { return url }
        }
        return nil
    }
}
