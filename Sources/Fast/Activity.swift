import AppKit
import Foundation

// One count for a day on which the installed browser was active: a random
// ID for this installation, a random ID for the person and which update
// channel this Mac follows, Nightly or Stable, nothing else; the site
// supplies the day. The person ID is made once and goes to the
// person's other Macs and iPhone as a synced setting (end-to-end
// encrypted, as all of Sync), so the site counts people, not copies.
//
// Store boosts kept for a week and still on (docs/store.md, Kept) are
// counted apart: their Store ids in a request of their own, with no ID, at
// least ten minutes after the day's count, each boost at most once in 30
// days, so the site counts the installs that keep one by adding up what it
// was sent. Both go only while Share daily activity is on.
@MainActor
final class Activity {
    static let shared = Activity()
    static let key = "activity.send"

    private static let idKey = "activity.installation"
    /// The person's random ID, the same on every device they sync.
    static let personKey = "activity.person"
    private static let dayKey = "activity.lastDay"
    /// When the day was last counted, so the kept boosts go apart from it.
    private static let countedKey = "activity.counted"
    /// When each kept boost was last sent, by Store id.
    static let keptKey = "activity.keptSent"
    /// How long a boost goes unsent after it was sent: the site counts
    /// installs over this many days.
    static let keptEvery: TimeInterval = 30 * 24 * 60 * 60
    /// How long after the day's count the kept boosts may go.
    static let keptApart: TimeInterval = 10 * 60

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()
    private var started = false
    private var sending = false
    private var sendingKept = false
    private var clock: Timer?
    private var later: Timer?

    private init() {}

    func start() {
        guard !started, !Store.testing, !Store.development, Updater.site != nil else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
        // A browser can stay in front across midnight without reopening.
        clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
        clock?.tolerance = 60 * 5
        sendIfDue()
    }

    func sendIfDue() {
        guard started, let app = NSApp, app.isActive, !sending,
              Store.settings.object(forKey: Self.key) as? Bool ?? true,
              let site = Updater.site else { return }

        let day = Self.utcDay(Date())
        guard Store.settings.string(forKey: Self.dayKey) != day else {
            sendKeptIfDue(site: site)
            return
        }
        let id: String
        if let saved = Store.settings.string(forKey: Self.idKey) {
            id = saved
        } else {
            id = UUID().uuidString.lowercased()
            Store.settings.set(id, forKey: Self.idKey)
        }

        let person: String
        if let saved = Store.settings.string(forKey: Self.personKey) {
            person = saved
        } else {
            person = UUID().uuidString.lowercased()
            Store.settings.set(person, forKey: Self.personKey)
        }

        sending = true
        let request = Self.dayRequest(site: site, id: id, person: person,
                                      nightly: Store.settings.bool(forKey: Updater.nightlyKey))
        Task { [weak self] in
            defer { self?.sending = false }
            guard let (_, response) = try? await Self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            Store.settings.set(day, forKey: Self.dayKey)
            Store.settings.set(Date(), forKey: Self.countedKey)
            StoreCatalog.shared.refresh()
            StoreCatalog.shared.checkRequests()
            self?.keptLater()
        }
    }

    /// Once the day is counted, the kept boosts a while after, at a moment
    /// of their own.
    private func keptLater() {
        later?.invalidate()
        later = Timer.scheduledTimer(withTimeInterval: Self.keptApart + .random(in: 0 ... 10 * 60), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
    }

    private func sendKeptIfDue(site: URL) {
        guard !sendingKept else { return }
        let counted = Store.settings.object(forKey: Self.countedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(counted) >= Self.keptApart else { return }
        let sent = Store.settings.dictionary(forKey: Self.keptKey) as? [String: Double] ?? [:]
        let due = Self.keptDue(StoreCatalog.shared.keptForActivity(), sent: sent, now: Date())
        guard !due.isEmpty else { return }
        sendingKept = true
        let request = Self.keptRequest(site: site, ids: due)
        Task { [weak self] in
            defer { self?.sendingKept = false }
            guard let (_, response) = try? await Self.session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let now = Store.settings.dictionary(forKey: Self.keptKey) as? [String: Double] ?? [:]
            Store.settings.set(Self.keptSent(due, into: now, at: Date()), forKey: Self.keptKey)
        }
    }

    // MARK: what goes

    /// The day's count: the installation's ID, the person's and the update
    /// channel, nothing else. /admin splits each day's people by channel.
    static func dayRequest(site: URL, id: String, person: String, nightly: Bool) -> URLRequest {
        post(site.appendingPathComponent("api/activity"),
             ["id": id, "person": person, "channel": nightly ? "nightly" : "stable"])
    }

    /// Kept boosts, by Store id, and nothing else: no ID, no day.
    static func keptRequest(site: URL, ids: [String]) -> URLRequest {
        post(site.appendingPathComponent("api/kept"), ["kept": ids])
    }

    private static func post(_ url: URL, _ body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// The kept boosts not sent in the last 30 days, at most a hundred.
    static func keptDue(_ kept: [String], sent: [String: Double], now: Date) -> [String] {
        Array(Set(kept).filter { id in
            guard let last = sent[id] else { return true }
            return now.timeIntervalSince1970 - last >= keptEvery
        }.sorted().prefix(100))
    }

    /// The record once `ids` went: their time now, and what is long past
    /// forgotten.
    static func keptSent(_ ids: [String], into sent: [String: Double], at now: Date) -> [String: Double] {
        var out = sent.filter { now.timeIntervalSince1970 - $0.value < 2 * keptEvery }
        for id in ids { out[id] = now.timeIntervalSince1970 }
        return out
    }

    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
