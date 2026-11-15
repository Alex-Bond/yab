import AppKit
import LocalAuthentication
import WebKit

/// "Yab unlocks it", for the person: a connected manager whose unlock
/// password Yab keeps (Settings › Passwords) is unlocked for the person
/// behind one Touch ID a Mac session (docs/evidence/manager-unlock-policy-2026-10-13.md).
/// The first time it is locked where the person needs it, Touch ID is asked
/// ("unlock NordPass"); with a yes, Yab types its password into its own
/// unlock page, never shown (ManagerUnlock), and for the rest of the session
/// it does so silently, until the Mac locks or sleeps or Yab quits. With no
/// Touch ID on the Mac, or a no, the manager asks as it always does.
///
/// Where the person needs it:
/// - its popup (its button, a pin, the ⌘E tile) or its own unlock page in a
///   tab shows its lock screen: typed there, so that page shows it unlocked;
/// - a sign-in field takes the caret: checked out of sight, on its unlock page
///   in a page of its own (no tab);
/// - once the session is yes: a page in front showing a sign-in, and again
///   every minute while it stays in front, so a manager that locked itself on
///   its timer is open by the time it's used. These never ask.
///
/// Agents don't go through here: unlock_manager unlocks for a task without
/// Touch ID, one try. One try at a time a manager; a password
/// that didn't work marks its row and stops every try until it is changed.
@MainActor enum ManagerKeep {
    private static var busy: Set<String> = []
    private static var tried: [String: Date] = [:]
    private static weak var front: Tab?
    private static var timer: Timer?
    /// What each manager's last try came to, for the bench.
    private(set) static var last: [String: String] = [:]
    /// What happened, in order, on a test run.
    private(set) static var trace: [String] = []
    private static func note(_ what: String) {
        guard Store.testing else { return }
        trace.append(String(format: "%.1f ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + what)
        if trace.count > 60 { trace.removeFirst() }
    }

    // MARK: - the session's Touch ID

    /// Touch ID given this Mac session: Yab unlocks without asking again.
    private(set) static var approved = false
    /// When the person last said no: a focused field doesn't ask again soon.
    private static var declinedAt: Date?
    private static var asking: [@MainActor (Bool) -> Void] = []
    private static var lockWatch: [NSObjectProtocol] = []
    /// A test run's answer in place of the finger (nil: ask the Mac).
    static var testAnswer: Bool?

    /// Over with the session: the screen locks, the Mac sleeps, the user
    /// switches away. Yab quitting forgets it with the process.
    private static func watchForLock() {
        guard lockWatch.isEmpty else { return }
        let forget: (Notification) -> Void = { _ in MainActor.assumeIsolated { approved = false; tried = [:] } }
        let workspace = NSWorkspace.shared.notificationCenter
        lockWatch = [
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: forget),
        ]
    }

    /// A new session, as after the Mac locked: Touch ID asked again, and
    /// the next sign-in checked at once.
    static func forgetSession() {
        approved = false
        declinedAt = nil
        tried = [:]
    }

    /// Whether Yab may unlock `id` for the person now: already yes this
    /// session, or Touch ID asked when `mayAsk`. No Touch ID: no.
    static func permit(_ id: String, mayAsk: Bool) async -> Bool {
        note("permit approved \(approved) mayAsk \(mayAsk)")
        if approved { return true }
        guard mayAsk else { return false }
        return await withCheckedContinuation { done in
            asking.append { done.resume(returning: $0) }
            guard asking.count == 1 else { return }
            ask(PasswordManagers.name(id))
        }
    }

    private static func answer(_ yes: Bool) {
        if yes { approved = true; declinedAt = nil } else { declinedAt = Date() }
        let waiting = asking
        asking = []
        waiting.forEach { $0(yes) }
    }

    private static func ask(_ name: String) {
        watchForLock()
        if Store.testing, let testAnswer { answer(testAnswer); return }
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &trouble) else { answer(false); return }
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock \(name)") { ok, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { answer(ok) } }
        }
    }

    // MARK: - unlocking

    /// The connected managers Yab may unlock for the person: its password
    /// kept, its extension on with an unlock page, and not 1Password, whose
    /// app holds its lock.
    static var kept: [String] {
        let connections = PasswordManagers.Connections.shared
        let on = PasswordManagers.extensionsOn
        return connections.list.map(\.provider).filter {
            on.contains($0) && connections.row($0) == .yabUnlocks && PasswordManagers.yabMayUnlock($0)
                && PasswordManagers.provider($0)?.unlockPage != nil
        }
    }

    /// Being unlocked for the person right now (Yab's list spins for it).
    static func unlocking(_ id: String) -> Bool { busy.contains(PasswordManagers.canonical(id)) }

    /// The kept manager an extension page belongs to.
    static func manager(of url: URL?) -> String? {
        guard let url, url.scheme?.hasSuffix("-extension") == true, let host = url.host() else { return nil }
        return kept.first { id in
            PasswordManagers.installed(id).flatMap { Extensions.here.contexts[$0.id] }?.baseURL.host() == host
        }
    }

    private static func secret(_ id: String) -> String? {
        guard kept.contains(id), case .found(let text) = ManagerUnlock.fetch(id) else { return nil }
        return text
    }

    static func settle(_ id: String, _ outcome: ManagerUnlock.Outcome, _ why: String) {
        if outcome == .unlocked { ManagerUnlock.nudge() }
        switch outcome {
        case .unlocked: PasswordManagers.Connections.shared.unlocked(id, ok: true)
        case .notUnlocked: PasswordManagers.Connections.shared.unlocked(id, ok: false)
        case .noField, .notRunning: break
        }
        last[id] = "\(why): \(outcome)"
        note("settled \(why): \(outcome)")
    }

    /// Its popup or its own page, as it loads: its lock screen, if it shows
    /// one within a few seconds, unlocked right there, Touch ID first the
    /// first time this session.
    static func inPlacePage(_ page: any PageHandle, url: URL?) {
        guard manager(of: url) != nil,
              let web = WebKitOnly.page(page, for: "Legacy password-manager unlock") else { return }
        inPlace(web, url: url)
    }

    static func inPlace(_ web: WKWebView, url: URL?) {
        guard let id = manager(of: url), !busy.contains(id) else { return }
        busy.insert(id)
        Task { @MainActor [weak web] in
            defer { busy.remove(id) }
            guard let web, await ManagerUnlock.lockScreen(web, seconds: 6) else { return }
            guard await permit(id, mayAsk: true) else { last[id] = "in place: not allowed"; return }
            guard let secret = secret(id) else { return }
            settle(id, await ManagerUnlock.enter(secret, into: web), "in place")
        }
    }

    /// Each kept manager checked out of sight and unlocked when locked, at
    /// most once in `every` seconds; Touch ID asked only when `mayAsk`.
    static func behind(_ why: String, every: TimeInterval, mayAsk: Bool) {
        for id in kept {
            if busy.contains(id) { note("\(why): busy"); continue }
            if let at = tried[id], Date().timeIntervalSince(at) < every { note("\(why): tried \(Int(Date().timeIntervalSince(at))) s ago"); continue }
            tried[id] = Date()
            busy.insert(id)
            Task { @MainActor in
                defer { busy.remove(id) }
                let outcome = await ManagerUnlock.hidden(id) {
                    await permit(id, mayAsk: mayAsk) ? secret(id) : nil
                }
                settle(id, outcome, why)
            }
        }
    }

    /// A page of yours shows a sign-in (`focused`: its field took the caret).
    /// Before the session's yes, only a focused field asks, and not again for
    /// ten minutes after a no.
    static func signIn(_ tab: Tab, focused: Bool) {
        note("sign-in focused \(focused) bench \(tab.bench) kept \(kept.count) busy \(busy.count) tried \(tried.count)")
        guard !tab.bench, !tab.shy, !kept.isEmpty else { return }
        let mayAsk = focused && (declinedAt.map { Date().timeIntervalSince($0) > 600 } ?? true)
        guard approved || mayAsk else { return }
        front = tab
        behind(focused ? "field" : "page", every: focused ? 15 : 30, mayAsk: mayAsk)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { stillThere() }
        }
    }

    /// Every minute: the sign-in page still in front of someone, and the
    /// managers checked again, silently and only after the session's yes;
    /// otherwise the clock stops.
    private static func stillThere() {
        guard let tab = front, !kept.isEmpty, let window = tab.builtPage?.window, window.isVisible, window.identifier != Bench.roomID else {
            timer?.invalidate()
            timer = nil
            front = nil
            return
        }
        guard approved, NSApp.isActive, window.isKeyWindow else { return }
        tab.page.run("!!document.querySelector('input[type=password],input[type=email],input[autocomplete~=username]')") { result in
            MainActor.assumeIsolated {
                if (try? result.get()) as? Bool == true { behind("in front", every: 55, mayAsk: false) }
            }
        }
    }
}
