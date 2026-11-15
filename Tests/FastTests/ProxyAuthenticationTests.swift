import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ProxyAuthenticationTests {
    @Test func cancelCoalescesConcurrentRequestsAndSuppressesLaterTabs() {
        let gate = ProxyAuthentication()
        var prompts = 0
        var answers: [PageAuthenticationReply] = []
        var finish: (@MainActor (PageAuthenticationReply) -> Void)?
        func request(_ host: String = "proxy.test", scope: String = "profile", port: Int = 8080, configuration: String = "a") {
            gate.authenticate(scope: scope, host: host, port: port, realm: "VPN", method: "basic",
                configuration: configuration, reply: { answers.append($0) }) { prompts += 1; finish = $0 }
        }
        request(); request("PROXY.TEST"); request()
        #expect(prompts == 1 && answers.isEmpty)
        finish?(.cancel)
        #expect(answers == [.cancel, .cancel, .cancel])
        request(); request()
        #expect(prompts == 1 && answers.count == 5)
        // A different network profile or proxy endpoint remains usable.
        request(scope: "private"); request(port: 8081)
        #expect(prompts == 3)
        request(configuration: "new proxy setting")
        #expect(prompts == 4)
    }

    @Test func credentialsFanOutAndStaleRepliesCannotAnswerANewChallenge() {
        let gate = ProxyAuthentication()
        var callbacks: [@MainActor (PageAuthenticationReply) -> Void] = []
        var answers: [PageAuthenticationReply] = []
        func request() {
            gate.authenticate(scope: "profile", host: "proxy", port: 80, realm: nil, method: "basic",
                reply: { answers.append($0) }) { callbacks.append($0) }
        }
        request(); request()
        let credentials = PageAuthenticationReply.credential(user: "user", password: "secret")
        callbacks[0](credentials); callbacks[0](.cancel)
        #expect(answers == [credentials, credentials])
        request()
        #expect(callbacks.count == 2)
        gate.reset(scope: "profile")
        #expect(answers.last == .cancel)
        request()
        callbacks[1](credentials)
        #expect(answers.count == 3)
        callbacks[2](.cancel)
        #expect(answers.count == 4)
    }

    @Test func defaultHandlingCannotReopenASystemProxyPrompt() {
        let gate = ProxyAuthentication()
        var answers: [PageAuthenticationReply] = []
        var prompts = 0
        for _ in 0..<2 {
            gate.authenticate(scope: "profile", host: "proxy", port: 80, realm: nil, method: "basic",
                reply: { answers.append($0) }) { answer in prompts += 1; answer(.performDefaultHandling) }
        }
        #expect(prompts == 1 && answers == [.cancel, .cancel])
    }
}
