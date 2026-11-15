import Foundation
import SwiftUI

/// Conservative local trace matching. Page words never become a repair intent;
/// this only offers a user-triggered follow-up in the existing conversation.
enum BoostLearning {
    struct Pattern: Equatable {
        let site: String
        let steps: [String]
    }
    static func pattern(_ items: [ChatItem]) -> Pattern? {
        guard items.contains(where: { $0.kind == .message && $0.state == .done }),
              !items.contains(where: { $0.state == .failed }) else { return nil }
        let clicks = items.filter { $0.kind == .tool && $0.state == .done && $0.name == "press" && !$0.detail.hasPrefix("keys:") }
        guard clicks.count >= 2, let first = clicks.first, let site = first.page?.host,
              BoostPackage.host(site) != nil else { return nil }
        let start = Array(clicks.prefix(2))
        guard start.allSatisfy({ $0.page?.host == site && !$0.detail.isEmpty && !$0.detail.hasPrefix("tab:") }),
              start[0].detail != start[1].detail else { return nil }
        return Pattern(site: site, steps: start.map(\.detail))
    }
    static func repeated(in chat: Chat, history: [Chat]) -> String? {
        guard chat.state == "done", let last = chat.turns.last, let pattern = pattern(last) else { return nil }
        let turns = history.filter { $0.state == "done" && $0.id != chat.id }.prefix(100).flatMap(\.turns) + chat.turns
        return turns.filter { Self.pattern($0) == pattern }.count >= 3 ? pattern.site : nil
    }
    static let prompt = "Turn the repeatable browser work in this chat into a plugin tool. Read skill('boosts'). Use the existing trace as reference, define a narrow schema, declare acts for every write, add checks and evals.yaml, and test the read-only path in your own tab. Propose the plugin with boost; I will review Keep. Never replay a previous Send, Pay or Delete while testing."
}

struct BoostLearningView: View {
    let chat: Chat
    let live: Bool
    @State private var site: String?
    var body: some View {
        Group {
            if !live, let site {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Similar steps on \(site) have run three times. Save them as a tool?")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Button("Save as Tool…") { Agents.shared.followUp(chat.id, BoostLearning.prompt) }
                }
            }
        }
        .task(id: chat.updated) {
            let allowed = !live && !Boosts.shared.safeMode && Agents.shared.session(chat.id)?.boostOrigin == nil
            site = allowed ? BoostLearning.repeated(in: chat, history: Chats.shared.all) : nil
        }
    }
}
