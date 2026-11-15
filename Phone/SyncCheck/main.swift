import Foundation
import SyncKit

// Phone/SyncCheck: the iPhone's sync engine against a Mac's, run on a Mac
// (adhd, through the farm: Phone/SyncCheck/run.sh).
//
//   synccheck live URL     a "Mac" (SyncClient + the Mac's SyncShapes) and
//                          the iPhone engine (PhoneSync) on one new account
//                          on a local sync server: tabs, chats, words for a
//                          Mac, presence, offline, relaunch, pairing; timings.
//
// The records' fields need no comparing: both devices write and read them
// through SyncKit's Shapes.swift and ChatShapes.swift, and
// Tests/FastTests/SyncWireTests.swift holds the Mac's to their bytes.

setvbuf(stdout, nil, _IOLBF, 0)
var failures = 0

func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("  ok    \(what)") } else { failures += 1; print("  FAIL  \(what) \(detail())") }
}

let canonical: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return e
}()

func json<T: Encodable>(_ value: T) -> String { String(data: try! canonical.encode(value), encoding: .utf8)! }

/// The two collections differ: where, readably.
func diff(_ a: [String: [String: Value]], _ b: [String: [String: Value]]) -> String {
    var out: [String] = []
    for id in Set(a.keys).union(b.keys).sorted() {
        guard let x = a[id] else { out.append("only iPhone: \(id)"); continue }
        guard let y = b[id] else { out.append("only Mac: \(id)"); continue }
        for field in Set(x.keys).union(y.keys).sorted() where x[field] != y[field] {
            out.append("\(id).\(field): Mac \(x[field].map(json) ?? "absent") iPhone \(y[field].map(json) ?? "absent")")
        }
    }
    return out.prefix(12).joined(separator: "; ")
}

func same(_ what: String, mac: [String: [String: Value]], phone: [String: [String: Value]]) {
    let x = json(mac), y = json(phone)
    check(x == y, "\(what): \(mac.count) records, \(x.utf8.count) bytes identical", diff(mac, phone))
}

/// Records as a device writes them, with one fixed clock: what is sealed
/// and sent, byte for byte.
func records(_ collection: String, _ c: [String: [String: Value]], at wall: Int64 = 1_759_700_000_000) -> [Record] {
    let clock = Clock(device: "check", now: { wall })
    return c.keys.sorted().map { id in
        var record = Record(collection: collection, id: id)
        record.update(to: c[id]!, clock: clock)
        return record
    }
}

func t(_ minutesAgo: Double) -> Double { 1_759_700_000 - minutesAgo * 60 + 17.4 }

// MARK: - Live

/// A value set from another queue.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

final class Waiter: @unchecked Sendable {
    private let lock = NSLock()
    func until(_ seconds: Double = 15, _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if lock.withLock({ done() }) { return true }
            usleep(2_000)
        }
        return lock.withLock { done() }
    }
}

/// Things heard, with when.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Date, SyncChange, SyncBatch.Origin)] = []
    private var macRecords: [(Date, Record)] = []
    func add(_ batch: SyncBatch) { lock.withLock { items += batch.changes.map { (Date(), $0, batch.origin) } } }
    func add(_ records: [Record]) { lock.withLock { macRecords += records.map { (Date(), $0) } } }
    func first(_ match: (SyncChange) -> Bool) -> Date? { lock.withLock { items.first { $0.2 == .remote && match($0.1) }?.0 } }
    func macFirst(_ match: (Record) -> Bool) -> Date? { lock.withLock { macRecords.first { match($0.1) }?.0 } }
    var remoteCount: Int { lock.withLock { items.filter { $0.2 == .remote }.count } }
    func clear() { lock.withLock { items = []; macRecords = [] } }
}

func ms(_ from: Date, _ to: Date?) -> Double { to.map { $0.timeIntervalSince(from) * 1000 } ?? .infinity }

