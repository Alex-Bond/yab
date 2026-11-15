import Foundation
import WebKit
import MailCore

/// A call's sound plays without a click (feedback #398: Google Meet went
/// silent a minute into a call, twice, and came back only by joining again).
///
/// Yab asks for a click before a page's sound plays
/// (`mediaTypesRequiringUserActionForPlayback = .audio`, Web.configuration).
/// WebKit lets a call's voice through anyway, but only while the page is
/// capturing the microphone or the camera, or already plays sound. A call
/// gives each voice an <audio> element of its own and plays it from its own
/// code; once the page has let go of the microphone and the camera (muted,
/// camera off) and the element it played through goes, the next voice's
/// play() is refused with NotAllowedError, and the call is silent until a
/// click: joining again. evals/feedback-398 (`quiet`) reproduces it: the
/// speakers' tone goes from 0.30 to 0 and stays there. Chrome lets a page
/// the person has clicked in play, so Meet never meets this there.
///
/// So the call sites load with WebKit's autoplay policy "allow"
/// (`_autoplayPolicy`, WebKit's per-site Allow All Auto-Play): every
/// page of Meet, Zoom's web client, Teams, Slack and Webex, whole sites,
/// since a call starts from their home page without a new load.
enum CallSound {
    /// _WKWebsiteAutoplayPolicyAllow.
    private static let allowed = 1
    private static let setter = NSSelectorFromString("_setAutoplayPolicy:")

    nonisolated static func site(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else {
            return CallLink.isCall(url)
        }
        if CallRelay.serves(host) { return true }
        if ["teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com"].contains(host) { return true }
        return host.hasSuffix(".webex.com") || CallLink.isCall(url)
    }

    static func allow(_ preferences: WKWebpagePreferences, for url: URL?) {
        guard site(url), preferences.responds(to: setter) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(preferences.method(for: setter), to: Set.self)(preferences, setter, allowed)
    }
}
