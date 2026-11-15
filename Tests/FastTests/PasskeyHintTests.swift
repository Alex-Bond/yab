import AppKit
import Testing
@testable import Fast

// When the corner says passkeys aren't here yet (PasskeyHint).
struct PasskeyHintTests {
    let github = URL(string: "https://github.com/sessions/two-factor/webauthn")!

    @Test func neverInABuildThatCanDoThem() {
        let hint = Told()
        #expect(!hint.say(.request, at: github, entitled: true))
        #expect(!hint.say(.look, at: github, entitled: true))
        #expect(hint.state.told.isEmpty)
        // And the site is still owed it, should the same launch ever lack them.
        #expect(hint.say(.request, at: github, entitled: false))
    }

    @Test func oncePerSite() {
        let hint = Told()
        #expect(hint.say(.request, at: github, entitled: false))
        #expect(!hint.say(.request, at: github, entitled: false))
        // Another page and another host of the same site: already told.
        #expect(!hint.say(.request, at: URL(string: "https://gist.github.com/login"), entitled: false))
        #expect(!hint.say(.look, at: github, entitled: false))
        // Another site hears it once too.
        #expect(hint.say(.request, at: URL(string: "https://accounts.google.com/v3/signin/challenge/pk"), entitled: false))
        #expect(!hint.say(.request, at: URL(string: "https://mail.google.com/"), entitled: false))
        #expect(hint.say(.request, at: URL(string: "http://fixture.localhost:8080/"), entitled: false))
        #expect(hint.state.told == ["github.com", "google.com", "fixture.localhost"])
    }

    @Test func lookingCountsOnlyWhereAPasskeyIsTheStep() {
        let hint = Told()
        // Feature detection is everywhere: on a news page it says nothing,
        // and keeps the site's one telling for a real request.
        #expect(!hint.say(.look, at: URL(string: "https://www.nytimes.com/"), entitled: false))
        #expect(!hint.say(.look, at: URL(string: "https://github.com/login"), entitled: false))
        #expect(hint.state.told.isEmpty)
        #expect(hint.say(.look, at: github, entitled: false))
        #expect(hint.say(.look, at: URL(string: "https://accounts.google.com/v3/signin/challenge/sk?TL=x"), entitled: false))
    }

    @Test func noSiteNoWord() {
        let hint = Told()
        #expect(!hint.say(.request, at: nil, entitled: false))
        #expect(!hint.say(.request, at: URL(string: "about:blank"), entitled: false))
        #expect(!hint.say(.request, at: URL(string: "file:///tmp/page.html"), entitled: false))
    }

    @Test func xLoginOffersThePasswordAlternativeOnce() {
        for address in ["https://x.com/i/flow/login", "https://x.com/i/flow/login?redirect_after_login=%2Fhome"] {
            let url = URL(string: address)!
            let hint = Told()
            #expect(!hint.say(.look, at: url, entitled: true))
            #expect(hint.say(.look, at: url, entitled: false))
            #expect(!hint.say(.request, at: url, entitled: false))
            #expect(hint.state.told == ["x.com"])
            #expect(PasskeyHint.words(at: url) == "Passkeys await Apple. Use your password")
        }
    }

    @Test func xFeatureDetectionElsewhereDoesNotUseTheLoginHint() {
        let hint = Told()
        for address in ["https://x.com/", "https://x.com/home", "https://x.com/settings/security",
                        "https://x.com/i/flow/signup", "https://x.com/i/flow/login-help",
                        "https://x.com.example.test/i/flow/login"] {
            #expect(!hint.say(.look, at: URL(string: address), entitled: false), "\(address)")
        }
        #expect(hint.state.told.isEmpty)
        #expect(hint.say(.look, at: URL(string: "https://x.com/i/flow/login"), entitled: false))
    }

    @Test func otherSignInStepsKeepTheirGeneralAlternative() {
        for address in ["https://github.com/sessions/two-factor/webauthn",
                        "https://accounts.google.com/v3/signin/challenge/pk", "https://x.com/home",
                        "https://x.com.example.test/i/flow/login"] {
            #expect(PasskeyHint.words(at: URL(string: address)) == PasskeyHint.words)
        }
        #expect(PasskeyHint.words(at: nil) == "Passkeys await Apple. Sign in another way")
    }

    @Test func sayItShort() {
        #expect(!PasskeyHint.words.contains("\u{2014}"))
        #expect(PasskeyHint.mark == "key")
        #expect(Glyphs.art(PasskeyHint.mark) != nil)
    }

    /// Whole in the corner, never cut in the middle, at every sidebar size.
    @MainActor @Test func fitsTheCorner() {
        for size in [12.0, 13.0, 14.0] {
            let font = NSFont.systemFont(ofSize: size)
            for words in [PasskeyHint.words, PasskeyHint.words(at: URL(string: "https://x.com/i/flow/login"))] {
                let width = (words as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
                #expect(width <= 240 * size / 12, "\(size) pt: \(width)")
            }
        }
        #expect(Notice.longest == 240 * Notice.font.pointSize / 12)
    }
}

/// The hint held by reference, so a test can ask inside #expect.
private final class Told {
    var state = PasskeyHint()
    func say(_ ask: PasskeyHint.Ask, at url: URL?, entitled: Bool) -> Bool {
        state.take(ask, at: url, entitled: entitled)
    }
}
