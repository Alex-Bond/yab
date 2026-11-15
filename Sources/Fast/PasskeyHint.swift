import Foundation

// A site asks for a passkey in a build that can't do them.
//
// Without Apple's browser entitlement (com.apple.developer.web-browser.
// public-key-credential, asked for and not yet granted) a WKWebView gets no
// passkeys at all, and sites say so in their own words, words about some
// other browser or device: GitHub's "Webauthn isn't supported", Google's
// "Bluetooth is not on". The corner says once what is going on, and what to
// do. The page keeps doing what it does: nothing here answers it or stops it.
//
// Heard two ways, both through the passkey bridge (PasskeyRelay): a page
// that asks, navigator.credentials.get or create with a public key, and a
// page that only looks for them, finds none and gives up with its own
// message. Looking happens on pages of every kind, so that one counts only on
// the few sign-in pages where a passkey is the step being asked for.
struct PasskeyHint {
    /// Within the corner's one line (Notice.longest): the longer "Passkeys
    /// come to Yab once Apple approves it" was cut in the middle.
    static let words = "Passkeys await Apple. Sign in another way"

    /// A password is X's alternative, not a second factor already past it.
    static func words(at url: URL?) -> String {
        guard let url, url.host()?.lowercased() == "x.com", signsIn(url) else { return words }
        return "Passkeys await Apple. Use your password"
    }
    static let mark = "key"
    /// Two sentences: read before it goes.
    static let stay: TimeInterval = 5

    enum Ask: String { case request, look }

    /// Whether this build can do them at all, asked of its own signature
    /// once (Preferences.entitledToPasskeys).
    @MainActor static let possible = Preferences.entitledToPasskeys

    /// Every window's, for as long as Yab runs.
    @MainActor static var shared = PasskeyHint()

    /// The sites already told this launch.
    private(set) var told: Set<String> = []

    /// Whether to say it now, for this ask on this page. A yes is kept: a
    /// site hears it once.
    mutating func take(_ ask: Ask, at url: URL?, entitled: Bool) -> Bool {
        guard !entitled, let url, let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        if ask == .look, !Self.signsIn(url) { return false }
        return told.insert(Vault.registrable(host)).inserted
    }

    /// The sign-in pages where a passkey is the step itself, and where the
    /// site, finding none, says something that doesn't help.
    static func signsIn(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let path = url.path.lowercased()
        switch host {
        case "github.com":
            // The second step, with a security key or a passkey.
            return path.hasPrefix("/sessions/two-factor/webauthn")
        case "accounts.google.com":
            // A challenge for a passkey (pk) or a security key (sk).
            return path.contains("/challenge/pk") || path.contains("/challenge/sk")
        case "x.com":
            return path == "/i/flow/login"
        default:
            return false
        }
    }
}