func stats(_ name: String, _ values: [Double]) {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return print("  \(name): none") }
    let p = { (q: Double) in sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))] }
    print(String(format: "  timing  %@: n=%d p50 %.1f ms, p95 %.1f ms, min %.1f, max %.1f", name, sorted.count, p(0.5), p(0.95), sorted.first!, sorted.last!))
}

/// The "Mac": SyncKit's client with the Mac's own SyncShapes, keeping its
/// spaces and rows the way SyncCenter does (reconcile after a write, rows
/// rebuilt from the journal after something came).
final class FakeMac: @unchecked Sendable {
    let journal: Journal
    let client: SyncClient
    let id: String
    var spaces: [Space] = []
    var rows: [UUID: Session.Shape] = [:]
    var chats: [String: Chat] = [:]
    let heard: Heard
    let lock = NSLock()
    var front: (url: String, title: String, tab: String)?

    init(base: URL, seal: Seal, folder: URL, id: String, heard: Heard) throws {
        self.id = id
        self.heard = heard
        journal = try Journal(path: folder.appendingPathComponent("\(id).sqlite").path, device: id)
        client = SyncClient(base: base, journal: journal, seal: seal, device: .init(id: id, name: "Test Mac \(id)", model: "Mac15,3"))
        // As SyncCenter does: merged and written into the row in one step,
        // so a flush can't read the row in between and take what just came
        // for something closed here.
        client.deliver = { [weak self] items in
            guard let self else { return }
            self.lock.withLock {
                guard let changed = try? self.journal.receive(items), !changed.isEmpty else { return }
                heard.add(changed)
                self.adopt(changed)
            }
        }
        client.presence = { [weak self] in
            guard let self else { return nil }
            var fields: [String: Value] = ["name": .string("Test Mac \(id)"), "at": .number(Date().timeIntervalSince1970)]
            if let front = self.front { fields["url"] = .string(front.url); fields["title"] = .string(front.title); fields["tab"] = .string(front.tab) }
            return Record(collection: "presence", id: id, fields: fields)
        }
    }

    /// SyncCenter.adopt, for rows: what came is written into the row.
    private func adopt(_ records: [Record]) {
        guard records.contains(where: { ["tab", "folder", "pair"].contains($0.collection) }) else { return }
        let tabs = journal.all("tab"), folders = journal.all("folder"), pairs = journal.all("pair")
        for space in spaces {
            rows[space.id] = SyncShapes.row(space.id, tabs: tabs, folders: folders, pairs: pairs, here: rows[space.id] ?? Session.Shape(tabs: [], active: 0))
        }
    }

