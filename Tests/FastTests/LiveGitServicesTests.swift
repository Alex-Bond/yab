import Foundation
import Testing
@testable import Fast

// Synthetic answers in the providers' documented shapes. No account, cookie,
// network request or browser window is used by these contract tests.
struct LiveGitServicesTests {
    private struct Fixture {
        let service: LiveGitService
        let repository: String
        let request: String
        let item: String
        let closed: String
    }

    private static let fixtures: [Fixture] = [
        Fixture(service: .gitlab, repository: "https://gitlab.com/acme/yab",
                request: "https://gitlab.com/api/v4/projects/acme%2Fyab/merge_requests?state=opened&per_page=50&page=1",
                item: "https://gitlab.com/acme/yab/-/merge_requests/11", closed: "merged"),
        Fixture(service: .bitbucket, repository: "https://bitbucket.org/acme/yab",
                request: "https://api.bitbucket.org/2.0/repositories/acme/yab/pullrequests?state=OPEN&pagelen=50",
                item: "https://bitbucket.org/acme/yab/pull-requests/11", closed: "MERGED"),
        Fixture(service: .codeberg, repository: "https://codeberg.org/acme/yab",
                request: "https://codeberg.org/api/v1/repos/acme/yab/pulls?state=open&limit=50&page=1",
                item: "https://codeberg.org/acme/yab/pulls/11", closed: "closed"),
        Fixture(service: .sourcehut, repository: "https://todo.sr.ht/~acme/bugs",
                request: "https://todo.sr.ht/query",
                item: "https://todo.sr.ht/~acme/bugs/11", closed: "RESOLVED"),
        Fixture(service: .gitee, repository: "https://gitee.com/acme/yab",
                request: "https://gitee.com/api/v5/repos/acme/yab/pulls?state=open&per_page=50&page=1",
                item: "https://gitee.com/acme/yab/pulls/11", closed: "closed"),
        Fixture(service: .gitea, repository: "https://gitea.com/acme/yab",
                request: "https://gitea.com/api/v1/repos/acme/yab/pulls?state=open&limit=50&page=1",
                item: "https://gitea.com/acme/yab/pulls/11", closed: "closed"),
    ]

    private func row(_ fixture: Fixture, state: String? = nil, link: String? = nil) -> [String: Any] {
        let title = "Review sidebar"
        let date = "2026-10-24T07:00:00Z"
        switch fixture.service {
        case .gitlab:
            return ["iid": 11, "title": title, "web_url": link ?? fixture.item,
                    "state": state ?? "opened", "updated_at": date]
        case .bitbucket:
            return ["id": 11, "title": title, "links": ["html": ["href": link ?? fixture.item]],
                    "state": state ?? "OPEN", "updated_on": date]
        case .sourcehut:
            return ["id": 11, "subject": title, "status": state ?? "REPORTED", "updated": date]
        case .codeberg, .gitee, .gitea:
            return ["id": 101, "number": 11, "title": title, "html_url": link ?? fixture.item,
                    "state": state ?? "open", "updated_at": date]
        }
    }

