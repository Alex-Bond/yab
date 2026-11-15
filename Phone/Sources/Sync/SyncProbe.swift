import Foundation
import os
#if canImport(SyncKit)
import SyncKit
#endif

/// The app's side of the end-to-end check (Phone/tools/sync-e2e): with
/// `-YabSyncProbe 1` the app writes what sync did, one line each with the
/// wall clock in milliseconds, to Library/Caches/yab-sync-probe/events.log,
/// and does what the check writes into commands there, the way the column
/// would (close a row, Clear, open a tab). The check runs on the same Mac
/// as the simulator, so both clocks are one. Test runs only.
@MainActor
final class SyncProbe {
    let folder: URL
    private weak var bridge: SyncBridge?
    private weak var app: AppModel?
    private var timer: Timer?
    private var done = 0
    /// The Mac the check named (`target`), else the first.
    private var target: String?
    private var targetMac: SyncMac? { target.flatMap { id in bridge?.macs.first { $0.id == id } } ?? bridge?.macs.first }
    /// What the check's "back" and "front" said: the app stays in front in
    /// the simulator, so a push woken "in the back" knows to close again.
    private(set) var inFront = true
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "sync-probe")

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> SyncProbe? {
        guard let i = arguments.firstIndex(of: "-YabSyncProbe"), i + 1 < arguments.count, arguments[i + 1] != "0",
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return SyncProbe(folder: caches.appendingPathComponent("yab-sync-probe", isDirectory: true))
    }

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data().write(to: folder.appendingPathComponent("events.log"))
        // Commands of an earlier launch are not this one's.
        try? Data().write(to: folder.appendingPathComponent("commands"))
    }

    func attach(_ bridge: SyncBridge, app: AppModel) {
        self.bridge = bridge
        self.app = app
        say("launched", app.world.name)
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// One line: `<ms> <event> <detail>`.
    func say(_ event: String, _ detail: String) {
        let line = String(format: "%.1f %@ %@\n", Date().timeIntervalSince1970 * 1000, event, detail)
        let url = folder.appendingPathComponent("events.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        log.debug("\(line, privacy: .public)")
    }

    /// Another device's changes, once the app's stores have them.
    func heard(_ batch: SyncBatch, ids: IDs) {
        for change in batch.changes {
            switch change {
            case let .tab(tab): say("tab+", "\(tab.id) \(tab.space) \(tab.list) \(tab.url) \(tab.title)")
            case let .tabGone(id): say("tab-", id)
            case let .message(item): say("message", "\(item.chat) \(item.kind)")
            case let .send(send): say("send", "\(send.id) \(send.state)")
            default: continue
            }
        }
        if let app { rows(app) }
    }

    /// Every space's rows, one line each.
    func rows(_ app: AppModel) {
        for space in app.browser.spaces { say("row", row(of: space)) }
    }

    /// A space's rows in words, for the check to compare.
    func row(of space: Space) -> String {
        "\(space.id) pins=\(space.pins.map(\.id).joined(separator: ",")) kept=\(space.keptTabs.map(\.id).joined(separator: ","))"
            + " today=\(space.today.map(\.id).joined(separator: ","))"
    }

    private func poll() {
        guard let app, let text = try? String(contentsOf: folder.appendingPathComponent("commands"), encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count > done else { return }
        for line in lines[done...] {
            done += 1
            run(line, app)
        }
    }

    /// What the check asks, done through the stores as a surface would.
    private func run(_ line: String, _ app: AppModel) {
        let words = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard let verb = words.first else { return }
        let arg = words.count > 1 ? words[1] : ""
        let rest = words.count > 2 ? words[2] : ""
        switch verb {
        case "close": app.browser.close(arg)
        case "clear": app.browser.clearToday(in: arg.isEmpty ? nil : arg)
        case "keep": app.browser.keep(arg)
        case "unkeep": app.browser.unkeep(arg)
        case "select": app.browser.select(arg)
        case "move": app.browser.move(arg, to: rest)
        case "top": app.browser.reorder(arg, to: 0)
        case "space": app.browser.showSpace(arg)
        case "open":
            // open <url> <title>
            let address = SyncMapping.address(arg)
            let host = SyncMapping.host(arg)
            app.browser.open(Tab(id: UUID().uuidString, title: rest.isEmpty ? address : rest, site: SyncMapping.siteName(host),
                                 icon: host, url: address, host: host))
        case "front":
            inFront = true
            bridge?.cameToFront()
        case "back":
            inFront = false
            bridge?.wentToBack()
        case "pushtoken":
            // pushtoken <hex>: as if APNs had given this token.
            var bytes: [UInt8] = []
            var hex = Substring(arg)
            while hex.count >= 2, let byte = UInt8(hex.prefix(2), radix: 16) { bytes.append(byte); hex = hex.dropFirst(2) }
            SyncPush.registered(Data(bytes))
        case "recovery":
            // recovery <the Recovery Key, spaces for dashes or not>
            bridge?.useRecovery(words.dropFirst().joined(separator: " "))
        case "url":
            // url <address>: which tab (and space) has it, for a check
            // that knows the page, not the id the app gave it.
            let address = SyncMapping.address(arg).lowercased()
            let hit = app.browser.spaces.lazy.flatMap { space in space.allTabs.map { (space, $0) } }
                .first { SyncMapping.address(SyncMapping.fullURL($0.1.address)).lowercased() == address }
            say("url", hit.map { "\($0.1.id) \($0.0.id) \(arg)" } ?? "none \(arg)")
            return
        case "row": break
        case "spaces":
            // spaces: the public spaces' names, in order (one Personal, row 361).
            say("spaces", app.browser.spaces.filter { !$0.isPrivate }.map(\.name).joined(separator: "|"))
            return
        case "tabs":
            // tabs: each public space's tabs, "Name=url,url|Name=…" (row 385).
            say("tabs", app.browser.spaces.filter { !$0.isPrivate }.map { space in
                space.name + "=" + space.allTabs.filter { !$0.isPrivate }.compactMap(\.url).joined(separator: ",")
            }.joined(separator: "|"))
            return
        case "newspace":
            // newspace <name>: a space made here, as Settings › Spaces makes one.
            _ = app.browser.createSpace(name: words.dropFirst().joined(separator: " "), emoji: "🧳",
                                        look: SpaceLook(color: RGB(168, 195, 160)))
        case "rename":
            // rename <name>: the space in front renamed.
            app.browser.setSpace(app.browser.spaceID, name: words.dropFirst().joined(separator: " "))
        case "live":
            // live <url> [space name]: a page opened as the field opens one
            // (a live tab's own id, not a UUID), in that space or the one in front.
            guard let url = URL(string: arg) else { return }
            let space = rest.isEmpty ? nil : app.browser.spaces.first { !$0.isPrivate && $0.name == rest }?.id
            app.browser.open(PageFixtures.liveTab(for: url), in: space)
        case "keepurl":
            // keepurl <url>: the tab at that address kept.
            guard let tab = app.browser.spaces.flatMap(\.allTabs).first(where: { $0.url == arg }) else { return }
            app.browser.keep(tab.id)
        case "settings":
            // settings <page>: Settings open at that page, for a picture of it.
            guard let page = SettingsPageID(rawValue: arg) else { return }
            SettingsUI.shared.openedAt = .page(page)
            SettingsUI.shared.navigation = [.page(page)]
            app.surfaces.openSettings()
        case "caps":
            // caps: what the first Mac takes from this iPhone, as the app reads it.
            guard let engine = bridge?.engine, let mac = targetMac else { say("caps", "none"); return }
            say("caps", "open=\(engine.canOpen(on: mac.id)) agent=\(engine.canStartAgent(on: mac.id))"
                + " task=\(engine.readOnlyTaskEpoch(on: mac.id) != nil)"
                + " login=\(engine.opensAtLogin(mac.id))")
            return
        case "openmac":
            // openmac <tab id>: Open on Mac, as the page menu does.
            guard let tab = app.browser.tab(arg) else { say("openmac", "none \(arg)"); return }
            bridge?.openOnMac(tab, quietly: true, on: target)
        case "ask":
            // ask <claude|codex> <words>: a new chat on the first Mac, with that agent.
            guard let engine = bridge?.engine, let mac = targetMac else { say("asked", "none"); return }
            do {
                let send = try engine.startChat(rest, on: mac.id, agent: ChatAgent(rawValue: arg))
                say("asked", send.id)
            } catch {
                say("asked", "failed \(error.localizedDescription)")
            }
            return
        case "task":
            // task <words>: a read-only task for the first Mac, from the space in front.
            let text = words.dropFirst().joined(separator: " ")
            guard let engine = bridge?.engine, let mac = targetMac,
                  let space = bridge?.syncSpace(app.browser.spaceID) else { say("task", "none"); return }
            guard let epoch = engine.readOnlyTaskEpoch(on: mac.id) else { say("task", "unoffered"); return }
            do {
                let request = try engine.sendReadOnlyTaskRecord(text, on: mac.id, origin: .init(space: space, isPrivate: false), epoch: epoch)
                say("task", request.id)
            } catch {
                say("task", "failed \(error)")
            }
            return
        case "target":
            // target <Mac id>: which Mac openmac, ask, task and caps address
            // (two Macs of one person have one name, and their order is the ids').
            target = arg.isEmpty ? nil : arg
            say("target", arg)
            return
        case "devices":
            // devices: the account's devices as Settings › Sync lists them.
            let words = SettingsDevice.list(bridge?.devices ?? [], own: bridge?.ownDevice, now: Date())
            for device in words { say("device", "\(device.id) \(device.isPhone ? "iphone" : "mac") \(device.words) \(device.name)") }
            say("devices", "\(words.count)")
            return
        case "scan":
            // scan <what the camera read>: Scan QR, as if it read that.
            let ok = bridge?.joinWithInvite(words.dropFirst().joined(separator: " ")) ?? false
            say("scan", ok ? "ok" : "refused")
            return
        case "turnoff":
            // turnoff: Turn Off Sync on This iPhone, its question answered.
            bridge?.turnOff()
            say("turnoff", bridge?.phase == .off ? "off" : "still on")
            return
        case "typing":
            // typing 1|0: as if the keyboard were up (a page from the Mac waits).
            bridge?.pretendTyping(arg == "1")
            say("typing", arg)
            return
        case "now":
            // now: what the Now line says, and the chip of a page from the
            // Mac (a task's line stands before it on the Now line).
            say("now", app.nowItem.map { "\($0.kind.rawValue) \($0.title): \($0.subtitle)" } ?? "none")
            say("card", app.tasks.arrived.map { NowItem.arrived($0).chip?.words ?? "" } ?? "none")
            return
        case "tapnow":
            // tapnow: the Now line's Open, as a finger on it.
            app.tapNow(action: app.nowItem?.action, from: .zero)
        case "tasks":
            // tasks: each task's last word from its Mac.
            for observation in bridge?.engine?.taskRecords() ?? [] {
                say("taskobs", "\(observation.task) \(observation.status.rawValue) \(observation.result ?? observation.progress)")
            }
            return
        case "chatflag":
            // chatflag <chat id> pin|unpin|read|unread|archive|unarchive|title <words>
            guard let engine = bridge?.engine else { say("chatflag", "none"); return }
            let flag = rest.split(separator: " ", maxSplits: 1).map(String.init)
            do {
                switch flag.first ?? "" {
                case "pin": try engine.setChat(arg, pinned: true)
                case "unpin": try engine.setChat(arg, pinned: false)
                case "read": try engine.setChat(arg, unread: false)
                case "unread": try engine.setChat(arg, unread: true)
                case "archive": try engine.setChat(arg, archived: true)
                case "unarchive": try engine.setChat(arg, archived: false)
                case "title": try engine.setChat(arg, title: flag.count > 1 ? flag[1] : "")
                default: say("chatflag", "unknown \(rest)"); return
                }
                say("chatflag", "\(arg) \(rest) supported=\(engine.canSetChat(arg))")
            } catch {
                say("chatflag", "failed \(error)")
            }
            return
        case "approvals":
            // What the approval tray shows now, as one line of JSON.
            say("approval", Self.trayState())
            return
        case "approve":
            // approve card <id> | place <id> | addcard <number> <MM/YY> <name…> | addplace <street>|<city>|<zip>
            //         | yes | no | account <user>: as a finger would in the tray.
            let tray = ApprovalTray.shared
            let parts = rest.split(separator: " ").map(String.init)
            switch arg {
            case "card": tray.pickCard(rest)
            case "place": tray.pickPlace(rest)
            case "addcard":
                tray.cardForm = .init(number: parts.first ?? "", expires: parts.count > 1 ? parts[1] : "",
                                      csc: "", name: parts.dropFirst(2).joined(separator: " "))
                tray.saveCard()
            case "addplace":
                let fields = rest.split(separator: "|").map(String.init)
                tray.placeForm = .init(name: "Probe", street: fields.first ?? "", apt: "", city: fields.count > 1 ? fields[1] : "",
                                       postal: fields.count > 2 ? fields[2] : "")
                tray.savePlace()
            case "yes": tray.yes()
            case "no": tray.no()
            case "account": tray.yes(account: rest)
            default: say("approve", "unknown \(arg)"); return
            }
            say("approved", "\(arg) \(rest)")
            return
        default:
            say("unknown", line)
            return
        }
        // The bridge writes once the change is whole; the line says when.
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.bridge?.flushLocal()
            self?.say("did", line)
            self?.rows(app)
        }
    }
}

extension SyncProbe {
    /// The tray as the person sees it: which question, what it's about,
    /// what is picked, what came of a yes.
    static func trayState() -> String {
        let tray = ApprovalTray.shared
        var out: [String: Any] = ["up": tray.isUp, "phase": "\(tray.phase)", "step": "\(tray.step)", "foot": tray.footLine]
        if let request = tray.request { out["id"] = request.id; out["title"] = request.title }
        if let content = tray.content {
            out["kind"] = "\(content.kind)"
            out["verb"] = content.verb
            out["name"] = content.name
            out["question"] = content.question ?? ""
            out["items"] = content.items.count
            out["bcc"] = content.items.compactMap { $0.mail?.bcc?.count }.reduce(0, +)
            out["files"] = content.files.count + content.items.reduce(0) { $0 + ($1.mail?.files.count ?? 0) }
            if let pay = content.pay {
                out["amount"] = pay.amount
                out["cards"] = pay.cards.map { ["id": $0.id, "last4": $0.last4] }
                out["places"] = pay.places.map { ["id": $0.id, "line": $0.line] }
            }
        }
        out["card"] = tray.card ?? ""
        out["place"] = tray.place ?? ""
        out["receipt"] = tray.receiptWords ?? ""
        let data = (try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where the sync key lives on this device, checked (`-YabKeychainProbe 1`,
/// M7 step 1): the groups `SyncKeychain.standard()` uses, whether a Mac's
/// key is there (and in which group: read only, never shown), and a key of
/// its own written and read back the way joining keeps one, under a service
/// of the probe's so nothing real is touched. The lines go to
/// Library/Caches/yab-keychain-probe.txt and the log.
@MainActor
enum SyncKeychainProbe {
    static func runIfAsked(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let i = arguments.firstIndex(of: "-YabKeychainProbe"), i + 1 < arguments.count, arguments[i + 1] == "1" else { return }
        let standard = SyncKeychain.standard()
        var lines = [
            "own group: \(standard.ownGroup ?? "none")",
            "shared groups: \(standard.sharedGroups.joined(separator: ", "))",
            "writes to: \(standard.writeGroup ?? "the default")",
        ]
        if let found = standard.shared {
            lines.append("a Mac's key: found, in \(found.group ?? "the default group")")
        } else {
            lines.append("a Mac's key: none")
        }
        let probe = SyncKeychain(service: SyncKeychain.macService + " probe", sharedGroups: standard.sharedGroups,
                                 writeGroup: standard.writeGroup, ownGroup: standard.ownGroup)
        probe.forget(everywhere: true)
        let seal = Seal.make()
        probe.keep(seal)
        lines.append("kept here: \(probe.local?.raw == seal.raw ? "read back" : "NOT read back")")
        if let shared = probe.shared {
            lines.append("kept for the Macs: \(shared.seal.raw == seal.raw ? "read back" : "a different key"), in \(shared.group ?? "the default group")")
        } else {
            lines.append("kept for the Macs: NOT read back")
        }
        probe.forget(everywhere: true)
        lines.append("forgotten: \(probe.local == nil && probe.shared == nil ? "yes" : "NO")")
        let text = lines.joined(separator: "\n") + "\n"
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? text.write(to: caches.appendingPathComponent("yab-keychain-probe.txt"), atomically: true, encoding: .utf8)
        }
        Logger(subsystem: "dev.serafim.fast.iphone", category: "sync").notice("keychain probe:\n\(text, privacy: .public)")
    }
}
