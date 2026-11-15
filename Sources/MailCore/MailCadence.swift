import AppKit
import Network

// How often mail asks Gmail what changed, and the line it asks on
// (docs/mail.md, Sync). Gmail's push needs a server of its own and IMAP's
// IDLE a wider scope than Yab has, so mail asks, and asks cheaply: a
// history.list costs 2 of the 6,000 units a minute Google gives each
// person, over a connection kept open between asks.
//
// The rhythm follows whoever is looking: every 10 seconds with mail in
// front, 15 while Yab is, 30 behind other apps when a notification would
// say what came, five minutes when nothing would, and not at all while the
// Mac sleeps or saves power. Waking, unlocking the screen, the network
// coming back and opening mail ask at once (MailCenter.now).

public enum MailCadence {
    /// One account's view of the Mac, as far as asking goes.
    public struct State: Equatable {
        /// A code box waits for a mailed code (MailCenter.quick).
        public var quick = false
        public var asleep = false
        /// macOS's Low Power Mode.
        var lowPower = false
        /// On a battery at a fifth or less, the rest of what Yab calls
        /// saving power (Thrift).
        var lowBattery = false
        /// Mail's page is in front in its window, even behind another app.
        var mailInFront = false
        /// Yab is the app in front.
        public var active = false
        /// This account's notifications are on and macOS lets Yab show them.
        var notifying = false

        public init(quick: Bool = false, asleep: Bool = false, lowPower: Bool = false, lowBattery: Bool = false, mailInFront: Bool = false, active: Bool = false, notifying: Bool = false) {
            self.quick = quick
            self.asleep = asleep
            self.lowPower = lowPower
            self.lowBattery = lowBattery
            self.mailInFront = mailInFront
            self.active = active
            self.notifying = notifying
        }
    }

    /// Seconds from one ask to the next, or nil for none. A code box
    /// waiting asks every 2 seconds even in Low Power: it lasts two
    /// minutes at most and someone is sitting at it.
    public static func every(_ state: State) -> TimeInterval? {
        if state.asleep { return nil }
        if state.quick { return 2 }
        if state.lowPower { return nil }
        if state.mailInFront { return 10 }
        if state.active { return 15 }
        // Behind other apps, only a notification makes speed worth it, and
        // not on a battery that is nearly out.
        return state.notifying && !state.lowBattery ? 30 : 300
    }

    /// The units of Gmail's quota an hour of asking costs one account, a
    /// history.list each time (MailGmail.cost); what came is fetched on top.
    public static func units(perHour every: TimeInterval?) -> Int {
        guard let every, every > 0 else { return 0 }
        return Int((3600 / every).rounded(.down)) * MailGmail.cost("history", method: "GET")
    }

    /// When the next beat is due: the soonest of the accounts' next asks,
    /// each its last ask and its rhythm on, none before its rest is over;
    /// and the soonest snoozed thread's time. Nil when nothing is due.
    public static func next(asks: [(last: Date, every: TimeInterval?, rest: Date?)], snoozed: Date?, now: Date) -> Date? {
        var soonest = snoozed
        for ask in asks {
            guard let every = ask.every else { continue }
            let due = max(ask.last.addingTimeInterval(every), ask.rest ?? .distantPast)
            soonest = min(soonest ?? due, due)
        }
        return soonest.map { max($0, now) }
    }
}

/// One account's line to Gmail: a session of its own, so the connection
/// stays open from ask to ask, one TLS handshake and not one a poll (an
/// idle one to Gmail was still there after two and a half minutes and gone
/// after five, so asks 10 to 30 seconds apart all share one), nothing Gmail
/// sends is written to a cache on disk, and no cookie rides along. It counts
/// the connections it opened and the asks that went over one already open,
/// for the bench.
public final class MailWire: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (opened: 0, reused: 0)
    public private(set) lazy var session: URLSession = URLSession(configuration: MailWire.configuration(), delegate: self, delegateQueue: nil)

    override public init() { super.init() }

    /// A line to Google as mail's are: nothing it answers written to a cache
    /// on disk, no cookie kept or sent, no credential kept, and TLS 1.2 at
    /// least (the app lets pages load anything, as a browser must; mail
    /// doesn't need to).
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return config
    }

    /// Yab 0.0.3 asked Gmail through the app's shared session, whose cache
    /// on disk (~/Library/Caches/<bundle id>/Cache.db) kept what Gmail
    /// answered. Mail never goes there now (MailGmail.uncached); what was
    /// kept goes once, and again at every Disconnect (`always`). The whole
    /// cache goes: the rest of it is only what a few other asks keep to be
    /// quicker.
    public static func sweepCache(_ cache: URLCache = .shared, always: Bool = false, settings: UserDefaults = Store.settings) {
        guard always || !settings.bool(forKey: swept) else { return }
        cache.removeAllCachedResponses()
        settings.set(true, forKey: swept)
    }

    static let swept = "mail.cache.swept"

    public var opened: Int { lock.withLock { counts.opened } }
    public var reused: Int { lock.withLock { counts.reused } }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for step in metrics.transactionMetrics where step.resourceFetchType == .networkLoad {
            lock.withLock {
                if step.isReusedConnection { counts.reused += 1 } else { counts.opened += 1 }
            }
        }
    }

    /// The account went: its connection with it. Its calls are cancelled
    /// at once and the session let go of ten minutes later, not now: a call
    /// still on its way (a sync that hadn't yet heard it was stopped) would
    /// make a task on a session already let go of, which ends the app.
    public func close() {
        let session = session
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) { session.finishTasksAndInvalidate() }
    }
}

/// The network coming back, said once each time it does, for an ask at once.
public final class MailNetwork: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private var was: NWPath.Status?

    public init(back: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            defer { was = path.status }
            if path.status == .satisfied, let was, was != .satisfied { back() }
        }
        monitor.start(queue: DispatchQueue(label: "yab.mail.network", qos: .utility))
    }

    public func stop() { monitor.cancel() }
}

/// The screen unlocked, heard even while Yab is behind other apps: AppKit
/// holds distributed notifications back from an app that isn't active
/// unless they are asked for at once.
public final class MailUnlock: NSObject {
    private let back: @MainActor () -> Void

    public init(back: @escaping @MainActor () -> Void) {
        self.back = back
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlocked), name: .init("com.apple.screenIsUnlocked"),
                                                            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func unlocked() {
        DispatchQueue.main.async { [back] in MainActor.assumeIsolated { back() } }
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }
}
