import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// Which Mac work goes to, and what the phone says while that Mac is down
/// (docs/mac-asleep-status.md): the chat's wait row asleep, Yab closed,
/// silent, another Mac up, ten hours on, expired; the Chats card; a new
/// chat's line and the + menu's Mac row and page; Open on Mac with one Mac
/// and two; its toast; Settings › Sync.
extension StateCatalog {
    static let macWait: [NamedState] = [
        NamedState("mac.asleep", "Mac asleep: line", "“MacBook Pro is asleep · since 18:52”, under it “It starts when it wakes.”") { app in
            await waitingChat(app, .asleep(since: at1852))
        },
        NamedState("mac.closed", "Yab closed: line", "“Yab is closed on MacBook Pro · since 18:52”, “It starts when Yab opens.”") { app in
            await waitingChat(app, .closed(since: at1852))
        },
        NamedState("mac.silent", "Mac silent: line", "“No word from MacBook Pro · since 18:52”, “It starts when it’s back.”") { app in
            await waitingChat(app, .silent(since: at1852))
        },
        NamedState("mac.other", "Another Mac online", "The line and an “Ask on Mac mini” button.") { app in
            await waitingChat(app, .asleep(since: at1852), other: true)
        },
        NamedState("mac.expires", "Tenth hour waiting", "A second line: “Expires at … if it’s still asleep.”") { app in
            await waitingChat(app, .asleep(since: at1852), sentAgo: 10.5 * 3600)
        },
        NamedState("mac.expired", "Expired", "In red, “Expired before MacBook Pro received it”, Send Again under it.") { app in
            await waitingChat(app, .asleep(since: at1852), expired: true)
        },
        NamedState("mac.chats", "Chats: chat waiting", "The Quiet cafés card: “Waits for MacBook Pro”.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852))])
            app.chats.update("cafe") { chat in
                chat.messages.append(Message(role: .you, text: "and one that opens at 7?", mac: Message.MacWait(send: "stand-in")))
                chat.messages.append(Message(role: .wait, text: MacWords.waiting("MacBook Pro", .asleep(since: at1852), sent: Date(), now: Date()) ?? "",
                                             by: .claude, mac: Message.MacWait(send: "stand-in", name: "MacBook Pro")))
            }
            NewTabPager.shared.startAt = NewTabPager.chatsPage
            app.field.openSpaces()
        },
        NamedState("mac.newline", "New chat: Mac asleep", "Over the field: “MacBook Pro is asleep · it starts when it wakes”.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852), used: 0), mac("mini", "Mac mini", .asleep(since: at1852), used: 3600)])
            app.newChat()
            try? await Task.sleep(for: .milliseconds(700))
        },
        NamedState("mac.attach", "Tray: Mac row", "Under Reasoning: Mac · Mac mini.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852), used: 0), mac("mini", "Mac mini", .up, used: 600)])
            app.newChat()
            try? await Task.sleep(for: .milliseconds(600))
            app.openAttachTray()
            try? await Task.sleep(for: .milliseconds(800))
        },
        NamedState("mac.attach.macs", "Tray: Mac picker", "Mac mini with a checkmark and Up, MacBook Pro and Asleep since 18:52.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852), used: 0), mac("mini", "Mac mini", .up, used: 600)])
            app.newChat()
            try? await Task.sleep(for: .milliseconds(600))
            app.openAttachTray()
            try? await Task.sleep(for: .milliseconds(300))
            app.attachTrayPage(.mac)
            try? await Task.sleep(for: .milliseconds(800))
        },
        NamedState("mac.menu", "Open on Mac: asleep", "The caption “MacBook Pro · asleep”.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852))])
            openPageMenu(app)
        },
        NamedState("mac.menu.two", "Open on Mac: two Macs", "The caption “Mac mini” and an arrow: the list of Macs.") { app in
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852), used: 0), mac("mini", "Mac mini", .up, used: 600)])
            openPageMenu(app)
        },
        NamedState("mac.toast", "Toast: Mac asleep", "“MacBook Pro is asleep. Opens when it wakes.”") { app in
            app.surfaces.showToast(MacWords.sentToast("MacBook Pro", .asleep(since: at1852)), glyph: .macbook)
        },
        NamedState("mac.toast.task", "Toast: Yab closed", "“Open Yab on MacBook Pro to run tasks”") { app in
            app.surfaces.showToast(MacWords.closedForTasks("MacBook Pro"), glyph: .macbook)
        },
        NamedState("mac.sync", "Settings › Sync: asleep", "MacBook Pro: Asleep since 18:52.") { app in
            SyncStates.devices(app)
            macs(app, [mac("mac", "MacBook Pro", .asleep(since: at1852))])
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.sync)
        },
        NamedState("mac.sync.closed", "Settings › Sync: Yab closed", "MacBook Pro: Yab closed since Tue.") { app in
            SyncStates.devices(app)
            macs(app, [mac("mac", "MacBook Pro", .closed(since: Date().addingTimeInterval(-3 * 86_400)))])
            app.surfaces.openSettings()
            SettingsUI.shared.openPage(.sync)
        },
    ]

    /// Today at 18:52, the prototype's time a Mac went to sleep.
    private static var at1852: Date {
        Calendar.current.date(bySettingHour: 18, minute: 52, second: 0, of: Date()) ?? Date()
    }

    @MainActor private static func mac(_ id: String, _ name: String, _ state: MacState, used: TimeInterval = 0) -> SyncMac {
        SyncMac(id: id, name: name, model: "Mac16,1", lastSeen: state.since ?? Date(), online: state.isUp, front: nil,
                state: state, usedAt: Date().addingTimeInterval(-3600 * 24 + used))
    }

    @MainActor private static func macs(_ app: AppModel, _ list: [SyncMac]) {
        UserDefaults.standard.removeObject(forKey: MacPick.chosenKey)
        app.sync.pretendMacs(list)
    }

    /// A question waiting for its Mac, the row under it as sync maps it.
    @MainActor private static func waitingChat(_ app: AppModel, _ state: MacState, other: Bool = false,
                                               sentAgo: TimeInterval = 0, expired: Bool = false) async {
        var list = [mac("mac", "MacBook Pro", state)]
        if other { list.append(mac("mini", "Mac mini", .up, used: 600)) }
        macs(app, list)
        app.browser.macAsleep = true
        app.ask("plan a calm saturday", page: nil)
        app.expand()
        try? await Task.sleep(for: .milliseconds(500))
        guard let id = app.chatSheet.chatID else { return }
        let sent = Date().addingTimeInterval(-sentAgo)
        app.chats.update(id) { chat in
            chat.messages.removeAll { $0.role == .wait || $0.role == .typing }
            if let at = chat.messages.lastIndex(where: { $0.role == .you }) {
                chat.messages[at].mac = expired ? nil : Message.MacWait(send: "stand-in")
            }
            if expired {
                chat.messages.append(Message(role: .failed, text: "This question expired before MacBook Pro received it. Send it again.",
                                             mac: Message.MacWait(send: "stand-in", expired: true, name: "MacBook Pro")))
            } else {
                let words = MacWords.waiting("MacBook Pro", state, sent: sent, now: Date()) ?? ""
                chat.messages.append(Message(role: .wait, text: words, by: .claude,
                                             mac: Message.MacWait(send: "stand-in", offerID: other ? "mini" : nil,
                                                                  offerName: other ? "Mac mini" : nil, name: "MacBook Pro")))
            }
        }
        try? await Task.sleep(for: .milliseconds(400))
    }
}
