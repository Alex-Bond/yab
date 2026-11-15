import Testing
@testable import Fast

/// Which of the bench's verbs go to agentCommand and which to its own
/// switch: a verb sent to the wrong one is answered "doesn't know".
@MainActor
struct BenchRoutingTests {
    @Test func theYabMenuIsTheBenchsOwn() {
        #expect(!Bench.forAgents("app-menu"))
    }

    @Test(arguments: ["app-status", "app-quit", "app-serve", "app-import", "agent-run", "agent-native-apply",
                      "hints-copy", "snapshot", "press", "handoff-wait"])
    func agentVerbsGoToAgents(verb: String) {
        #expect(Bench.forAgents(verb))
        #expect(verb.hasPrefix("agent-native-") || Bench.agentHandlers[verb] != nil)
    }

    @Test(arguments: ["tabs", "open", "winshot", "ui", "page-menu", "bookmark-menu"])
    func benchVerbsStayInTheBench(verb: String) {
        #expect(!Bench.forAgents(verb))
    }
}