    /// SyncCenter.flush: what the files say now, told to the journal.
    @discardableResult
    func flush() throws -> [Record.Key] {
        try lock.withLock {
            func orders(_ c: String) -> [String: String] {
                Dictionary(journal.living(c).compactMap { r in r["order"]?.string.map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
            }
            var changed = try journal.reconcile("space", SyncShapes.spaces(spaces, orders: orders("space")))
            let out = SyncShapes.rows(rows, orders: orders("tab"))
            changed += try journal.reconcile("tab", out.tabs)
            changed += try journal.reconcile("folder", out.folders)
            changed += try journal.reconcile("pair", out.pairs)
            var heads: [String: [String: Value]] = [:], items: [String: [String: Value]] = [:]
            for (key, chat) in chats {
                heads[key] = SyncChats.head(chat, kind: "agent", device: id)
                items.merge(SyncChats.items(chat, record: key)) { a, _ in a }
            }
            changed += try journal.reconcile("chat", heads, within: { [id] in $0.fields["device"]?.string == id })
            changed += try journal.reconcile("chatitem", items, within: { ($0.fields["chat"]?.string ?? "").hasPrefix("a:") })
            client.kick()
            return changed
        }
    }

    func row(_ space: UUID) -> Session.Shape { lock.withLock { rows[space] ?? Session.Shape(tabs: [], active: 0) } }
    func edit(_ body: (FakeMac) -> Void) { lock.withLock { body(self) } }
}

func live(_ base: URL) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yab-sync-check-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    SyncShapes.register()
    let wait = Waiter()
    let seal = Seal.make()
    let heard = Heard()

    print("== joining")
    // Recovery Key: what the iPhone types back.
    check(Seal(recovery: seal.recovery.lowercased().replacingOccurrences(of: "-", with: " "))?.raw == seal.raw, "the Recovery Key typed back opens the account")

    let mac = try FakeMac(base: base, seal: seal, folder: scratch, id: "mac-a", heard: heard)
    let work = UUID(uuidString: "6A1E4F0C-3B2D-4F77-9C1A-0E5D2B7A9F10")!
    mac.edit { m in
        m.spaces = [Space(id: UUID(uuidString: SyncCollection.firstSpace)!, name: "Personal", icon: "🏠", ownSignIns: false),
                    Space(id: work, name: "Work", icon: "💼", ownSignIns: true)]
        m.rows[work] = Session.Shape(tabs: [
            Session.Entry(url: "https://mail.google.com/", title: "Inbox", pin: "M", seen: t(1), id: "AAAAAAAA-0000-4000-8000-000000000001"),
            Session.Entry(url: "https://github.com/me/yab/pull/12", title: "PR 12", kept: true, folder: "F0000000-0000-4000-8000-000000000001",
                          folderName: "Pull requests", folderOpen: true, id: "AAAAAAAA-0000-4000-8000-000000000002"),
            Session.Entry(url: "https://news.ycombinator.com/", title: "Hacker News", seen: t(2), id: "AAAAAAAA-0000-4000-8000-000000000003"),
            Session.Entry(url: "https://figma.com/file/x", title: "Figma", seen: t(3), id: "AAAAAAAA-0000-4000-8000-000000000004"),
        ], active: 2)
        m.chats["a:k3j9x2"] = Chat(id: "k3j9x2", title: "Find a hotel", cli: "claude", model: "opus",
                                   items: [ChatItem(id: "i1", kind: .asked, text: "Find a hotel in Lisbon", state: .done),
                                           ChatItem(id: "i2", kind: .message, text: "Memmo Alfama, 180 € a night.", state: .done)],
                                   state: "done", answer: "Memmo Alfama, 180 € a night.", started: Date(), updated: Date())
    }
    try mac.flush()
    let macStart = Date()
    mac.client.start()
    check(wait.until { mac.client.state == .live }, "the Mac makes the account and is live", "\(mac.client.state)")
    print(String(format: "  timing  Mac register + socket + hello: %.0f ms", ms(macStart, Date())))
    check(wait.until { mac.journal.pending().isEmpty }, "the Mac's \(mac.journal.all("tab").count) tabs went up")

    // The iPhone: the key as iCloud Keychain would bring it.
    let keys = SyncKeychain.testing(folder: scratch.appendingPathComponent("phone-keys"))
    let shared = SyncKeychain.testing(folder: scratch.appendingPathComponent("phone-keys"))
    shared.keep(seal)
    check(keys.shared?.seal.raw == seal.raw, "the iPhone finds the shared key (files standing for iCloud Keychain)")
    let deviceID = keys.deviceID
    check(deviceID == keys.deviceID, "the iPhone's device id is made once")
    let phoneFolder = scratch.appendingPathComponent("phone")
    let callbacks = DispatchQueue(label: "check.callbacks")
    func makePhone() throws -> PhoneSync {
        let phone = try PhoneSync(seal: seal, options: .init(base: base, folder: phoneFolder, device: .init(id: deviceID, name: "Test iPhone", model: "iPhone18,1"),
                                                             callbacks: callbacks), keys: keys)
        phone.onChanges = { heard.add($0) }
        return phone
    }
    var phone = try makePhone()
    let phoneStart = Date()
    phone.start()
    check(wait.until { phone.state == .live }, "the iPhone registers and catches up", "\(phone.state)")
    print(String(format: "  timing  iPhone register + socket + catch-up of %d records: %.0f ms", phone.journal.all("tab").count + phone.journal.all("space").count, ms(phoneStart, Date())))
    check(keys.token != nil, "the iPhone keeps the token the server gave")

    print("== the row")
    let row = phone.row(work.uuidString)
    check(row.pins.map(\.url) == ["https://mail.google.com/"] && row.kept.map(\.url) == ["https://github.com/me/yab/pull/12"]
          && row.today.map(\.url) == ["https://news.ycombinator.com/", "https://figma.com/file/x"],
          "Work's row on the iPhone: 1 pin, 1 kept, 2 today, in the Mac's order", "\(row.all.map(\.url))")
    check(row.folders["F0000000-0000-4000-8000-000000000001"]?.name == "Pull requests" && row.kept.first?.folder == "F0000000-0000-4000-8000-000000000001",
          "the Mac's folder shows on the iPhone with its tab")
    check(phone.spaces().map(\.name) == ["Personal", "Work"], "spaces in the Mac's order", "\(phone.spaces().map(\.name))")
    check(phone.chats().first?.title == "Find a hotel" && phone.messages(in: "a:k3j9x2").map(\.text) == ["Find a hotel in Lisbon", "Memmo Alfama, 180 € a night."],
          "the Mac's chat and its steps are on the iPhone")

    print("== iPhone names and folders through the real Mac mapping")
    let editTab = "AAAAAAAA-0000-4000-8000-000000000002"
    let outer = UUID().uuidString, inner = UUID().uuidString
    _ = try phone.makeFolder(id: outer, name: "Phone research", in: work.uuidString)
    _ = try phone.makeFolder(id: inner, name: "Phone sources", in: work.uuidString, parent: outer)
    try phone.rename(editTab, "Named on iPhone")
    _ = try phone.putInFolder(editTab, folder: inner)
    check(wait.until {
        mac.row(work).tabs.first(where: { $0.id == editTab })?.folder == inner
    }, "phone folder arrives in the real Mac row")
    let edited = mac.row(work).tabs.first { $0.id == editTab }
    check(edited?.name == "Named on iPhone" && edited?.title == "PR 12", "the Mac keeps the page title underneath the phone name")
    check(edited?.folderPath?.map(\.id) == [outer], "the Mac reconstructs the nested parent")
    _ = try phone.renameFolder(inner, in: work.uuidString, to: "References")
    check(wait.until { mac.row(work).tabs.first(where: { $0.id == editTab })?.folderName == "References" }, "folder rename reaches the Mac")
    try phone.rename(editTab, nil)
    _ = try phone.deleteFolder(outer, in: work.uuidString)
    check(wait.until { mac.row(work).tabs.first(where: { $0.id == editTab })?.folderPath == nil }, "deleting a parent promotes the Mac child")
    _ = try phone.deleteFolder(inner, in: work.uuidString)
    check(wait.until { mac.row(work).tabs.first(where: { $0.id == editTab })?.folder == nil }, "deleting the folder leaves its Mac tab alive")
    _ = try phone.putInFolder(editTab, folder: "F0000000-0000-4000-8000-000000000001")
    check(wait.until { mac.row(work).tabs.first(where: { $0.id == editTab })?.folder == "F0000000-0000-4000-8000-000000000001" }, "the original folder can take the tab again")

    print("== Mac to iPhone, live")
    var down: [Double] = []
    for i in 0..<20 {
        let id = String(format: "BBBBBBBB-0000-4000-8000-%012d", i)
        mac.edit { m in m.rows[work]!.tabs.append(Session.Entry(url: "https://example.com/mac/\(i)", title: "From the Mac \(i)", seen: t(0), id: id)) }
        let sent = Date()
        try mac.flush()
        _ = wait.until(5) { heard.first { if case .tab(let tab) = $0 { return tab.id == id }; return false } != nil }
        down.append(ms(sent, heard.first { if case .tab(let tab) = $0 { return tab.id == id }; return false }))
    }
    check(down.allSatisfy { $0.isFinite }, "20 tabs opened on the Mac reached the iPhone")
    stats("Mac opens a tab -> iPhone has it (flush + push + relay + merge)", down)
    check(phone.row(work.uuidString).today.suffix(3).map(\.title) == ["From the Mac 17", "From the Mac 18", "From the Mac 19"], "in the Mac's order, at the end of Today")

    print("== iPhone to Mac, live")
    var up: [Double] = []
    var opened: [SyncTab] = []
    for i in 0..<20 {
        let sent = Date()
        let tab = try phone.openTab(url: "https://example.com/phone/\(i)", title: "From the iPhone \(i)", in: work.uuidString, at: .bottom)
        opened.append(tab)
        _ = wait.until(5) { heard.macFirst { $0.collection == "tab" && $0.id == tab.id } != nil }
        up.append(ms(sent, heard.macFirst { $0.collection == "tab" && $0.id == tab.id }))
    }
    check(up.allSatisfy { $0.isFinite }, "20 tabs opened on the iPhone reached the Mac")
    stats("iPhone opens a tab -> Mac's journal has it", up)
    let macRow = mac.row(work)
    check(macRow.tabs.suffix(20).map(\.title) == (0..<20).map { "From the iPhone \($0)" } && macRow.tabs.suffix(20).allSatisfy { $0.kept != true && $0.pin == nil },
          "the Mac's own row (SyncShapes.row) has them at the end of Today, in order", "\(macRow.tabs.suffix(20).map(\.title))")
    let echo = try mac.flush()
    check(!echo.contains { $0.collection == "tab" }, "the Mac writing its row back changes no tab: the iPhone's keys fit its row", "\(echo)")

    print("== keep, move, close, clear")
    let hn = "AAAAAAAA-0000-4000-8000-000000000003"
    heard.clear()
    try phone.keep(hn, true)
    _ = wait.until { mac.row(work).tabs.first { $0.id == hn }?.kept == true }
    let keptOnMac = mac.row(work)
    check(keptOnMac.tabs.first { $0.id == hn }?.kept == true && keptOnMac.tabs.firstIndex { $0.id == hn } == 2,
          "kept on the iPhone: kept on the Mac, under the other kept tab", "\(keptOnMac.tabs.prefix(4).map(\.title))")
    let last = opened.last!.id
    try phone.move(last, at: .top)
    _ = wait.until { mac.row(work).tabs.first { $0.kept != true && $0.pin == nil }?.id == last }
    check(mac.row(work).tabs.first { $0.kept != true && $0.pin == nil }?.id == last, "moved to the top of Today on the iPhone: first of Today on the Mac")
    let echo2 = try mac.flush()
    check(!echo2.contains { $0.collection == "tab" }, "and the Mac keeps the iPhone's key for it", "\(echo2)")
    let closing = opened[3].id
    let closedAt = Date()
    try phone.closeTab(closing)
    _ = wait.until { !mac.row(work).tabs.contains { $0.id == closing } }
    check(!mac.row(work).tabs.contains { $0.id == closing }, "closed on the iPhone: gone from the Mac's row")
    print(String(format: "  timing  close on iPhone -> gone on Mac: %.0f ms", ms(closedAt, heard.macFirst { $0.id == closing && !$0.alive() })))
    // The Mac closes one of the iPhone's.
    let macCloses = opened[4].id
    mac.edit { m in m.rows[work]!.tabs.removeAll { $0.id == macCloses } }
    let macClosedAt = Date()
    try mac.flush()
    _ = wait.until { heard.first { $0 == .tabGone(macCloses) } != nil }
    check(heard.first { $0 == .tabGone(macCloses) } != nil, "closed on the Mac: gone on the iPhone")
    print(String(format: "  timing  close on Mac -> gone on iPhone: %.0f ms", ms(macClosedAt, heard.first { $0 == .tabGone(macCloses) })))
    // A close beats a move made at the same time elsewhere.
    let race = opened[5].id
    try phone.closeTab(race)
    mac.edit { m in
        if let i = m.rows[work]!.tabs.firstIndex(where: { $0.id == race }) { m.rows[work]!.tabs[i].title = "Renamed on the Mac meanwhile" }
    }
    try mac.flush()
    _ = wait.until { mac.journal.pending().isEmpty && phone.pending == 0 }
    Thread.sleep(forTimeInterval: 0.3)
    check(!mac.row(work).tabs.contains { $0.id == race } && phone.tab(race) == nil, "closed on one side while renamed on the other: closed on both")
    let todayBefore = phone.row(work.uuidString).today.count
    try phone.clearToday(in: work.uuidString)
    _ = wait.until { !mac.row(work).tabs.contains { $0.kept != true && $0.pin == nil } }
    check(!mac.row(work).tabs.contains { $0.kept != true && $0.pin == nil } && mac.row(work).tabs.count == 3,
          "Clear on the iPhone: \(todayBefore) of Today gone on the Mac, the pin and two kept stay", "\(mac.row(work).tabs.map(\.title))")

    print("== words for a Mac")
    heard.clear()
    let said = Date()
    let send = try phone.say("And a cheaper one?", in: "a:k3j9x2")
    _ = wait.until { !SyncChats.waiting(mac.journal.all("send"), device: "mac-a").isEmpty }
    let words = SyncChats.waiting(mac.journal.all("send"), device: "mac-a")
    check(words.count == 1 && words[0].text == "And a cheaper one?" && words[0].chat == "a:k3j9x2", "the Mac hears the words for its chat", "\(words)")
    let heardAt = Date()
    // The Mac says them in the chat (Agents.followUp), its agent answers,
    // and the send is marked taken (SyncCenter.takeSends).
    mac.edit { m in
        m.chats["a:k3j9x2"]!.items += [ChatItem(id: "i3", kind: .asked, text: words[0].text, state: .done),
                                        ChatItem(id: "i4", kind: .message, text: "Casa do Bairro, 110 € a night.", state: .done)]
        m.chats["a:k3j9x2"]!.answer = "Casa do Bairro, 110 € a night."
        m.chats["a:k3j9x2"]!.updated = Date()
    }
    _ = try mac.journal.change(.init(collection: "send", id: send.id), ["took": .number(Date().timeIntervalSince1970), "state": "taken"])
    try mac.flush()
    _ = wait.until { heard.first { if case .send(let s) = $0 { return s.id == send.id && s.state == .taken }; return false } != nil
        && heard.first { if case .message(let m) = $0 { return m.text == "Casa do Bairro, 110 € a night." }; return false } != nil }
    let takenAt = heard.first { if case .send(let s) = $0 { return s.id == send.id && s.state == .taken }; return false }
    let answerAt = heard.first { if case .message(let m) = $0 { return m.text == "Casa do Bairro, 110 € a night." }; return false }
    check(takenAt != nil && answerAt != nil, "the iPhone sees its words taken and the answer as the chat's new step")
    print(String(format: "  timing  iPhone says -> Mac has the send: %.0f ms; Mac answers -> iPhone has it: %.0f ms (no agent: answered at once)",
                 ms(said, heardAt), ms(heardAt, answerAt)))
    check(phone.messages(in: "a:k3j9x2").map(\.kind) == ["asked", "message", "asked", "message"], "the chat on the iPhone: four steps in order")
    let task = try phone.startChat("Book a table for two at 8", on: "mac-a")
    _ = wait.until { SyncChats.waiting(mac.journal.all("send"), device: "mac-a").contains { $0.id == task.id } }
    let newTask = SyncChats.waiting(mac.journal.all("send"), device: "mac-a").first { $0.id == task.id }
    check(newTask?.chat == nil && newTask?.kind == "agent" && newTask?.text == "Book a table for two at 8", "a new task from the iPhone reaches the Mac as one")
    _ = try mac.journal.change(.init(collection: "send", id: task.id), ["took": .number(Date().timeIntervalSince1970), "state": "taken", "chat": "a:new123"])
    mac.client.kick()
    _ = wait.until { phone.sends().first { $0.id == task.id }?.chat == "a:new123" }
    check(phone.sends().first { $0.id == task.id }?.chat == "a:new123" && phone.sends().first { $0.id == task.id }?.state == .taken,
          "and the iPhone learns the chat it started")
    try phone.setChat("a:k3j9x2", pinned: false, unread: false)
    check(phone.chat("a:k3j9x2")?.pinned == false && phone.chat("a:k3j9x2")?.unread == false && phone.journal.pending(limit: 10).allSatisfy { $0.record.collection != "chat" },
          "Pin and Unread kept on the iPhone, not sent while the Mac would undo them")

    print("== presence")
    mac.front = ("https://news.ycombinator.com/", "Hacker News", hn)
    let presenceSent = Date()
    mac.client.sayPresence()
    _ = wait.until { phone.macs.first?.front?.tab == hn }
    check(phone.macs.first?.id == "mac-a" && phone.macs.first?.online == true && phone.macs.first?.front?.tab == hn,
          "the iPhone knows the Mac is online and which tab it has in front", "\(phone.macs)")
    print(String(format: "  timing  Mac presence -> iPhone: %.0f ms", ms(presenceSent, Date())))

    print("== offline, relaunch")
    phone.stop()
    _ = wait.until { phone.state == .off }
    // Stopped stays stopped: a tab the Mac opens now doesn't come down.
    let whileOff = "DDDDDDDD-0000-4000-8000-000000000001"
    mac.edit { m in m.rows[work]!.tabs.append(Session.Entry(url: "https://example.com/while-off", title: "While the iPhone is away", id: whileOff)) }
    try mac.flush()
    Thread.sleep(forTimeInterval: 2.5)
    check(phone.state == .off && phone.tab(whileOff) == nil, "the line stays down after stop: nothing came in 2.5 s", "\(phone.state)")
    let off1 = try phone.openTab(url: "https://example.com/offline/1", title: "Offline 1", in: work.uuidString)
    let off2 = try phone.openTab(url: "https://example.com/offline/2", title: "Offline 2", in: work.uuidString)
    try phone.keep(off2.id, true)
    check(phone.pending == 2, "two changes wait in the journal while the line is down", "\(phone.pending)")
    // Meanwhile the Mac opens 300 tabs.
    mac.edit { m in
        for i in 0..<300 {
            m.rows[work]!.tabs.append(Session.Entry(url: "https://example.com/many/\(i)", title: "Many \(i)", id: String(format: "CCCCCCCC-0000-4000-8000-%012d", i)))
        }
    }
    try mac.flush()
    _ = wait.until { mac.journal.pending().isEmpty }
    let cursorBefore = phone.journal.cursor
    phone = try makePhone()   // a new launch on the same folder
    heard.clear()
    let relaunch = Date()
    phone.start()
    _ = wait.until(20) { phone.state == .live }
    let liveAt = Date()
    _ = wait.until(20) { phone.pending == 0 && mac.row(work).tabs.contains { $0.id == off2.id && $0.kept == true } }
    check(mac.row(work).tabs.contains { $0.id == off1.id } && mac.row(work).tabs.contains { $0.id == off2.id && $0.kept == true },
          "after a relaunch, what was done offline reaches the Mac")
    let tabsHeard = heard.remoteCount
    check(phone.row(work.uuidString).today.filter { $0.title.hasPrefix("Many ") }.count == 300, "and the Mac's 300 new tabs are on the iPhone")
    check(tabsHeard >= 300 && tabsHeard <= 303, "only what changed came down (cursor \(cursorBefore) kept): \(tabsHeard) changes heard")
    print(String(format: "  timing  relaunch -> live with 300 new tabs caught up: %.0f ms; -> offline changes on the Mac: %.0f ms", ms(relaunch, liveAt), ms(relaunch, Date())))

    print("== pause")
    let late = try phone.openTab(url: "https://example.com/last-second", title: "Opened just before leaving", in: work.uuidString)
    let paused = DispatchSemaphore(value: 0)
    let pauseAt = Date()
    phone.pause(within: 5) { paused.signal() }
    check(paused.wait(timeout: .now() + 7) == .success, "pause waits for what is going up, then closes the line")
    print(String(format: "  timing  pause drained in %.0f ms", ms(pauseAt, Date())))
    _ = wait.until(3) { mac.row(work).tabs.contains { $0.id == late.id } }
    check(mac.row(work).tabs.contains { $0.id == late.id }, "the tab opened just before going to the back reached the Mac")

    print("== SyncKit's client after stop()")
    let bare = SyncClient(base: base, journal: try Journal(path: nil, device: "bare"), seal: seal, device: .init(id: "bare", name: "Bare", model: "Mac15,3"))
    let bareStates = Box<[String]>([])
    bare.stateChanged = { state in bareStates.value.append("\(state)") }
    bare.start()
    _ = wait.until { bare.state == .live }
    bare.stop()
    Thread.sleep(forTimeInterval: 3)
    print("  SyncClient.start, live, stop, 3 s later: \(bare.state); states \(bareStates.value.joined(separator: " -> "))")
    bare.stop()

    print("== pairing")
    let pairing = PhonePairing(base: base, every: 0.25)
    let result = Box<Result<Seal, PhonePairing.Failure>?>(nil)
    let pairStart = Date()
    pairing.start { result.value = $0 }
    Thread.sleep(forTimeInterval: 1)
    let answered = Box<Bool?>(nil)
    let typedAt = Date()
    Pairing.answer(code: pairing.code.lowercased(), seal: seal, base: base) { answered.value = $0 }
    _ = wait.until(10) { result.value != nil }
    let pairedAt = Date()
    check(answered.value == true && (try? result.value?.get())?.raw == seal.raw, "a code shown on the iPhone, typed on a Mac: the iPhone has the key", "\(String(describing: result.value))")
    print(String(format: "  timing  code typed on the Mac -> iPhone has the key: %.0f ms (polling every 250 ms); whole flow %.0f ms", ms(typedAt, pairedAt), ms(pairStart, pairedAt)))

    print("== pairing after 45 s (the server's 20 reads)")
    let stock = Joining()
    let stockResult = Box<Seal??>(nil)
    Pairing.ask(stock, base: base, timeout: 120) { stockResult.value = .some($0) }
    let patient = PhonePairing(base: base, every: 2)
    let patientResult = Box<Result<Seal, PhonePairing.Failure>?>(nil)
    patient.start { patientResult.value = $0 }
    Thread.sleep(forTimeInterval: 45)
    let stockAnswered = Box<Bool?>(nil), patientAnswered = Box<Bool?>(nil)
    Pairing.answer(code: stock.code, seal: seal, base: base) { stockAnswered.value = $0 }
    Pairing.answer(code: patient.code, seal: seal, base: base) { patientAnswered.value = $0 }
    _ = wait.until(10) { patientResult.value != nil && stockAnswered.value != nil }
    let stockJoined = stockResult.value.map { $0 != nil } ?? false
    print("  stock Pairing.ask, 2 s polls, code typed at 45 s: Mac's answer \(stockAnswered.value.map { "\($0)" } ?? "none"), joined \(stockJoined)")
    print("  PhonePairing, 2 s polls, code typed at 45 s: Mac's answer \(patientAnswered.value.map { "\($0)" } ?? "none"), joined \((try? patientResult.value?.get()) != nil), box put back \(patient.reposts) times")
    check((try? patientResult.value?.get())?.raw == seal.raw, "PhonePairing still takes a code typed after 45 s")
    pairing.cancel(); patient.cancel()

    phone.stop()
    mac.client.deleteAccount { _ in }
    Thread.sleep(forTimeInterval: 0.5)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "live"?:
    do { try live(URL(string: args.dropFirst().first ?? "http://127.0.0.1:8787")!) } catch { failures += 1; print("  FAIL  live: \(error)") }
default:
    print("usage: synccheck live URL")
    exit(2)
}
print(failures == 0 ? "PASS" : "FAILED: \(failures)")
exit(failures == 0 ? 0 : 1)
