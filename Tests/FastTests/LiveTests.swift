import Foundation
import Testing
@testable import Fast

// A live folder of GitHub's pull requests: what its lists answer, as
// answered on 2026-09-28 (names and titles made up), and what an answer
// changes in the folder.
struct LiveGitHubTests {
    static let needsAction = #"""
{"meta":{"title":"Pull request name1"},"payload":{"pullsInboxSurfaceContentRoute":{"results":[{"itemType":"pull_request","assignees":[],"author":{"displayLogin":"someone"},"authoredByAgent":false,"category":"CI_FAILING","commentCount":7,"commitHeadShaChannel":"x","agentAttributedUser":null,"createdAt":"2026-09-01T18:42:17-07:00","displayState":"OPEN","headSha":"x","labels":[],"id":"PR_name2","aliveChannel":null,"isDraft":false,"isReadByCurrentUser":true,"mergeQueueUrl":null,"number":711,"permalink":"https://github.com/acme/name3/pull/711","repoNameWithOwner":"acme/name3","stackPosition":null,"stackSize":null,"state":"OPEN","title":"Pull request name4","titleHtml":"Pull request name4","updatedAt":"2026-09-04T18:51:27-07:00"}],"pageInfo":{"currentPage":1,"totalPages":1,"totalCount":1,"openCount":null,"closedCount":null},"error":null}}}
"""#
    static let waiting = #"""
{"meta":{"title":"Pull request name1"},"payload":{"pullsInboxSurfaceContentRoute":{"results":[{"itemType":"pull_request","assignees":[],"author":{"displayLogin":"someone"},"authoredByAgent":false,"category":"WAITING_FOR_REVIEW","commentCount":5,"commitHeadShaChannel":"x","agentAttributedUser":null,"createdAt":"2026-09-01T14:38:51-07:00","displayState":"OPEN","headSha":"x","labels":[],"id":"PR_name5","aliveChannel":null,"isDraft":false,"isReadByCurrentUser":true,"mergeQueueUrl":null,"number":1,"permalink":"https://github.com/acme/name6/pull/1","repoNameWithOwner":"acme/name6","stackPosition":null,"stackSize":null,"state":"OPEN","title":"Pull request name7","titleHtml":"Pull request name7","updatedAt":"2026-09-01T19:10:42-07:00"},{"itemType":"pull_request","assignees":[],"author":{"displayLogin":"someone"},"authoredByAgent":false,"category":"WAITING_FOR_REVIEW","commentCount":5,"commitHeadShaChannel":"x","agentAttributedUser":null,"createdAt":"2026-09-01T15:34:14-07:00","displayState":"OPEN","headSha":"x","labels":[],"id":"PR_name8","aliveChannel":null,"isDraft":false,"isReadByCurrentUser":true,"mergeQueueUrl":null,"number":3,"permalink":"https://github.com/acme/name6/pull/3","repoNameWithOwner":"acme/name6","stackPosition":null,"stackSize":null,"state":"OPEN","title":"Pull request name9","titleHtml":"Pull request name9","updatedAt":"2026-09-01T15:37:26-07:00"},{"itemType":"pull_request","assignees":[],"author":{"displayLogin":"someone"},"authoredByAgent":false,"category":"WAITING_FOR_REVIEW","commentCount":0,"commitHeadShaChannel":"x","agentAttributedUser":null,"createdAt":"2026-09-01T15:31:54-07:00","displayState":"OPEN","headSha":"x","labels":[],"id":"PR_name10","aliveChannel":null,"isDraft":false,"isReadByCurrentUser":true,"mergeQueueUrl":null,"number":2,"permalink":"https://github.com/acme/name6/pull/2","repoNameWithOwner":"acme/name6","stackPosition":null,"stackSize":null,"state":"OPEN","title":"Pull request name11","titleHtml":"Pull request name11","updatedAt":"2026-09-01T15:31:54-07:00"}],"pageInfo":{"currentPage":1,"totalPages":1,"totalCount":3,"openCount":null,"closedCount":null},"error":null}}}
"""#
    static let ready = #"""
{"meta":{"title":"Pull request name1"},"payload":{"pullsInboxSurfaceContentRoute":{"results":[],"pageInfo":{"currentPage":1,"totalPages":1,"totalCount":0,"openCount":null,"closedCount":null},"error":null}}}
"""#
    static let deferred = #"""
{"meta":{"title":"Pull request name1"},"payload":{"pullsInboxSurfaceContentDeferredData":{"results":[{"id":"PR_name2","reviewDecisionState":"REVIEW_REQUIRED","statusCheckRollup":{"state":"FAILURE","totalCount":4,"successCount":2},"approvedReviewsCount":null,"changesRequestedReviewsCount":null},{"id":"PR_name5","reviewDecisionState":null,"statusCheckRollup":{"state":"SUCCESS","totalCount":1,"successCount":1},"approvedReviewsCount":null,"changesRequestedReviewsCount":null},{"id":"PR_name10","reviewDecisionState":null,"statusCheckRollup":{"state":"SUCCESS","totalCount":1,"successCount":1},"approvedReviewsCount":null,"changesRequestedReviewsCount":null},{"id":"PR_name8","reviewDecisionState":null,"statusCheckRollup":{"state":"SUCCESS","totalCount":1,"successCount":1},"approvedReviewsCount":null,"changesRequestedReviewsCount":null}]}}}
"""#

    static func pulls(_ text: String) -> [LiveGitHub.Pull] {
        guard case .pulls(let pulls) = LiveGitHub.pulls(Data(text.utf8), status: 200, finalURL: URL(string: "https://github.com/pulls/inbox/queries")) else { return [] }
        return pulls
    }

    @Test func lists() {
        let failing = Self.pulls(Self.needsAction)
        #expect(failing.count == 1)
        #expect(failing.first?.category == "CI_FAILING")
        #expect(failing.first?.number == 711)
        #expect(failing.first?.url.absoluteString == "https://github.com/acme/name3/pull/711")
        #expect(failing.first?.repo == "acme/name3")
        #expect(failing.first?.updated != nil)
        #expect(Self.pulls(Self.waiting).count == 3)
        #expect(Self.pulls(Self.ready).isEmpty)
    }

    @Test func signedOutAndBroken() {
        #expect(LiveGitHub.pulls(Data("<html>".utf8), status: 200, finalURL: URL(string: "https://github.com/login?return_to=x")) == .signedOut)
        #expect(LiveGitHub.pulls(Data(), status: 401, finalURL: nil) == .signedOut)
        #expect(LiveGitHub.pulls(Data("<html>".utf8), status: 200, finalURL: URL(string: "https://github.com/pulls/inbox/queries")) == .failed)
        #expect(LiveGitHub.pulls(Data(#"{"payload":{}}"#.utf8), status: 200, finalURL: nil) == .failed)
        #expect(LiveGitHub.pulls(Data(), status: 502, finalURL: nil) == .failed)
    }

    @Test func statuses() {
        let statuses = LiveGitHub.statuses(Data(Self.deferred.utf8))
        #expect(statuses.count == 4)
        #expect(statuses["PR_name2"] == LiveGitHub.Status(review: "REVIEW_REQUIRED", checks: "FAILURE"))
        #expect(statuses["PR_name5"]?.checks == "SUCCESS")
    }

    @Test func words() {
        let statuses = LiveGitHub.statuses(Data(Self.deferred.utf8))
        let items = LiveGitHub.items([("waiting-for-review", Self.pulls(Self.waiting)), ("needs-action", Self.pulls(Self.needsAction))],
                                     statuses: statuses, hiddenGroups: [])
        // Needs action first, then yours waiting.
        #expect(items.count == 4)
        #expect(items.first?.words == .failing)
        #expect(items.dropFirst().allSatisfy { $0.words == nil })
        #expect(Set(items.map(\.key)).count == 4)
        let pull = LiveGitHub.Pull(id: "x", number: 1, title: "t", url: URL(string: "https://github.com/a/b/pull/1")!, repo: "a/b",
                                   category: nil, draft: false, read: false, updated: nil)
        #expect(LiveGitHub.words(pull, list: "review-requested", status: nil) == .review)
        #expect(LiveGitHub.words(pull, list: "waiting-for-review", status: .init(review: "CHANGES_REQUESTED", checks: "FAILURE")) == .changes)
        #expect(LiveGitHub.words(pull, list: "waiting-for-review", status: .init(review: nil, checks: "ERROR")) == .failing)
        #expect(LiveGitHub.words(pull, list: "ready-to-merge", status: .init(review: "APPROVED", checks: "SUCCESS")) == .ready)
        #expect(LiveGitHub.words(pull, list: "waiting-for-review", status: nil) == .new)
        var read = pull
        read.read = true
        #expect(LiveGitHub.words(read, list: "waiting-for-review", status: nil) == nil)
    }

    @Test func hiddenRepositories() {
        let items = LiveGitHub.items([("needs-action", Self.pulls(Self.needsAction))], statuses: [:], hiddenGroups: ["acme/name3"])
        #expect(items.isEmpty)
    }

    @Test func keys() {
        #expect(LiveFolder.key(URL(string: "https://github.com/Acme/Yab/pull/12")) == "github.com/acme/yab/pull/12")
        #expect(LiveFolder.key(URL(string: "https://github.com/acme/yab/pull/12/files#diff-1")) == "github.com/acme/yab/pull/12")
        #expect(LiveFolder.key(URL(string: "https://git.acme.dev/acme/yab/pull/3")) == "git.acme.dev/acme/yab/pull/3")
        #expect(LiveFolder.key(URL(string: "https://github.com/acme/yab/pulls")) == nil)
        #expect(LiveFolder.key(URL(string: "https://github.com/acme/yab/issues/12")) == nil)
    }

    @Test func titles() {
        #expect(LiveGitHub.shortTitle("Fix wake crash by anna · Pull Request #12 · acme/yab · GitHub") == "Fix wake crash")
        #expect(LiveGitHub.shortTitle("Fix wake crash · Pull Request #12 · acme/yab") == "Fix wake crash")
        #expect(LiveGitHub.shortTitle("Fix wake crash") == "Fix wake crash")
        #expect(LiveGitHub.host(of: URL(string: "https://github.com/a/b/pull/1")!) == "github.com")
        #expect(LiveGitHub.host(of: URL(string: "http://127.0.0.1:8123/a/b/pull/1")!) == "http://127.0.0.1:8123")
    }

    @Test func urls() {
        #expect(LiveGitHub.queryURL(host: "github.com", list: "needs-action")?.absoluteString == "https://github.com/pulls/inbox/queries?filter=needs-action&max_pr_age=1m")
        let deferred = LiveGitHub.deferredURL(host: "github.com", ids: ["PR_a", "PR_b"])?.absoluteString ?? ""
        #expect(deferred.hasPrefix("https://github.com/pulls/inbox/deferred?page=1&ids%5B%5D=PR_a&ids%5B%5D=PR_b"))
    }
}

struct LiveDiffTests {
    static func item(_ n: Int, _ words: LiveWords? = nil) -> LiveItem {
        LiveItem(key: "github.com/a/b/pull/\(n)", url: URL(string: "https://github.com/a/b/pull/\(n)")!, title: "PR \(n)", group: "a/b",
                 words: words, updated: nil)
    }

    static func held(_ n: Int, brought: Bool = true, words: LiveWords? = nil, busy: Bool = false) -> (LiveFolder.Held, UUID) {
        let id = UUID()
        return (LiveFolder.Held(id: id, key: "github.com/a/b/pull/\(n)", brought: brought, words: words, busy: busy), id)
    }

    @Test func comesAndGoes() {
        let (one, oneID) = Self.held(1)
        let (two, twoID) = Self.held(2, words: .new)
        let diff = LiveFolder.diff([Self.item(2), Self.item(3, .review)], held: [one, two], today: [:], elsewhere: [], hidden: [])
        #expect(diff.remove == [oneID])
        #expect(diff.add.map(\.key) == ["github.com/a/b/pull/3"])
        #expect(diff.words.count == 1)
        #expect(diff.words[twoID] == .some(nil))
    }

    @Test func onlyWhatItBrought() {
        let (mine, _) = Self.held(1, brought: false)
        let (busy, _) = Self.held(2, busy: true)
        let diff = LiveFolder.diff([], held: [mine, busy], today: [:], elsewhere: [], hidden: [])
        #expect(diff.remove.isEmpty)
    }

    @Test func todayMovesIn() {
        let open = UUID()
        let diff = LiveFolder.diff([Self.item(4)], held: [], today: ["github.com/a/b/pull/4": open], elsewhere: [], hidden: [])
        #expect(diff.add.count == 1)
        #expect(diff.adopt["github.com/a/b/pull/4"] == open)
    }

    @Test func hiddenAndElsewhere() {
        let diff = LiveFolder.diff([Self.item(5), Self.item(6), Self.item(7)], held: [], today: [:],
                                   elsewhere: ["github.com/a/b/pull/6"], hidden: ["github.com/a/b/pull/5"])
        #expect(diff.add.map(\.key) == ["github.com/a/b/pull/7"])
        // A hidden one it holds goes, as if no longer listed.
        let (held, id) = Self.held(5)
        #expect(LiveFolder.diff([Self.item(5)], held: [held], today: [:], elsewhere: [], hidden: ["github.com/a/b/pull/5"]).remove == [id])
    }

    @Test func stopsAtThirty() {
        let items = (1...40).map { Self.item($0) }
        let diff = LiveFolder.diff(items, held: [], today: [:], elsewhere: [], hidden: [])
        #expect(diff.add.count == LiveFolder.most)
    }
}
