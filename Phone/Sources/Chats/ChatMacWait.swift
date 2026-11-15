import SwiftUI

// Words waiting for a Mac that is down: the wait row under them, Don't Send,
// Ask on another Mac and Send Again (docs/mac-asleep-status.md).

extension AppModel {
    /// Don't Send: the words taken back from their Mac and into the field.
    func dontSend(_ message: Message) {
        guard let send = message.mac?.send else { return }
        let sheet = chatSheet
        let words = message.text
        guard isFixture || sync.takeBack(send: send) else { return }
        if isFixture, let id = sheet.chatID {
            chats.update(id) { chat in
                if let at = chat.messages.lastIndex(where: { $0.mac?.send == send && $0.role == .you }) {
                    chat.messages.removeSubrange(at...)
                }
            }
        }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        DispatchQueue.main.async {
            sheet.draft = words
            sheet.focused = true
        }
    }

    /// Ask on Mac mini: the words taken back and asked in a new chat there.
    func askOnOtherMac(_ wait: Message.MacWait) {
        guard let send = wait.send, let other = wait.offerID else { return }
        Haptics.play(.light, reason: Haptics.Reason.confirm)
        sync.askOnOther(send: send, mac: other)
    }

    /// Over a new chat's field: its Mac is down, and the words will wait.
    var newChatMacLine: String? {
        sync.newWorkMac().flatMap { MacWords.beforeSending($0.name, $0.state) }
    }

    /// A new chat's Macs, for the + menu's Mac row: two or more.
    func newChatMacs(_ id: Chat.ID) -> [SyncMac] {
        guard !id.hasPrefix("a:"), !id.hasPrefix("c:"), sync.engineChat(id) == false else { return [] }
        return sync.macs.count > 1 ? sync.macs : []
    }

    /// Picked in the + menu: new work goes to it from now on.
    func pickMac(_ mac: SyncMac) {
        sync.chosenMac = mac.id
        attachTrayPage(.main)
    }

    /// A new chat that asks these words at once: on the Mac a wait row
    /// offered (SyncBridge.chosenMacOnce).
    func newChatAsking(_ words: String) {
        newChat(focus: false)
        DispatchQueue.main.async { [weak self] in self?.send(words) }
    }
}

/// Under words that wait: their Mac by name and why, and another Mac that
/// is up, as a quiet button.
struct MacWaitRow: View {
    @Environment(AppModel.self) private var app
    let message: Message

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            MessageStatus(text: message.text.isEmpty ? "Waits for your Mac" : message.text, failed: false)
            if let wait = message.mac, let name = wait.offerName, wait.offerID != nil {
                Button { app.askOnOtherMac(wait) } label: {
                    Text("Ask on \(name)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 30)
                        .background(ChatInk.fill(0.08), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .accessibilityIdentifier("chat.askOnOtherMac")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Under words that expired before their Mac took them: why, in the red of
/// Not Sent, and Send Again.
struct ExpiredRow: View {
    @Environment(AppModel.self) private var app
    let question: String
    let mac: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            MessageStatus(text: MacWords.expired(mac), failed: true)
            Button { app.send(question) } label: {
                Text("Send Again")
                    .font(.system(size: Metrics.Chat.statusFont, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.trailing, 4)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.sendAgain")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
