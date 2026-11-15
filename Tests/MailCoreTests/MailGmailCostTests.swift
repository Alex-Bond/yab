import Foundation
import Testing
@testable import MailCore

// What each Gmail call costs of the user's quota (docs/mail.md, Sync): every
// path mail's code calls has its price from Google's table, and a path
// nobody priced fails here rather than in someone's quota.
struct MailGmailCostTests {
    /// Every call the plan's work makes, priced as Google's table had it on
    /// 2026-09-10 (developers.google.com/workspace/gmail/api/reference/quota).
    static let priced: [(path: String, method: String, cost: Int)] = [
        ("profile", "GET", 1), ("history", "GET", 2),
        ("labels", "GET", 1), ("labels", "POST", 5), ("labels/Label_1", "GET", 1), ("labels/Label_1", "PATCH", 5), ("labels/Label_1", "DELETE", 5),
        ("messages", "GET", 5), ("messages/m1", "GET", 20), ("messages/m1/attachments/a1", "GET", 20),
        ("messages/m1/modify", "POST", 5), ("messages/batchModify", "POST", 50),
        ("messages/send", "POST", 100), ("upload/messages/send", "POST", 100),
        ("messages/m1/trash", "POST", 20), ("messages/m1/untrash", "POST", 5),
        ("threads", "GET", 10), ("threads/t1", "GET", 40), ("threads/t1/modify", "POST", 10),
        ("threads/t1/trash", "POST", 20), ("threads/t1/untrash", "POST", 10),
        ("drafts", "GET", 5), ("drafts", "POST", 10), ("drafts/d1", "GET", 20), ("drafts/d1", "PUT", 15),
        ("drafts/d1", "DELETE", 10), ("drafts/send", "POST", 100),
        ("settings/sendAs", "GET", 1), ("settings/sendAs/me@example.com", "GET", 1),
    ]

    @Test func everyPathHasItsCost() throws {
        for call in Self.priced {
            #expect(MailGmail.cost(call.path, method: call.method) == call.cost, "\(call.method) \(call.path)")
        }
        // Every call in mail's code as it is written there.
        let calls = try Self.calls()
        #expect(calls.count >= 10)
        for call in calls {
            #expect(MailGmail.method(call.path, call.method) != nil, "\(call.method) \(call.path) (\(call.at)) has no price: add it to MailGmail.quota")
        }
        // Nothing that deletes for good is priced: Yab never does it.
        #expect(MailGmail.method("threads/t1", "DELETE") == nil)
        #expect(MailGmail.method("messages/batchDelete", "POST") == nil)
        // And what has no price counts as dear as a send.
        #expect(MailGmail.cost("watch", method: "POST") == 100)
    }

    /// Each `call("…")` in Mail*.swift, the engine's and the app's: its path
    /// with every \(…) as x, its HTTP method, and where it is.
    static func calls() throws -> [(path: String, method: String, at: String)] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = try ["Sources/MailCore", "Sources/Fast"].flatMap { folder in
            try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)
        }.filter { $0.lastPathComponent.hasPrefix("Mail") && $0.pathExtension == "swift" }
        let literal = try NSRegularExpression(pattern: #"\bcall\(\s*"((?:[^"\\]|\\\([^)]*\))*)""#)
        let method = try NSRegularExpression(pattern: #"method:\s*"([A-Z]+)""#)
        // A call whose path isn't written out can't be priced here.
        let unread = try NSRegularExpression(pattern: #"await\s+(?:[\w.]+\.)?call\(\s*[^"\s)]"#)
        var out: [(String, String, String)] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (n, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                let at = "\(file.lastPathComponent):\(n + 1)"
                #expect(unread.firstMatch(in: line, range: range) == nil, "\(at) calls Gmail with a path the test can't read")
                guard let match = literal.firstMatch(in: line, range: range), let path = Range(match.range(at: 1), in: line) else { continue }
                // PageHandle.call runs a page script, not a Gmail request.
                if line[path].hasPrefix("return ") { continue }
                let bare = String(line[path]).replacingOccurrences(of: #"\\\([^)]*\)"#, with: "x", options: .regularExpression)
                let verb = method.firstMatch(in: line, range: range).flatMap { Range($0.range(at: 1), in: line) }.map { String(line[$0]) } ?? "GET"
                out.append((bare, verb, at))
            }
        }
        return out
    }
}
