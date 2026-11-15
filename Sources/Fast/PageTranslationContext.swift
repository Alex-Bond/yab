import Foundation
import Translation

/// Node identities let Apple align a paragraph's translation with its inline markup.
enum PageTranslationNode: AttributedStringKey {
    typealias Value = String
    static let name = "yab.translation.node"
}

struct PageTranslationContext {
    struct Part {
        let id: String
        let text: String
        var anchored = true
    }

    let id: String
    let parts: [Part]

    @available(macOS 26.4, *)
    var source: AttributedString {
        var text = AttributedString("")
        for part in parts {
            var segment = AttributedString(part.text)
            segment[PageTranslationNode.self] = part.id
            text.append(segment)
        }
        return text
    }

    @available(macOS 26.4, *)
    var request: TranslationSession.Request {
        .init(sourceText: source, clientIdentifier: id)
    }

    /// Plain text may move around an inline element, but the element itself
    /// must stay in place. Fall back when the translated anchors change order.
    @available(macOS 26.4, *)
    func aligned(_ answer: TranslationSession.Response) -> [[String: String]]? {
        guard let text = answer.attributedTargetText else { return nil }
        let positions = Dictionary(uniqueKeysWithValues: parts.enumerated().map { ($0.element.id, $0.offset) })
        var lastAnchor = -1
        var previousAnchor: String?
        var plain = ""
        var values: [String: String] = [:]
        func flushPlain(before end: Int) -> Bool {
            guard !plain.isEmpty else { return true }
            guard let destination = parts[(lastAnchor + 1)..<end].first(where: { !$0.anchored }) else { return false }
            values[destination.id, default: ""] += plain
            plain = ""
            return true
        }
        for run in text.runs {
            guard let id = run[PageTranslationNode.self], let position = positions[id] else { return nil }
            let translated = String(text[run.range].characters)
            if parts[position].anchored {
                if previousAnchor != id {
                    guard position > lastAnchor, flushPlain(before: position) else { return nil }
                    lastAnchor = position
                }
                values[id, default: ""] += translated
                previousAnchor = id
            } else {
                plain += translated
                previousAnchor = nil
            }
        }
        guard flushPlain(before: parts.count),
              parts.filter(\.anchored).allSatisfy({ !(values[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              parts.map({ values[$0.id] ?? "" }).joined() == answer.targetText else { return nil }
        return parts.map { ["id": $0.id, "text": values[$0.id] ?? "", "exact": "true", "group": id] }
    }
}
