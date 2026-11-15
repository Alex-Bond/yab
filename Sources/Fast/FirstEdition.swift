import AppKit
import Foundation

/// A personal gift for useful early feedback. The one-use link claims a
/// receipt, kept through Sync; receiving it never depends on posting publicly.
@MainActor
enum FirstEdition {
    static let key = "gift.firstEdition.receipt"
    static var owned: Bool { valid(Store.settings.string(forKey: key)) }

    nonisolated static func valid(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// A button on the matching gift page, on our own origin, is required.
    static func allows(token: String, page: URL?, clicked: Bool) -> Bool {
        guard clicked, valid(token), let page, Dress.ours(page.host()),
              page.scheme == "https" || (Store.testing && page.scheme == "http" && page.host() == Updater.site?.host()) else { return false }
        return page.path == "/gift/\(token)"
    }

    static func receipt(in answer: [String: Any]) -> String? {
        guard answer["icon"] as? String == AppIconStyle.firstEdition.rawValue,
              let receipt = answer["receipt"] as? String, valid(receipt) else { return nil }
        return receipt
    }

    static func claim(_ token: String) async throws {
        if owned { return }
        guard valid(token), let site = Updater.site else { throw Failure.message("This gift link is invalid.") }
        guard let installation = await Invites.installation else { throw Failure.message("Couldn't open your gift. Try again.") }
        var request = URLRequest(url: site.appendingPathComponent("api/gifts/claim"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["token": token, "install": installation])
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let answer = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.message("Couldn't open your gift. Try again.")
        }
        guard http.statusCode == 200, let receipt = receipt(in: answer) else {
            throw Failure.message(answer["error"] as? String ?? "Couldn't open your gift. Try again.")
        }
        Store.settings.set(receipt, forKey: key)
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
