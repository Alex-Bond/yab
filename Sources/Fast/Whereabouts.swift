import CoreLocation
import Foundation
import WebKit

/// Where you are, for the pages you let know it.
///
/// WebKit, in an app that isn't Safari, neither asks macOS about location
/// nor reads it: a page's getCurrentPosition, granted, waited for ever with
/// no macOS window (feedback #142). evals/location/bare.py, a bare
/// WKWebView on macOS 26.4 to 26.7: no dialog, no position, even with the
/// app already allowed and CoreLocation holding a fix 10 ms after it was
/// asked. So Yab does both. It asks macOS itself, the first time a page's
/// question is allowed (a site's request and the person's Allow, never on
/// its own), and it is the pool's geolocation provider: WebKit's C
/// WKGeolocationManager, which hands CoreLocation's fixes to every page
/// watching, as SiteNotices is the pool's notification provider.
@MainActor
final class Whereabouts: NSObject, CLLocationManagerDelegate {
    static let shared = Whereabouts()

    private let manager = CLLocationManager()
    /// Waiting on macOS's answer about Yab.
    private var waiting: [(Bool) -> Void] = []
    /// The pool's WKGeolocationManagerRef, once the provider is set.
    private var geolocation: UnsafeRawPointer?
    private var installed = false
    private var updating = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// What a manager says before locationd has answered it is "not
    /// determined", whatever macOS decided: on renderer-2, Location Services
    /// off, a fresh manager said so and the card asked as if macOS would.
    /// Known once the manager's first word comes, a moment after it starts.
    private var known = false
    private var untilKnown: [() -> Void] = []

    /// `then` once what macOS said about Yab is known (a second at most).
    func whenKnown(_ then: @escaping () -> Void) {
        guard !known else { return then() }
        untilKnown.append(then)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.nowKnown() }
    }

    private func nowKnown() {
        known = true
        let all = untilKnown
        untilKnown = []
        for then in all { then() }
    }

    /// macOS said no to Yab, or Location Services is off for the whole Mac
    /// (CoreLocation says denied for that too).
    var refused: Bool { status == .denied || status == .restricted }

    /// macOS's answer about Yab: asked for, with its own window, if it was
    /// never given.
    func authorize(_ done: @escaping (Bool) -> Void) {
        switch status {
        case .notDetermined:
            waiting.append(done)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        case .denied, .restricted:
            done(false)
        default:
            done(true)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            if !known { nowKnown() }
            guard status != .notDetermined else { return }
            let all = waiting
            waiting = []
            for done in all { done(!refused) }
            if refused, updating { fail("Location Services is off for Yab") }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { tell(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Not yet known is CoreLocation still looking; it goes on.
        if (error as? CLError)?.code == .locationUnknown { return }
        let message = error.localizedDescription
        MainActor.assumeIsolated { fail(message) }
    }

    // MARK: - WebKit's provider

    private typealias Ref = UnsafeRawPointer
    private struct Base { var version: Int32; var info: UnsafeRawPointer? }
    /// WKGeolocationProviderV1.
    private struct Provider {
        var base: Base
        var start: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var stop: (@convention(c) (Ref?, UnsafeRawPointer?) -> Void)?
        var accuracy: (@convention(c) (Ref?, Bool, UnsafeRawPointer?) -> Void)?
    }

    nonisolated(unsafe) private static let webKit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
    nonisolated private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let symbol = dlsym(webKit, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    /// Set once, before the first page is granted: from then on what WebKit
    /// knows of where you are is what CoreLocation tells Yab.
    func install() {
        guard !installed else { return }
        installed = true
        guard let context = Self.fn("WKContextGetGeolocationManager", (@convention(c) (Ref) -> Ref?).self),
              let set = Self.fn("WKGeolocationManagerSetProvider", (@convention(c) (Ref, UnsafeRawPointer) -> Void).self),
              Self.fn("WKGeolocationManagerProviderDidChangePosition", (@convention(c) (Ref, Ref) -> Void).self) != nil,
              let geolocation = context(Unmanaged.passUnretained(Web.pool).toOpaque())
        else { return }
        self.geolocation = geolocation
        let provider = UnsafeMutablePointer<Provider>.allocate(capacity: 1)
        provider.initialize(to: Provider(
            base: Base(version: 1, info: nil),
            start: { _, _ in MainActor.assumeIsolated { Whereabouts.shared.start() } },
            stop: { _, _ in MainActor.assumeIsolated { Whereabouts.shared.stop() } },
            accuracy: { _, high, _ in
                MainActor.assumeIsolated {
                    Whereabouts.shared.manager.desiredAccuracy = high ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
                }
            }))
        set(geolocation, UnsafeRawPointer(provider))
    }

    /// A page started watching (WebKit calls it for the first one only).
    private func start() {
        guard !updating else { return }
        updating = true
        // What CoreLocation knew a moment ago answers at once; a fresh fix follows.
        if let known = manager.location, -known.timestamp.timeIntervalSinceNow < 120 { tell(known) }
        manager.startUpdatingLocation()
    }

    private func stop() {
        guard updating else { return }
        updating = false
        manager.stopUpdatingLocation()
    }

    private func tell(_ location: CLLocation) {
        guard updating, let geolocation,
              let changed = Self.fn("WKGeolocationManagerProviderDidChangePosition", (@convention(c) (Ref, Ref) -> Void).self)
        else { return }
        let time = location.timestamp.timeIntervalSince1970
        let c = location.coordinate
        let position: Ref?
        if let full = Self.fn("WKGeolocationPositionCreate_b", (@convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> Ref?).self) {
            position = full(time, c.latitude, c.longitude, max(location.horizontalAccuracy, 0),
                            location.verticalAccuracy > 0, location.altitude,
                            location.verticalAccuracy > 0, location.verticalAccuracy,
                            location.course >= 0, location.course,
                            location.speed >= 0, location.speed)
        } else if let plain = Self.fn("WKGeolocationPositionCreate", (@convention(c) (Double, Double, Double, Double) -> Ref?).self) {
            position = plain(time, c.latitude, c.longitude, max(location.horizontalAccuracy, 0))
        } else {
            position = nil
        }
        guard let position else { return }
        changed(geolocation, position)
        Self.fn("WKRelease", (@convention(c) (Ref) -> Void).self)?(position)
    }

    private func fail(_ message: String) {
        guard updating, let geolocation else { return }
        if let failed = Self.fn("WKGeolocationManagerProviderDidFailToDeterminePositionWithErrorMessage", (@convention(c) (Ref, Ref) -> Void).self),
           let make = Self.fn("WKStringCreateWithUTF8CString", (@convention(c) (UnsafePointer<CChar>) -> Ref?).self),
           let text = message.withCString({ make($0) }) {
            failed(geolocation, text)
            Self.fn("WKRelease", (@convention(c) (Ref) -> Void).self)?(text)
        } else {
            Self.fn("WKGeolocationManagerProviderDidFailToDeterminePosition", (@convention(c) (Ref) -> Void).self)?(geolocation)
        }
    }
}
