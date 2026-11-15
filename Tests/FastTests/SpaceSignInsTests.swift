import Foundation
import Testing
@testable import Fast

struct SpaceSignInsTests {
    private typealias Crumb = SignIns.Crumb

    private func crumb(_ name: String, _ value: String = "v", expires: Date? = nil) -> Crumb {
        Crumb(name: name, value: value, expires: expires)
    }

    @Test func analyticsAloneIsSignedOut() {
        let cookies = [crumb("_ga"), crumb("_gid"), crumb("_uetsid"), crumb("ajs_user_id"), crumb("_csrf_token"), crumb("OptanonConsent")]
        #expect(SignIns.seen(cookies, names: [], working: true) == .out)
    }

    @Test func aSessionCookieIsLikelyAndATabMakesItSure() {
        let cookies = [crumb("_ga"), crumb("session_id")]
        #expect(SignIns.seen(cookies, names: [], working: false) == .likely)
        #expect(SignIns.seen(cookies, names: [], working: true) == .signedIn)
    }

    @Test func aCookieSayingNobodyIsThereCountsForNothing() {
        // GitHub keeps logged_in=no once you sign out.
        #expect(SignIns.seen([crumb("logged_in", "no")], names: [], working: true) == .out)
        #expect(SignIns.seen([crumb("auth_token", "")], names: [], working: false) == .out)
    }

    @Test func anExpiredCookieIsGone() {
        let past = Date(timeIntervalSinceNow: -60)
        #expect(SignIns.seen([crumb("sessionid", expires: past)], names: [], working: true) == .out)
        #expect(SignIns.seen([crumb("sessionid", expires: Date(timeIntervalSinceNow: 3600))], names: [], working: false) == .likely)
    }

    @Test func aSkillsNamesDecideAlone() {
        // A session-looking cookie that isn't the one GitHub signs in with.
        #expect(SignIns.seen([crumb("_gh_sess"), crumb("logged_in", "yes")], names: ["user_session"], working: true) == .out)
        #expect(SignIns.seen([crumb("user_session")], names: ["user_session"], working: false) == .signedIn)
        #expect(SignIns.seen([crumb("SID")], names: ["SID", "__Secure-1PSID"], working: false) == .signedIn)
    }

    @Test func cookieDomainsCoverTheirSubdomains() {
        #expect(SignIns.covers(".google.com", "mail.google.com"))
        #expect(SignIns.covers("github.com", "github.com"))
        #expect(SignIns.covers(".www.example.com", "example.com"))
        #expect(!SignIns.covers("accounts.google.com", "mail.google.com"))
        #expect(!SignIns.covers("ithub.com", "github.com"))
        #expect(!SignIns.covers("", "github.com"))
    }

    @Test func sitesMatchEitherWayUnderEachOther() {
        #expect(SignIns.same("mail.google.com", "google.com"))
        #expect(SignIns.same("github.com", "gist.github.com"))
        #expect(!SignIns.same("github.com", "gitlab.com"))
        #expect(SignIns.site("WWW.GitHub.com") == "github.com")
    }

    @Test func signInPagesAreToldFromPagesSignedInReads() {
        let yes = ["https://github.com/login?return_to=%2Fnotifications", "https://github.com/session",
                   "https://accounts.google.com/v3/signin/identifier", "https://login.microsoftonline.com/common/oauth2",
                   "https://app.example.com/auth/sign-in", "https://example.com/sessions/new", "https://sso.example.com/start",
                   "https://www.linkedin.com/login"]
        let no = ["https://github.com/notifications", "https://mail.google.com/mail/u/0/#inbox", "https://example.com/blog/login-tips",
                  "https://accounts.google.com/b/0/manageaccount", "https://github.com/sessions-by-topic", "https://example.com/authors"]
        for raw in yes { #expect(SignIns.loginPage(URL(string: raw)!), "\(raw)") }
        for raw in no { #expect(!SignIns.loginPage(URL(string: raw)!), "\(raw)") }
    }

    @Test func aSignInIsOverBackOnTheSite() {
        let from = URL(string: "https://resend.com/login")!
        #expect(SignIns.back(from: from, at: URL(string: "https://resend.com/broadcasts")!))
        #expect(SignIns.back(from: from, at: URL(string: "https://www.resend.com/home")!))
        for raw in ["https://accounts.google.com/v3/signin/identifier", "https://github.com/login/oauth/authorize",
                    "https://resend.com/login?error=1", "https://resend.com/signup", "https://resend.com/auth/callback",
                    "https://resend.com/verify-email"] {
            #expect(!SignIns.back(from: from, at: URL(string: raw)!), "\(raw)")
        }
    }

    @Test func theWaysLineNamesWhatToClick() {
        let line = SignIns.line(["Google", "GitHub"])
        #expect(line.hasPrefix("signs in with: Google, GitHub"))
        #expect(line.contains("Continue with Google"))
    }

    @Test func aSkillReadsItsSignInCookies() {
        let text = """
        ---
        name: github
        description: GitHub.
        sites: [github.com]
        signed-in: [user_session, other]
        ---

        # GitHub
        """
        let skill = Skills.parse(text, own: false, path: URL(fileURLWithPath: "/tmp/SKILL.md"))
        #expect(skill?.signedIn == ["user_session", "other"])
    }
}