    private func payload(_ fixture: Fixture, rows: [[String: Any]], next: String? = nil) throws -> Data {
        let value: Any
        switch fixture.service {
        case .bitbucket:
            var page: [String: Any] = ["values": rows]
            if let next { page["next"] = next }
            value = page
        case .sourcehut:
            value = ["data": ["user": ["tracker": ["tickets": [
                "results": rows, "cursor": next.map { $0 as Any } ?? NSNull(),
            ]]]]]
        default:
            value = rows
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func parse(_ fixture: Fixture, _ data: Data, status: Int = 200, final: String? = nil) -> LiveRead {
        fixture.service.parse(data, status: status, finalURL: URL(string: final ?? fixture.request),
                              repository: URL(string: fixture.repository)!)
    }

    private func items(_ result: LiveRead) -> [LiveItem] {
        guard case .items(let items) = result else {
            Issue.record("A valid complete fixture must produce items: \(result)")
            return []
        }
        return items
    }

    @Test func allSixProvidersHaveExactRepositoryAndRequestContracts() throws {
        #expect(Set(LiveGitService.allCases.map(\.rawValue))
                == ["gitlab", "bitbucket", "codeberg", "sourcehut", "gitee", "gitea"])
        for fixture in Self.fixtures {
            let service = fixture.service
            let repository = try #require(service.repository(fixture.repository))
            #expect(repository.absoluteString == fixture.repository)
            #expect(service.sourceID == service.rawValue + (service == .sourcehut ? ".tickets" : ".pulls"))
            let request = try #require(service.request(for: repository))
            #expect(request.url.absoluteString == fixture.request)
            if service == .sourcehut {
                let body = try #require(request.body)
                let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
                let query = try #require(json["query"] as? String)
                #expect(query.contains("user(username:"))
                #expect(query.contains("tracker(name:"))
                #expect(query.contains("tickets(cursor:"))
                let variables = try #require(json["variables"] as? [String: Any])
                #expect(variables["u"] as? String == "acme")
                #expect(variables["t"] as? String == "bugs")
                #expect(variables["c"] is NSNull)
            } else {
                #expect(request.body == nil)
            }
        }
    }

    @Test func onlyDeclaredProvidersAcceptSelfHostedRepositories() throws {
        for service in [LiveGitService.gitlab, .gitee, .gitea] {
            let repository = try #require(service.repository("https://forge.acme.invalid/team/yab"))
            let request = try #require(service.request(for: repository))
            #expect(request.url.host == "forge.acme.invalid")
            #expect(request.url.scheme == "https")
        }
        for service in [LiveGitService.bitbucket, .codeberg, .sourcehut] {
            #expect(service.repository("https://forge.acme.invalid/team/yab") == nil)
        }
        let nested = try #require(LiveGitService.gitlab.repository("https://git.acme.invalid/engineering/tools/yab"))
        #expect(LiveGitService.gitlab.request(for: nested)?.url.absoluteString
                == "https://git.acme.invalid/api/v4/projects/engineering%2Ftools%2Fyab/merge_requests?state=opened&per_page=50&page=1")
        for fixture in Self.fixtures where fixture.service != .gitlab {
            #expect(fixture.service.repository(fixture.repository + "/extra") == nil)
        }
    }

    @Test func onlyGitLabMayReadTheSpacesSessionCookies() {
        for service in LiveGitService.allCases {
            #expect(service.allowsSessionCookies == (service == .gitlab))
        }
    }

    @Test func repositoryInputsNeverSmuggleCredentialsOrNavigation() {
        for fixture in Self.fixtures {
            let service = fixture.service
            let good = fixture.repository
            let hostAndPath = String(good.dropFirst("https://".count))
            for bad in [
                "http://" + hostAndPath, hostAndPath, "//" + hostAndPath,
                "https://user@" + hostAndPath, "https://user:secret@" + hostAndPath,
                good + "?state=closed", good + "#fragment", good + "/../other",
                good + "/%2e%2e/other", good + "/./other",
            ] {
                #expect(service.repository(bad) == nil, "Rejected repository input: \(bad)")
            }
        }
        #expect(LiveGitService.bitbucket.repository("https://bitbucket.org.attacker.invalid/acme/yab") == nil)
        #expect(LiveGitService.codeberg.repository("https://codeberg.org.attacker.invalid/acme/yab") == nil)
        #expect(LiveGitService.sourcehut.repository("https://git.sr.ht/~acme/bugs") == nil)
        #expect(LiveGitService.sourcehut.repository("https://todo.sr.ht/acme/bugs") == nil)
    }

    @Test func providerFixturesKeepOpenItemsAndDeduplicateTheirURLs() throws {
        for fixture in Self.fixtures {
            let open = row(fixture)
            let data = try payload(fixture, rows: [open, row(fixture, state: fixture.closed), open])
            let found = items(parse(fixture, data))
            #expect(found.count == 1)
            #expect(found.first?.url.absoluteString == fixture.item)
            #expect(found.first?.title.contains("Review sidebar") == true)
            #expect(found.first?.key.isEmpty == false)
            #expect(found.first?.group.isEmpty == false)
            #expect(found.first?.updated != nil)
        }
    }

    @Test func onlyKnownCompleteEmptyAnswersCanRemoveCompletedItems() throws {
        for fixture in Self.fixtures {
            #expect(parse(fixture, try payload(fixture, rows: [])) == .items([]))
            #expect(parse(fixture, try payload(fixture, rows: [row(fixture, state: fixture.closed)])) == .items([]))
            for broken in ["", "<html>Sign in</html>", "{}", "{\"data\":null}", "[null]"] {
                #expect(parse(fixture, Data(broken.utf8)) == .failed)
            }
            var missingState = row(fixture)
            missingState.removeValue(forKey: fixture.service == .sourcehut ? "status" : "state")
            #expect(parse(fixture, try payload(fixture, rows: [row(fixture), missingState])) == .failed)
            #expect(parse(fixture, try payload(fixture, rows: [row(fixture, state: "unexpected-state")])) == .failed)
            #expect(parse(fixture, try payload(fixture, rows: [["state": "open"]])) == .failed)
        }
    }

