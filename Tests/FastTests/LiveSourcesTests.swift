import Foundation
import Testing
@testable import Fast

// The sources a live folder can have, held to answers in the shapes their
// sites gave on 2026-09-28 (every name, title and id made up), and the
// rules of a new-for-you folder.
struct LiveSourcesTests {
    @Test func issues() {
        let json = #"""
        {"payload":{"blackbirdSearchRoute":{"results":[
          {"number":12,"state":"open","hl_title":"Crash when <em>waking</em> &amp; floating","created":"2026-09-28T08:00:00Z",
           "repo":{"repository":{"name":"yab","owner_login":"acme"}}},
          {"number":13,"state":"closed","hl_title":"Old","repo":{"repository":{"name":"yab","owner_login":"acme"}}}
        ]}}}
        """#
        let found = LiveIssues.issues(Data(json.utf8), status: 200, finalURL: nil)
        #expect(found?.count == 1)
        #expect(found?.first?.title == "Crash when waking & floating")
        #expect(found?.first?.repo == "acme/yab")
        #expect(found?.first?.created != nil)
        #expect(LiveIssues.issues(Data("<html>".utf8), status: 200, finalURL: nil) == nil)
        #expect(LiveIssues.searchURL(host: "github.com", list: "assignee")?.absoluteString
                == "https://github.com/search?q=is:issue%20is:open%20archived:false%20assignee:@me&type=issues")
        #expect(LiveText.key(URL(string: "https://github.com/Acme/Yab/issues/12#issuecomment-1")) == "github.com/acme/yab/issues/12")
    }

    @Test func followedRepoReadsOnlyRecent() {
        let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
        var live = Live(source: "github.search", host: "github.com", show: [], query: "is:pr is:open repo:acme/yab")
        #expect(live.followed == "acme/yab")
        #expect(live.searched(now: now) == "is:pr is:open repo:acme/yab updated:>=2026-10-02")
        live.days = 30
        #expect(live.searched(now: now) == "is:pr is:open repo:acme/yab updated:>=2026-09-09")
        live.days = 0
        #expect(live.searched(now: now) == "is:pr is:open repo:acme/yab")
        let kept = Live(source: "github.search", host: "github.com", show: [], query: "is:pr is:open repo:acme/yab label:urgent")
        #expect(kept.followed == nil)
        #expect(kept.searched(now: now) == kept.query)
    }

    @Test func searches() {
        #expect(LiveIssues.search(in: URL(string: "https://github.com/search?q=label%3Aurgent+is%3Aopen&type=issues"))! == ("label:urgent is:open", false))
        #expect(LiveIssues.search(in: URL(string: "https://github.com/pulls?q=is%3Aopen+author%3A%40me"))! == ("is:open author:@me", true))
        #expect(LiveIssues.search(in: URL(string: "https://github.com/search?q=yab&type=repositories")) == nil)
        #expect(LiveIssues.search(in: URL(string: "https://github.com/acme/yab")) == nil)
        let live = Live(source: "github.search", host: "github.com", show: [], query: "is:pr label:urgent")
        #expect(LiveIssues.searchPage(live)?.absoluteString == "https://github.com/search?q=is:pr%20label:urgent&type=pullrequests")
        let json = #"""
        {"payload":{"blackbirdSearchRoute":{"results":[
          {"number":5,"state":"open","hl_title":"Speed up","issue":{"issue":{"pull_request_id":99}},"repo":{"repository":{"name":"yab","owner_login":"acme"}}},
          {"number":6,"state":"open","hl_title":"Bug","issue":{"issue":{"pull_request_id":null}},"repo":{"repository":{"name":"yab","owner_login":"acme"}}}]}}}
        """#
        let found = LiveIssues.issues(Data(json.utf8), status: 200, finalURL: nil) ?? []
        #expect(found.map(\.pull) == [true, false])
    }

    @Test func linear() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let json = #"{"data":{"viewer":{"assignedIssues":{"nodes":[{"identifier":"YAB-12","title":"Pin counts","url":"https://linear.app/acme/issue/YAB-12/pin-counts","dueDate":"2026-09-01","createdAt":"2026-08-01T10:00:00.000Z","team":{"key":"YAB"}},{"identifier":"YAB-13","title":"Feeds","url":"https://linear.app/acme/issue/YAB-13","dueDate":null,"createdAt":"2026-09-21T10:00:00.000Z","team":{"key":"YAB"}}]}}}}"#
        let items = LiveLinear.issues(Data(json.utf8), now: now) ?? []
        #expect(items.map(\.title) == ["YAB-12 Pin counts", "YAB-13 Feeds"])
        #expect(items.first?.words == .late)
        #expect(items.first?.group == "YAB")
        #expect(LiveLinear.issues(Data(#"{"errors":[{"message":"no"}]}"#.utf8)) == nil)
        #expect((try? JSONSerialization.jsonObject(with: Data(LiveLinear.query.utf8))) != nil)
        #expect((try? JSONSerialization.jsonObject(with: Data(LiveLinear.accountsQuery.utf8))) != nil)
    }

    // `notifications` from Linear's API on 2026-10-15 (three
    // workspaces, read only): issue notifications with `type`, `readAt`
    // and the issue, a product announcement with none.
    @Test func linearMentions() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let json = #"""
        {"data":{"notifications":{"nodes":[
          {"type":"issueNewComment","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T09:00:00.000Z",
           "actor":{"name":"dan"},"comment":{"body":"Works on **26.1**, see [the build](https://example.com/b) too"},
           "issue":{"identifier":"YAB-226","title":"Calls: Teams window","url":"https://linear.app/acme/issue/YAB-226/calls","team":{"key":"YAB"},"assignee":{"isMe":true},"creator":{"isMe":false}}},
          {"type":"issueCommentMention","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T10:00:00.000Z",
           "actor":{"name":"mira"},"comment":{"body":"@sam which one ships?"},
           "issue":{"identifier":"YAB-231","title":"Pointer capsule","url":"https://linear.app/acme/issue/YAB-231/pointer","team":{"key":"YAB"},"assignee":null,"creator":{"isMe":false}}},
          {"type":"issueMention","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T08:00:00.000Z",
           "actor":{"name":"mira"},"comment":null,
           "issue":{"identifier":"YAB-231","title":"Pointer capsule","url":"https://linear.app/acme/issue/YAB-231/pointer","team":{"key":"YAB"},"assignee":null,"creator":{"isMe":false}}},
          {"type":"issueNewComment","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T07:00:00.000Z",
           "actor":{"name":"kai"},"comment":{"body":"Subscribed only"},
           "issue":{"identifier":"YAB-300","title":"Not yours","url":"https://linear.app/acme/issue/YAB-300/x","team":{"key":"YAB"},"assignee":{"isMe":false},"creator":{"isMe":false}}},
          {"type":"issueNewComment","readAt":"2026-10-14T11:00:00.000Z","archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T06:00:00.000Z",
           "actor":{"name":"dan"},"comment":{"body":"Read already"},
           "issue":{"identifier":"YAB-12","title":"Read","url":"https://linear.app/acme/issue/YAB-12/r","team":{"key":"YAB"},"assignee":{"isMe":true},"creator":{"isMe":true}}},
          {"type":"issueCommentMention","readAt":null,"archivedAt":null,"snoozedUntilAt":"2026-12-01T00:00:00.000Z","createdAt":"2026-10-14T05:00:00.000Z",
           "actor":{"name":"dan"},"comment":{"body":"Snoozed"},
           "issue":{"identifier":"YAB-13","title":"Later","url":"https://linear.app/acme/issue/YAB-13/l","team":{"key":"YAB"},"assignee":{"isMe":true},"creator":{"isMe":true}}},
          {"type":"issueStatusChanged","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T04:00:00.000Z","actor":{"name":"dan"},"comment":null,
           "issue":{"identifier":"YAB-14","title":"Done","url":"https://linear.app/acme/issue/YAB-14/d","team":{"key":"YAB"},"assignee":{"isMe":true},"creator":{"isMe":true}}},
          {"type":"productAnnouncement","readAt":null,"archivedAt":null,"snoozedUntilAt":null,"createdAt":"2026-10-14T03:00:00.000Z"}
        ]}}}
        """#
        let items = LiveLinear.notes(Data(json.utf8), now: now) ?? []
        // Newest first, one row an issue: the comment mention, not the
        // older mention in the description.
        #expect(items.map(\.key) == ["linear/YAB-231", "linear/YAB-226"])
        #expect(items.map(\.words) == [.mention, .comment])
        #expect(items.map(\.list) == ["mentions", "mentions"])
        #expect(items.first?.quote == "@sam which one ships?")
        #expect(items.first?.person == "mira")
        #expect(items.last?.quote == "Works on 26.1, see the build too")
        #expect(items.last?.title == "YAB-226 Calls: Teams window")
        #expect(LiveLinear.notes(Data(#"{"errors":[{"message":"no"}]}"#.utf8)) == nil)
        #expect((try? JSONSerialization.jsonObject(with: Data(LiveLinear.notificationsQuery.utf8))) != nil)
        #expect(!LiveLinear.notificationsQuery.contains("mutation"))
        // One query a workspace for both lists, mentions filtered by type
        // on Linear's side (its filter has no readAt).
        let both = LiveLinear.reading(["assigned", "mentions"])
        #expect(both.contains("assignedIssues") && both.contains("notifications(first: 50, filter: { type: { in:"))
        #expect(!LiveLinear.query.contains("notifications") && !LiveLinear.notificationsQuery.contains("assignedIssues"))
        #expect(LiveLinear.quote("fixed in #412, see snake_case_name and a > b") == "fixed in #412, see snake_case_name and a > b")
        #expect(LiveLinear.quote("> quoted\n# Head\n- item _em_ `code` ~~gone~~") == "quoted Head item em code gone")
        let long = LiveLinear.quote(String(repeating: "word ", count: 30)) ?? ""
        #expect(long.hasSuffix("…") && long.count <= 61)
        #expect(LiveLinear.quote("  \n ") == nil)
    }

    /// My Issues with its mentions: assigned ones go when done, mentions a
    /// day after they're opened, and a thing both list is to do.
    @Test func linearMixedFolder() {
        let now = Date(timeIntervalSince1970: 1_792_000_000)
        let url = URL(string: "https://linear.app/acme/issue/YAB-1")!
        func item(_ id: String, _ list: String, _ words: LiveWords?) -> LiveItem {
            LiveItem(key: "linear/" + id, url: url, title: id, group: "YAB", words: words, updated: now.addingTimeInterval(-60), list: list)
        }
        let news: Set<String> = ["mentions"]
        let source = LiveSource.of("linear")
        #expect(source?.newsLists == news)
        #expect(source?.lists.map(\.id) == ["assigned", "mentions"])
        #expect(source?.shownAtFirst == ["assigned", "mentions"])
        #expect(Live(source: "linear", host: "linear.app", show: []).shown == ["assigned", "mentions"])
        #expect(Live(source: "linear", host: "linear.app", show: ["mentions"]).shown == ["mentions"])
        #expect(LiveSource.of("notion")?.newsLists == [])

        // First reading: both kinds come in; a thing both list comes once, as to do.
        let first = LiveFolder.mixed([item("YAB-2", "mentions", .mention), item("YAB-3", "mentions", .comment), item("YAB-3", "assigned", nil),
                                      item("YAB-4", "assigned", .late)],
                                     news: news, held: [], today: [:], elsewhere: [], hidden: [], shown: [], first: true, now: now)
        #expect(first.add.map(\.key) == ["linear/YAB-2", "linear/YAB-3", "linear/YAB-4"])
        #expect(first.add.map(\.list) == ["mentions", "assigned", "assigned"])

        // Later: the mention, read on Linear, is no longer listed but stays
        // until a day after you opened it; the done issue goes at once.
        let ids = (UUID(), UUID(), UUID())
        var held = [
            LiveFolder.Held(id: ids.0, key: "linear/YAB-2", brought: true, words: .mention, came: now.addingTimeInterval(-3600), news: true),
            LiveFolder.Held(id: ids.1, key: "linear/YAB-4", brought: true, words: .late),
            LiveFolder.Held(id: ids.2, key: "linear/YAB-5", brought: true, words: .comment, came: now.addingTimeInterval(-3600),
                            opened: now.addingTimeInterval(-25 * 3600), news: true),
        ]
        var later = LiveFolder.mixed([], news: news, held: held, today: [:], elsewhere: [], hidden: [],
                                     shown: ["linear/YAB-2", "linear/YAB-5"], first: false, now: now)
        #expect(Set(later.remove) == [ids.1, ids.2])
        #expect(later.add.isEmpty)

        // A mention shown once never comes back; one a tab holds as news
        // isn't brought again as to do.
        held.removeLast()
        later = LiveFolder.mixed([item("YAB-2", "assigned", nil), item("YAB-9", "mentions", .mention), item("YAB-4", "assigned", .late)],
                                 news: news, held: held, today: [:], elsewhere: [], hidden: [], shown: ["linear/YAB-2", "linear/YAB-9"],
                                 first: false, now: now)
        #expect(later.add.isEmpty)
        #expect(later.remove.isEmpty)

        // A mention of an issue open in today's moves that tab in; one
        // kept elsewhere stays out.
        let open = UUID()
        let moved = LiveFolder.mixed([item("YAB-20", "mentions", .mention), item("YAB-21", "mentions", .comment)], news: news, held: [],
                                     today: ["linear/YAB-20": open], elsewhere: ["linear/YAB-21"], hidden: [], shown: [], first: false, now: now)
        #expect(moved.add.map(\.key) == ["linear/YAB-20"])
        #expect(moved.adopt == ["linear/YAB-20": open])

        // What it has shown: what mentions brought, and on a first reading
        // all they listed; never a to-do thing.
        let listed = [item("YAB-30", "mentions", .mention), item("YAB-31", "mentions", .mention), item("YAB-32", "assigned", nil)]
        #expect(LiveFolder.shown(listed, kind: .toDo, news: news, added: [listed[0], listed[2]], before: ["x"], first: false)
                == ["x", "linear/YAB-30"])
        #expect(LiveFolder.shown(listed, kind: .toDo, news: news, added: [], before: [], first: true) == ["linear/YAB-30", "linear/YAB-31"])
        #expect(LiveFolder.shown(listed, kind: .news, news: [], added: [listed[2]], before: [], first: false) == ["linear/YAB-32"])

        // Twelve mentions at most, to-do ones not counted.
        let many = (1...20).map { item("M-\($0)", "mentions", .mention) }
        let full = LiveFolder.mixed(many, news: news, held: held, today: [:], elsewhere: [], hidden: [], shown: [], first: false, now: now)
        #expect(full.add.count == LiveFolder.fewest - 1)
    }

    @Test func linearAccounts() {
        let json = #"{"data":{"availableUsers":{"id":"a","users":[{"id":"u1","active":true,"organization":{"urlKey":"acme"}},{"id":"u2","active":false,"organization":{"urlKey":"old"}},{"id":"u3","active":true,"organization":{"urlKey":"lab"}}]}}}"#
        #expect(LiveLinear.accounts(Data(json.utf8)) == [.init(user: "u1", workspace: "acme"), .init(user: "u3", workspace: "lab")])
        let refused = #"{"errors":[{"message":"Authentication required","extensions":{"code":"AUTHENTICATION_ERROR"}}]}"#
        #expect(LiveLinear.refused(LiveReader.Answer(status: 400, url: nil, data: Data(refused.utf8))))
        #expect(LiveLinear.refused(LiveReader.Answer(status: 401, url: nil, data: Data())))
        #expect(!LiveLinear.refused(LiveReader.Answer(status: 200, url: nil, data: Data(json.utf8))))
        #expect(LiveNestMenu.group(URL(string: "https://linear.app/acme/issue/YAB-12/pin-counts"), source: "linear") == "acme")
        #expect(LiveNestMenu.group(URL(string: "https://github.com/acme/yab/pull/3")) == "acme/yab")
    }

    @Test func figmaNotifications() {
        let json = #"""
        {"error":false,"status":200,"meta":{"feed":[
          {"id":"1","view":34,"user_id":"me","track_back":"file_role_request_approved_1","created_at":"2026-09-27T10:00:00.000Z","read_at":null,"resolved_at":null,
           "locals":{"user_id":"me","file_role_request_id":"9","file_name":"Onboarding","level":100,"file_key":"KeyA","editor_type":"design"}},
          {"id":"2","view":1,"user_id":"me","track_back":"file_comments_2","created_at":"2026-09-26T10:00:00.000Z","read_at":null,
           "locals":{"file":{"key":"KeyB","name":"Icons"},"file_key":"KeyB","file_name":"Icons","open_url":"https://www.figma.com/design/KeyB/Icons#12?node-id=1-2",
            "comment":{"id":"12","message_meta":[{"t":"Look, "},{"t":"@Sam","user_id":"me"}]}}},
          {"id":"3","view":2,"user_id":"me","track_back":"file_comments_3","created_at":"2026-09-25T10:00:00.000Z","read_at":null,
           "locals":{"file_key":"KeyB","file_name":"Icons","comment":{"id":"13","message_meta":[{"t":"Older"}]}}},
          {"id":"4","view":2,"user_id":"me","track_back":"file_comments_4","created_at":"2026-09-24T10:00:00.000Z","read_at":null,
           "locals":{"file_key":"KeyC","file_name":"Site","open_url":"https://evil.example/KeyC","comment":{"id":"14","message_meta":[{"t":"Nice"}]}}},
          {"id":"5","view":50,"user_id":"me","track_back":"fig_files_5","created_at":"2026-09-23T10:00:00.000Z","read_at":null,
           "locals":{"file_key":"KeyD","file_name":"Deck"},"batch_locals":{"comment_count":1,"reply_count":3}},
          {"id":"6","view":27,"user_id":"me","track_back":"file_role_request_created_6","created_at":"2026-09-22T10:00:00.000Z","read_at":null,
           "locals":{"file_key":"KeyE","file_name":"Brand"}},
          {"id":"7","view":1,"user_id":"me","track_back":"file_comments_7","created_at":"2026-09-21T10:00:00.000Z","read_at":"2026-09-21T11:00:00.000Z",
           "locals":{"file_key":"KeyF","file_name":"Read"}}
        ]}}
        """#
        let items = LiveFigma.notifications(Data(json.utf8)) ?? []
        #expect(items.map(\.key) == ["figma/KeyA", "figma/KeyB", "figma/KeyC", "figma/KeyD", "figma/KeyE"])
        #expect(items.map(\.words) == [.shared, .mention, .comment, .comment, .request])
        #expect(items.map(\.title) == ["Onboarding", "Icons", "Site", "Deck", "Brand"])
        #expect(items[1].url.absoluteString == "https://www.figma.com/design/KeyB/Icons#12?node-id=1-2")
        #expect(items[0].url.absoluteString == "https://www.figma.com/file/KeyA")
        #expect(items[2].url.absoluteString == "https://www.figma.com/file/KeyC")
        #expect(items[0].updated == LiveFigma.date("2026-09-27T10:00:00Z"))
        #expect(LiveWords.request.needsYou)
        #expect(LiveFigma.notifications(Data(#"{"error":true,"status":401,"reason":"missing_authentication"}"#.utf8)) == nil)
    }

    @Test func figmaChanged() {
        let now = LiveFigma.date("2026-09-28T12:00:00Z")!
        let json = #"""
        {"meta":{"recent_files":[
          {"key":"K1","name":"Edited since","url":"https://www.figma.com/file/K1","touched_at":"2026-09-27T10:00:00Z","accessed_at":"2026-09-26T10:00:00Z","trashed_at":null},
          {"key":"K2","name":"Opened since","url":"https://www.figma.com/file/K2","touched_at":"2026-09-26T10:00:00Z","accessed_at":"2026-09-27T10:00:00Z"},
          {"key":"K3","name":"Long ago","url":"https://www.figma.com/file/K3","touched_at":"2026-08-01T10:00:00Z","accessed_at":"2026-07-01T10:00:00Z"},
          {"key":"K4","name":"Trashed","touched_at":"2026-09-27T10:00:00Z","accessed_at":"2026-09-26T10:00:00Z","trashed_at":"2026-09-27T11:00:00Z"}
        ]}}
        """#
        let files = LiveFigma.recent(Data(json.utf8)) ?? []
        #expect(files.map(\.key) == ["K1", "K2", "K3"])
        #expect(LiveFigma.candidates(files, now: now).map(\.key) == ["K1"])
        let since = LiveFigma.date("2026-09-26T10:00:00Z")!
        let theirs = #"{"meta":{"versions":[{"user_id":"sam","touched_at":"2026-09-27T10:00:00Z","participating_users_array":["Sam Lee"]},{"user_id":"me","touched_at":"2026-09-20T10:00:00Z"}]}}"#
        let mine = #"{"meta":{"versions":[{"user_id":"me","touched_at":"2026-09-27T10:00:00Z","participating_users_array":["Me Myself"]},{"user_id":"sam","touched_at":"2026-09-20T10:00:00Z"}]}}"#
        #expect(LiveFigma.others(Data(theirs.utf8), since: since, me: "me") == true)
        #expect(LiveFigma.others(Data(mine.utf8), since: since, me: "me") == false)
        #expect(LiveFigma.me(Data(#"{"meta":{"users":[{"id":"me","name":"Sam"}]}}"#.utf8)) == "me")
        #expect(LiveSource.of("figma")?.owns("www.figma.com") == true)
        #expect(LiveSource.of("figma")?.kind == .news)
    }

    @Test func notionInbox() {
        let json = #"""
        {"notificationIds":["n1","n2","n3"],
         "recordMap":{
          "notification":{
            "n1":{"spaceId":"s","value":{"value":{"id":"n1","type":"user-mentioned","read":false,"navigable_block_id":"1111-2222","space_id":"s","end_time":"1790000000000","channel":"mentions"},"role":"editor"}},
            "n2":{"spaceId":"s","value":{"value":{"id":"n2","type":"commented","read":false,"navigable_block_id":"3333","space_id":"s"},"role":"editor"}},
            "n3":{"spaceId":"s","value":{"value":{"id":"n3","type":"commented","read":true,"navigable_block_id":"4444","space_id":"s"},"role":"editor"}}},
          "block":{
            "1111-2222":{"spaceId":"s","value":{"value":{"id":"1111-2222","properties":{"title":[["Q4 "],["roadmap",[["b"]]]]}},"role":"editor"}}}}}
        """#
        let items = LiveNotion.inbox(Data(json.utf8)) ?? []
        #expect(items.count == 2)
        #expect(items.first?.title == "Q4 roadmap")
        #expect(items.first?.words == .mention)
        #expect(items.first?.url.absoluteString == "https://www.notion.so/11112222")
        #expect(items.first?.updated != nil)
        #expect(items.last?.words == .comment)
        #expect(items.last?.title == "Untitled")
        #expect(LiveNotion.words("user-invited") == .shared)
        #expect(LiveNotion.words("access-requested") == .shared)
        #expect(LiveNotion.words("user-mentioned") == .mention)
        #expect(LiveNotion.words("commented") == .comment)
        let sync = #"{"recordMap":{"block":{"b1":{"value":{"value":{"id":"b1","properties":{"title":[["Plan"]]}}}}}}}"#
        #expect(LiveNotion.titles(Data(sync.utf8)) == ["b1": "Plan"])
        #expect(LiveNotion.titlesBody([("b1", "s1")]).contains(#""pointer":{"table":"block","id":"b1","spaceId":"s1"}"#))
        let counts = #"{"results":[{"spaceId":"a","unread":{"mentions":2,"following":5,"nonMentions":1}},{"spaceId":"b","unread":{"mentions":0,"nonMentions":0}}]}"#
        #expect(LiveNotion.unread(Data(counts.utf8)) == ["a": 3, "b": 0])
    }

    @Test func notionChanged() {
        let json = #"""
        {"pages":[{"id":"p1","visitedAt":1790000000000},{"id":"p2","visitedAt":1790000000000}],
         "recordMap":{"block":{
          "p1":{"value":{"value":{"id":"p1","last_edited_time":1790000900000,"last_edited_by_id":"other","properties":{"title":[["Spec"]]}}}},
          "p2":{"value":{"value":{"id":"p2","last_edited_time":1790000900000,"last_edited_by_id":"me"}}}}}}
        """#
        let items = LiveNotion.changed(Data(json.utf8), me: "me")
        #expect(items.map(\.title) == ["Spec"])
        #expect(items.first?.words == .changed)
    }

    @Test func drive() {
        var file: [Any] = Array(repeating: NSNull(), count: 120)
        file[0] = "1AbCdEfGhIjKlMnOpQrStUvWxYz0123"
        file[2] = "Budget"
        file[3] = "application/vnd.google-apps.spreadsheet"
        file[10] = 1_790_000_900_000.0
        file[12] = 1_790_000_000_000.0
        file[22] = 1_790_000_500_000.0
        file[114] = "https://docs.google.com/spreadsheets/d/x/edit"
        var folder = file
        folder[0] = "1FoLdErFoLdErFoLdErFoLdErFoLdEr"
        folder[3] = "application/vnd.google-apps.folder"
        let data = try! JSONSerialization.data(withJSONObject: [[file, folder], NSNull()])
        let escaped = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"", with: "\\x22").replacingOccurrences(of: "/", with: "\\/")
        let html = "<script>window['_DRIVE_ivd'] = '\(escaped)';</script>"
        let files = LiveDrive.files(html) ?? []
        #expect(files.count == 2)
        #expect(files.first?.title == "Budget")
        #expect(files.first?.url?.host() == "docs.google.com")
        #expect(files.first!.modified! > files.first!.viewed!)
        #expect(files.first?.shared != nil)
        #expect(LiveDrive.files("<html>") == nil)
    }

    @Test func youtube() {
        let data = #"""
        {"contents":{"x":{"richShelfRenderer":{"contents":[
          {"richItemRenderer":{"content":{"lockupViewModel":{"contentId":"abcDEF12345","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
            "metadata":{"lockupMetadataViewModel":{"title":{"content":"A talk"},
              "metadata":{"contentMetadataViewModel":{"metadataRows":[{"metadataParts":[{"text":{"content":"A channel"}}]}]}}}}}}}},
          {"richItemRenderer":{"content":{"shortsLockupViewModel":{"entityId":"short"}}}}]}}}}
        """#
        let html = "<script>var ytInitialData = \(data);</script>"
        let videos = LiveYouTube.videos(html) ?? []
        #expect(videos == [LiveYouTube.Video(id: "abcDEF12345", title: "A talk", channel: "A channel")])
        #expect(LiveYouTube.videos("<html>") == nil)
    }

    @Test func feeds() {
        let rss = #"""
        <?xml version="1.0"?><rss version="2.0"><channel><title>Blog</title>
        <item><title>Hello &amp; welcome</title><link>https://blog.example/hello</link><guid>h1</guid><pubDate>Mon, 28 Sep 2026 10:00:00 +0000</pubDate></item>
        <item><title><![CDATA[Second]]></title><link>https://blog.example/2</link></item>
        </channel></rss>
        """#
        let items = LiveFeed.entries(Data(rss.utf8)) ?? []
        #expect(items.map(\.title) == ["Hello & welcome", "Second"])
        #expect(items.first?.id == "h1")
        #expect(items.first?.at != nil)
        #expect(items.last?.id == "https://blog.example/2")
        let atom = #"""
        <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>Releases</title>
        <entry><id>tag:1</id><title>v1.2</title><link rel="alternate" href="https://example.com/v1.2"/><updated>2026-09-28T10:00:00Z</updated></entry>
        </feed>
        """#
        #expect(LiveFeed.entries(Data(atom.utf8))?.first?.link.absoluteString == "https://example.com/v1.2")
    }

    @Test func gmail() {
        let feed = #"""
        <?xml version="1.0" encoding="UTF-8"?><feed version="0.3" xmlns="http://purl.org/atom/ns#"><fullcount>23707</fullcount>
        <entry><title>Lunch?</title><summary>Are you free</summary><link rel="alternate" href="https://mail.google.com/mail/u/0?message_id=1&amp;view=conv" type="text/html"/>
        <modified>2026-09-28T10:00:00Z</modified><issued>2026-09-28T10:00:00Z</issued><id>tag:gmail.google.com,2004:1</id>
        <author><name>Anna</name><email>anna@example.com</email></author></entry></feed>
        """#
        #expect(LiveGmail.count(Data(feed.utf8)) == 23707)
        let entries = LiveFeed.entries(Data(feed.utf8)) ?? []
        #expect(entries.first?.author == "Anna")
        #expect(entries.first?.title == "Lunch?")
        #expect(entries.first?.at != nil)
        #expect(LiveGmail.account(URL(string: "https://mail.google.com/mail/u/1/#inbox")) == "1")
        #expect(LiveGmail.account(URL(string: "https://mail.google.com/mail/")) == "0")
        // Primary only, as Gmail's own count (#314).
        #expect(LiveGmail.feed(account: "1")?.absoluteString == "https://mail.google.com/mail/u/1/feed/atom/%5Esq_ig_i_personal")
    }
}

struct LinkSummaryTests {
    @Test func page() {
        let html = #"""
        <html><head><title>Old &amp; plain</title>
        <meta property="og:title" content="Nginx as a reverse proxy">
        <meta name="description" content="How to put Nginx in front of Node.">
        <meta content="Acme Docs" property="og:site_name">
        <style>body{}</style><script>var x = "<p>not this</p>";</script></head>
        <body><h1>Nginx</h1><p>Put it in front of your app &amp; sleep well.</p></body></html>
        """#
        let page = LinkSummary.read(html)
        #expect(page.title == "Nginx as a reverse proxy")
        #expect(page.description == "How to put Nginx in front of Node.")
        #expect(page.site == "Acme Docs")
        #expect(page.text.contains("Put it in front of your app & sleep well."))
        #expect(!page.text.contains("not this"))
        let url = URL(string: "https://docs.acme.dev/nginx")!
        #expect(LinkSummary.words(page, gist: nil, url: url) == "Nginx as a reverse proxy\nHow to put Nginx in front of Node.")
        #expect(LinkSummary.words(page, gist: "A guide.", url: url) == "Nginx as a reverse proxy\nA guide.")
        #expect(LinkSummary.words(LinkSummary.Page(), gist: nil, url: url) == "docs.acme.dev/nginx")
        #expect(LinkSummary.plain("This page shows how a folder fills itself.") == "Shows how a folder fills itself.")
        #expect(LinkSummary.plain("The article is about Nginx.") == "Nginx.")
        #expect(LinkSummary.plain("A guide to Nginx.") == "A guide to Nginx.")
    }
}

struct LiveNewsTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ n: Int, hoursAgo: Double? = nil) -> LiveItem {
        LiveItem(key: "notion/\(n)", url: URL(string: "https://www.notion.so/\(n)")!, title: "Page \(n)", group: "", words: .mention,
                 updated: hoursAgo.map { now.addingTimeInterval(-$0 * 3600) })
    }

    @Test func freshOnlyAtFirst() {
        let diff = LiveFolder.news([Self.item(1, hoursAgo: 2), Self.item(2, hoursAgo: 200)], held: [], shown: [], hidden: [], first: true, now: Self.now)
        #expect(diff.add.map(\.key) == ["notion/1"])
        let later = LiveFolder.news([Self.item(1, hoursAgo: 2), Self.item(2, hoursAgo: 200)], held: [], shown: [], hidden: [], first: false, now: Self.now)
        #expect(later.add.count == 2)
    }

    @Test func neverTwice() {
        let diff = LiveFolder.news([Self.item(1, hoursAgo: 1)], held: [], shown: ["notion/1"], hidden: [], first: false, now: Self.now)
        #expect(diff.add.isEmpty)
    }

    @Test func goesADayAfterOpened() {
        let id = UUID(), fresh = UUID(), old = UUID()
        let held = [
            LiveFolder.Held(id: id, key: "notion/1", brought: true, came: Self.now.addingTimeInterval(-3 * 86400), opened: Self.now.addingTimeInterval(-2 * 86400)),
            LiveFolder.Held(id: fresh, key: "notion/2", brought: true, came: Self.now.addingTimeInterval(-3600), opened: Self.now.addingTimeInterval(-600)),
            LiveFolder.Held(id: old, key: "notion/3", brought: true, came: Self.now.addingTimeInterval(-8 * 86400)),
        ]
        let diff = LiveFolder.news([], held: held, shown: [], hidden: [], first: false, now: Self.now)
        #expect(Set(diff.remove) == [id, old])
    }

    @Test func twelveAtMost() {
        let items = (1...20).map { Self.item($0, hoursAgo: 1) }
        #expect(LiveFolder.news(items, held: [], shown: [], hidden: [], first: false, now: Self.now).add.count == LiveFolder.fewest)
    }
}
