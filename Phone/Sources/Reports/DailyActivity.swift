import Foundation
import UIKit

// One count for a day on which Yab for iPhone was used, as Yab on the Mac
// counts its days (Sources/Fast/Activity.swift, the same request to the same
// site): a random ID for this installation, made at the first launch, the
// word iphone, so the site counts iPhones apart, and the person's random ID
// when their Mac synced it here; nothing else, the site
// supplies the day. Once on each UTC day Yab is in front, while Share daily
// activity is on (Settings › About), which it is unless turned off.

@MainActor
final class DailyActivity {
    static let shared = DailyActivity()

    /// Share daily activity, on unless turned off.
    nonisolated static let key = "activity.send"
    nonisolated static let idKey = "activity.installation"
    nonisolated static let dayKey = "activity.lastDay"
    /// The person's random ID, made by Yab on their Mac and synced here
    /// (SyncBridge keeps it in these defaults); none without a Mac in Sync.
    nonisolated static let personKey = "activity.person"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        return URLSession(configuration: configuration)
    }()

    private var site: URL?
    private var defaults: UserDefaults = .standard
    private var sending = false
    private var clock: Timer?
    private var observer: NSObjectProtocol?

    private init() {}

    /// For a build that has a site: the ID made if there is none yet, then a
    /// count whenever Yab comes to the front on a day not counted.
    func start(site: URL, defaults: UserDefaults = .standard) {
        guard self.site == nil else { return }
        self.site = site
        self.defaults = defaults
        _ = Self.installation(in: defaults)
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
        // Yab can stay in front across midnight.
        clock = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendIfDue() }
        }
        clock?.tolerance = 60 * 5
        sendIfDue()
    }

    func sendIfDue() {
        guard let site, !sending, UIApplication.shared.applicationState == .active else { return }
        sending = true
        let defaults = defaults
        Task { [weak self] in
            defer { self?.sending = false }
            await Self.sendIfDue(site: site, defaults: defaults, now: Date()) { request in
                guard let (_, response) = try? await Self.session.data(for: request) else { return false }
                return (response as? HTTPURLResponse)?.statusCode == 200
            }
        }
    }

    /// The day's count, when it is due: sharing on, and today (UTC) not
    /// counted yet. The day is written down only once the site took it.
    /// Answers whether a count went.
    @discardableResult
    static func sendIfDue(site: URL, defaults: UserDefaults, now: Date,
                          post: (URLRequest) async -> Bool) async -> Bool {
        guard sends(defaults) else { return false }
        let day = utcDay(now)
        guard defaults.string(forKey: dayKey) != day else { return false }
        guard await post(dayRequest(site: site, id: installation(in: defaults), person: defaults.string(forKey: personKey))) else { return false }
        defaults.set(day, forKey: dayKey)
        return true
    }

    static func sends(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// The random ID for this installation, made the first time it is asked for.
    static func installation(in defaults: UserDefaults) -> String {
        if let saved = defaults.string(forKey: idKey) { return saved }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: idKey)
        return id
    }

    // MARK: what goes

    /// The day's count: the installation's ID and the platform, nothing else.
    static func dayRequest(site: URL, id: String, person: String? = nil) -> URLRequest {
        var request = URLRequest(url: site.appendingPathComponent("api/activity"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpShouldHandleCookies = false
        var body: [String: Any] = ["id": id, "platform": DiagnosticReports.platform]
        if let person { body["person"] = person }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
