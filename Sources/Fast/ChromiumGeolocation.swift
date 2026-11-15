import CoreLocation
import Foundation
import YabCoreClient

// Where you are, for Chromium pages, from Yab.
//
// Chrome asks macOS from its browser process, which is the app. Yab's
// browser process is YabCore, a helper inside Yab's bundle signed as
// "YabCore": the CoreLocation manager Chrome made there at startup left Yab's
// own question to macOS without a window (feedback #1971; adhd, the same build
// on WebKit got the window, on Chromium never). With CEF patch 0120 Chrome
// makes none (--yab-external-geolocation): its location source is fed from
// here (YabCore's geolocation_source.inc). Yab asks macOS, as it does for
// WebKit pages (Whereabouts), and hands over its answer and its fixes; YabCore
// says when Chromium starts and stops watching.
//
// macOS's answer goes over as allowed or not determined, never denied: then a
// site's question still reaches Yab's card, which says what to do, as on
// WebKit, instead of Chromium refusing the page in silence. Only an answer to
// Chromium's own ask (a page's <geolocation> element) says denied.
@MainActor
enum ChromiumGeolocation {
    /// Whether the connected helper takes Yab's answer and fixes.
    private static var supported = false

    /// A helper connected: its location source learns macOS's answer at once,
    /// so a site allowed before is answered by Chromium itself.
    static func connected(hooks: [String: JSONValue]) {
        // A bool, or 1 from a helper that boxed the macro as a number.
        supported = hooks["geolocationSource"] == .bool(true) || hooks["geolocationSource"] == .number(1)
        guard supported else { return }
        Whereabouts.shared.whenKnown { answerChanged() }
    }

    static func disconnected() {
        guard supported else { return }
        supported = false
        queue = nil
        Whereabouts.shared.watch(chromium: false, high: false)
    }

    static func receive(_ event: YabCoreEvent) -> Bool {
        switch event.name {
        case "geolocation.watch":
            let on = event.params["watching"] == .bool(true)
            NSLog("Yab: Chromium location watch %@", on ? "on" : "off")
            told = 0
            Whereabouts.shared.watch(chromium: on, high: event.params["highAccuracy"] == .bool(true))
            return true
        case "geolocation.ask":
            Whereabouts.shared.authorize { yes in send(status: yes ? 2 : 1) }
            return true
        default:
            return false
        }
    }

    /// macOS's answer about Yab moved, or Location Services did.
    static func answerChanged() {
        let place = Whereabouts.shared
        let allowed = !place.refused && place.status != .notDetermined
        send(status: allowed ? 2 : 0)
    }

    /// Fixes handed over since Chromium last started or stopped watching.
    private static var told = 0

    static func tell(_ location: CLLocation) {
        told += 1
        if told == 1 { NSLog("Yab: Chromium location fix, %.0f s old", -location.timestamp.timeIntervalSinceNow) }
        var fix: [String: JSONValue] = [
            "latitude": .number(location.coordinate.latitude),
            "longitude": .number(location.coordinate.longitude),
            "accuracy": .number(max(location.horizontalAccuracy, 0)),
            "timestamp": .number(location.timestamp.timeIntervalSince1970 * 1000),
        ]
        if location.verticalAccuracy > 0 {
            fix["altitude"] = .number(location.altitude)
            fix["altitudeAccuracy"] = .number(location.verticalAccuracy)
        }
        if location.course >= 0 { fix["heading"] = .number(location.course) }
        if location.speed >= 0 { fix["speed"] = .number(location.speed) }
        request("geolocation.position", fix)
    }

    static func fail(_ message: String, denied: Bool) {
        request("geolocation.error", ["code": .number(denied ? 1 : 2), "message": .string(message)])
    }

    private static func send(status: Int) {
        request("geolocation.permission", ["status": .number(Double(status))])
    }

    /// One at a time, in order: an answer never overtakes the fix after it.
    private static var queue: Task<Void, Never>?

    private static func request(_ method: String, _ params: [String: JSONValue]) {
        guard supported, let core = ChromiumProcess.shared.connectedClient else { return }
        let previous = queue
        queue = Task {
            await previous?.value
            _ = try? await core.request(method, params: params)
        }
    }
}