    @Test func responseAndItemOriginsCannotEscapeTheChosenService() throws {
        for fixture in Self.fixtures {
            let data = try payload(fixture, rows: [row(fixture)])
            #expect(parse(fixture, data, final: "https://outside.invalid/api/list") == .failed)
            #expect(parse(fixture, data, final: fixture.request.replacingOccurrences(of: "https://", with: "http://")) == .failed)
            #expect(parse(fixture, data, final: fixture.request.replacingOccurrences(of: "https://", with: "https://user@")) == .failed)
            #expect(parse(fixture, data, final: fixture.request.replacingOccurrences(of: "https://", with: "https://user:secret@")) == .failed)
            #expect(fixture.service.parse(data, status: 200, finalURL: nil,
                                         repository: URL(string: fixture.repository)!) == .failed)
            if fixture.service != .sourcehut {
                let contaminated = try payload(fixture, rows: [row(fixture), row(fixture, link: "https://outside.invalid/acme/yab/pulls/11")])
                #expect(parse(fixture, contaminated) == .failed)
            }
        }
    }

    @Test func sourceHutTracksItsDocumentedOpenTicketStates() throws {
        let fixture = try #require(Self.fixtures.first { $0.service == .sourcehut })
        for state in ["REPORTED", "CONFIRMED", "IN_PROGRESS", "PENDING"] {
            #expect(items(parse(fixture, try payload(fixture, rows: [row(fixture, state: state)]))).count == 1)
        }
        let valid = try payload(fixture, rows: [])
        var response = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        response["errors"] = [["message": "Tracker unavailable"]]
        let failed = try JSONSerialization.data(withJSONObject: response)
        #expect(parse(fixture, failed) == .failed)
    }

    @Test func incompletePagesAndAuthenticationNeverBecomeAnEmptySuccess() throws {
        for fixture in Self.fixtures {
            let data = try payload(fixture, rows: [row(fixture)])
            #expect(parse(fixture, data, status: 401) == (fixture.service.allowsSessionCookies ? .signedOut : .failed))
            #expect(parse(fixture, data, status: 403) == (fixture.service.allowsSessionCookies ? .signedOut : .failed))
            #expect(parse(fixture, data, status: 500) == .failed)
            #expect(parse(fixture, try payload(fixture, rows: Array(repeating: row(fixture), count: 50))) == .failed)
            if fixture.service == .bitbucket || fixture.service == .sourcehut {
                #expect(parse(fixture, try payload(fixture, rows: [row(fixture)], next: "more")) == .failed)
            }
        }
    }
    @Test func shortPagesCarryTransportPaginationMetadataIntoTheParser() throws {
        for fixture in Self.fixtures {
            let data = try payload(fixture, rows: [row(fixture)])
            for headers in [["Link": "<https://outside.invalid/next>; rel=\"next\""],
                            ["X-Next-Page": "2"], ["X-Page": "1", "X-Total-Pages": "2"]] {
                let response = try #require(HTTPURLResponse(url: URL(string: fixture.request)!, statusCode: 200,
                                                           httpVersion: nil, headerFields: headers))
                let answer = LiveReader.answer(data, response: response)
                #expect(answer.more)
                #expect(fixture.service.parse(answer.data, status: answer.status, finalURL: answer.url,
                                               repository: URL(string: fixture.repository)!, more: answer.more) == .failed)
            }
            let response = try #require(HTTPURLResponse(url: URL(string: fixture.request)!, statusCode: 200,
                                                       httpVersion: nil, headerFields: ["X-Next-Page": "", "Link": "<https://outside.invalid/last>; rel=\"last\""]))
            let answer = LiveReader.answer(data, response: response)
            #expect(!answer.more)
            #expect(items(fixture.service.parse(answer.data, status: answer.status, finalURL: answer.url,
                                                repository: URL(string: fixture.repository)!, more: answer.more)).count == 1)
        }
    }

}
