import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// ⌘J with no agent connected but Apple's model on this Mac: a short answer
/// about the page, or what is selected on it, at the line's foot. Nothing
/// leaves the Mac. A task (open, book, fill in) still needs an agent, and
/// the line says so (TaskLine.askHere).
enum MacAnswer {
    /// The model reads about 4,000 tokens in all, question and answer
    /// included: the page's start, and a shorter one if that was too much.
    static let room = 5_000
    static let shorter = 1_800

    /// Words this Mac can do on its own though they read as a task:
    /// "summarize this", "explain the second part".
    static func readsOnly(_ words: String) -> Bool {
        let first = words.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        return ["summarize", "summarise", "explain", "tldr", "tl;dr", "translate", "what", "who", "why", "how", "when", "where", "which", "is", "are", "does", "do", "can"].contains(first)
    }

    enum Failure: Error { case unavailable }

    static func stream(_ question: String, page: String, selection: String?,
                       partial: @MainActor @escaping (String) -> Void) async throws {
        do {
            try await ask(question, page: String(page.prefix(room)), selection: selection, partial: partial)
        } catch Failure.unavailable {
            throw Failure.unavailable
        } catch where !page.isEmpty && !Task.isCancelled {
            // Over the model's room, most often: once more with less of the page.
            try await ask(question, page: String(page.prefix(shorter)), selection: selection, partial: partial)
        }
    }

    private static func ask(_ question: String, page: String, selection: String?,
                            partial: @MainActor @escaping (String) -> Void) async throws {
        guard FormModel.ready else { throw Failure.unavailable }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                Answer briefly and plainly, in the language of the question, from the page and the selected text given. \
                If they don't say, say so in one sentence. Add no facts.
                """)
            var prompt = "Question: \(question)"
            if let selection, !selection.isEmpty { prompt += "\n\nSelected text:\n" + selection.prefix(1_500) }
            if !page.isEmpty { prompt += "\n\nThe page:\n" + page }
            for try await snapshot in session.streamResponse(to: prompt) {
                await partial(snapshot.content)
            }
            return
        }
        #endif
        throw Failure.unavailable
    }
}
