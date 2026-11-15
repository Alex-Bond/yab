import Foundation
import Testing
@testable import Fast

struct LiveSuggestTests {
    @Test func historyRanksSourcesAndRepositories() {
        let uses = LiveSuggest.uses([
            ("https://github.com/acme-dev/fast/pull/12", 40),
            ("https://github.com/acme-dev/fast/pulls", 20),
            ("https://github.com/acme-dev/fast-web/pull/3", 15),
            ("https://github.com/notifications", 9),
            ("https://github.com/acme-dev/fast/issues/7", 4),
            ("https://linear.app/acme/issue/YAB-412", 30),
            ("https://www.figma.com/design/abc/Sidebar", 3),
            ("https://example.com/", 99),
        ])
        #expect(uses.map(\.source) == ["github.pulls", "linear", "github.issues", "figma"])
        #expect(uses[0].visits == 84)
        #expect(uses[0].groups == ["acme-dev/fast", "acme-dev/fast-web"])
        #expect(uses[1].groups == ["acme"])
    }

    @Test func followedRepositoriesLeavePullRequests() {
        let visits: [(url: String, count: Int)] = [
            ("https://github.com/acme-dev/acme/pull/12", 40),
            ("https://github.com/samrivera/acme", 5),
            ("https://github.com/acme-dev/fast/pull/3", 6),
        ]
        let uses = LiveSuggest.uses(visits, followed: ["acme-dev/acme", "samrivera/acme"])
        #expect(uses.first?.visits == 6)
        #expect(uses.first?.groups == ["acme-dev/fast"])
        #expect((uses.first?.visits ?? 0) < LiveSuggest.enough)
    }

    @Test func repositoriesSkipGitHubsOwnPages() {
        let repos = LiveSuggest.repos([
            ("https://github.com/vercel/next.js/pull/1", 6),
            ("https://github.com/settings/profile", 50),
            ("https://github.com/acme-dev/acme", 52),
            ("https://gitlab.com/a/b", 80),
        ])
        #expect(repos.map(\.name) == ["acme-dev/acme", "vercel/next.js"])
    }

    @Test func typedRepositories() {
        #expect(LiveFolders.repo("acme-dev/fast") == "acme-dev/fast")
        #expect(LiveFolders.repo(" https://github.com/vercel/next.js/pulls?q=is%3Aopen ") == "vercel/next.js")
        #expect(LiveFolders.repo("github.com/anthropics/claude-code.git") == "anthropics/claude-code")
        #expect(LiveFolders.repo("fast") == nil)
        #expect(LiveFolders.repo("settings/profile") == nil)
        #expect(LiveFolders.repo("a b/c") == nil)
    }
}
