import Foundation
import MetricKit
import UIKit

/// What Yab for iPhone sends to its site, and when it may: the day's count
/// (DailyActivity) and crash reports (CrashReports). Only a build made with
/// a site sends anything: the Release configuration writes YabSite into the
/// Info.plist (project.yml, YAB_SITE), so TestFlight's and the App Store's
/// builds have one and the simulator's and the farm's Debug builds don't. A
/// test run never sends either.
@MainActor
enum Reports {
    static var site: URL? { site(in: .main, options: .current) }

    nonisolated static func site(in bundle: Bundle, options: LaunchOptions) -> URL? {
        guard !options.isTestRun, let text = bundle.object(forInfoDictionaryKey: "YabSite") as? String,
              let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static var observer: NSObjectProtocol?

    /// At launch: the day's count, and MetricKit listened to.
    static func start(_ options: LaunchOptions) {
        guard observer == nil, let site = site(in: .main, options: options) else { return }
        DailyActivity.shared.start(site: site)
        CrashReports.shared.start(site: site)
        DiagnosticsWatcher.shared.start()
        UpdateLoops.shared = UpdateLoops(file: CrashReports.shared.loopFile)
        UpdateLoops.shared?.start()
        // A question that couldn't be asked (Yab was in the back, something
        // was up) is asked when Yab is in front again.
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { offerCrashReports() }
        }
    }

    /// The app is up: the question waits while private tabs are behind
    /// their lock, and goes over the page otherwise.
    static func attach(_ app: AppModel) {
        CrashQuestion.mayAsk = { [weak app] in
            guard let app else { return false }
            return !app.privateContentBlocked && !app.privateLock.presentsPrompt
        }
    }

    static func offerCrashReports() {
        Task { await CrashReports.shared.offer() }
    }
}

/// MetricKit's diagnostics, at launch and as they come: crashes and long
/// hangs made into reports (DiagnosticReports), shorter hangs' stacks kept
/// (HangStacks), all handed to CrashReports on the main thread; and its
/// daily metrics, of which the exit counts are kept (ExitCounts).
final class DiagnosticsWatcher: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsWatcher()
    private let queue = DispatchQueue(label: "yab.diagnostics", qos: .utility)
    private var started = false
    private let bundle = Bundle.main.bundleIdentifier ?? "dev.serafim.fast.iphone"

    func start() {
        guard !started else { return }
        started = true
        let manager = MXMetricManager.shared
        manager.add(self)
        queue.async { [self] in
            handle(manager.pastDiagnosticPayloads)
            handle(manager.pastPayloads)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        queue.async { [self] in handle(payloads) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        queue.async { [self] in handle(payloads) }
    }

    private func handle(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        var reports: [CrashReport] = [], hangs: [[String: Any]] = []
        for payload in payloads {
            // Parsed once, from a copy of its own (DiagnosticReports.payload, #1537).
            guard let json = DiagnosticReports.payload(payload.jsonRepresentation()) else { continue }
            reports += DiagnosticReports.crashes(in: json, bundle: bundle)
            let durations = (payload.hangDiagnostics ?? []).map {
                Int($0.hangDuration.converted(to: .milliseconds).value.rounded())
            }
            let found = DiagnosticReports.hangs(in: json, bundle: bundle, durations: durations)
            reports += found.reports
            hangs += found.stacks
        }
        guard !reports.isEmpty || !hangs.isEmpty else { return }
        Task { @MainActor in await CrashReports.shared.received(reports, hangs: hangs) }
    }

    private func handle(_ payloads: [MXMetricPayload]) {
        let days = payloads.compactMap { ExitCounts.day($0) }
        guard !days.isEmpty else { return }
        Task { @MainActor in ExitCounts.keep(days, in: CrashReports.shared.exitFile) }
    }
}
