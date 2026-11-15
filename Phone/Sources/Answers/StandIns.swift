import Foundation

/// What the stand-ins say in explicit fixture worlds: the
/// prototype's own replies (`REPLIES`), the names new chats get (`NAMES`)
/// and the ideas over a new chat's field. The virtual Mac answers with them,
/// and in test worlds so does the stand-in for the model on this iPhone, so
/// every named state and test sees the same words.
enum StandIns {
    struct Reply: Sendable {
        /// Matched against the question, case blind; the first match wins.
        let pattern: String
        /// The iPhone may answer it from the page in front.
        let aboutPage: Bool
        let text: String

        func matches(_ question: String) -> Bool {
            question.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    static let replies: [Reply] = [
        Reply(pattern: "anna.*want|what does anna", aboutPage: true,
              text: "Anna wants a \u{201C}same as last week\u{201D} button on the hours picker, so people don\u{2019}t set their focus hours from scratch every Monday. She left it on frame 2, Pick your focus hours."),
        Reply(pattern: "sprint", aboutPage: false,
              text: "On Thursday in Slack she asked to move it to the next sprint: the beta needs the invite flow first. She\u{2019}ll pair with you on it next Monday."),
        Reply(pattern: "saturday|weekend", aboutPage: false,
              text: "Coffee at Kaffe S\u{F6}der at 9, before it fills up. A walk along S\u{F6}der M\u{E4}larstrand to Fotografiska. Dinner at 19:00: Nook has a table for two. Shall I book it on your Mac?"),
        Reply(pattern: "summar", aboutPage: true,
              text: "Onboarding v3: three welcome screens. Frame 2 picks focus hours and has one open comment from Anna; frame 3 invites the team."),
        Reply(pattern: "book it|yes,? book", aboutPage: false,
              text: "Booking Nook for two at 19:00 on your Mac. I\u{2019}ll say here when it\u{2019}s done."),
    ]

    /// The first reply that matches, if any.
    static func reply(to question: String) -> Reply? { replies.first { $0.matches(question) } }

    /// What a stand-in says to anything it has no reply for.
    static func fallback(_ question: String) -> String {
        "A stand-in answer to \u{201C}\(question.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}. This phone knows its own examples: Anna, the sprint, a Saturday."
    }

    static func answer(_ question: String) -> String { reply(to: question)?.text ?? fallback(question) }

    // MARK: - names

    private static let names: [(pattern: String, name: String)] = [
        ("anna", "Anna\u{2019}s hours picker"),
        ("saturday|weekend", "Saturday in Stockholm"),
        ("summar", "Onboarding v3, summed up"),
    ]

    /// A new chat's name, from its first words: a known subject's own name,
    /// else the words with a capital first letter, no question mark, at most
    /// 25 characters and an ellipsis.
    static func name(for question: String, fixturesEnabled: Bool = true) -> String {
        if fixturesEnabled, let hit = names.first(where: { question.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }) {
            return hit.name
        }
        var words = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = words.first { words = first.uppercased() + words.dropFirst() }
        if words.hasSuffix("?") { words.removeLast() }
        guard words.count > 26 else { return words }
        return String(words.prefix(25)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    // MARK: - ideas

    /// The prototype's ideas for its own pages, by the test page they draw.
    static func ideas(forPage page: String?) -> [String]? {
        switch page {
        case "figma": ["Summarize this page", "What does Anna want?", "Draft replies to Anna"]
        case "flights": ["Cheapest direct flight", "Book a window seat"]
        default: nil
        }
    }

    /// What any page can be asked when no model is there to read it (the
    /// Mac's ChatIdeas.plain).
    static let plainIdeas = ["Summarize this page", "What should I know about this?", "Find more like this"]
}
