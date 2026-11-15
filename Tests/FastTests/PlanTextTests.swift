import Testing
@testable import Fast

/// Codex's run of words for Yab's own helpers has no tools: what a mail or
/// a page says can't make it run, read or fetch anything (PlanText).
struct PlanTextTests {
    @Test func codexRunsWithEveryToolFeatureOff() {
        let args = PlanText.codexArgs("Write it.", out: "/tmp/out.txt", model: nil, effort: "low")
        #expect(args.first == "exec")
        #expect(args.last == "Write it.")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"] { #expect(args.contains(flag)) }
        #expect(args.contains(#"web_search="disabled""#))
        let sandbox = args.firstIndex(of: "-s").map { args[$0 + 1] }
        #expect(sandbox == "read-only")
        let off = Set(args.indices.filter { args[$0] == "--disable" }.map { args[$0 + 1] })
        for feature in ["shell_tool", "unified_exec", "code_mode_host", "browser_use", "computer_use", "apps", "plugins", "multi_agent"] {
            #expect(off.contains(feature))
        }
        #expect(!args.contains("-m"))
    }

    @Test func codexTakesTheModelAndEffortGiven() {
        let args = PlanText.codexArgs("x", out: "/tmp/o", model: "gpt-5.5-mini", effort: "medium")
        #expect(args.firstIndex(of: "-m").map { args[$0 + 1] } == "gpt-5.5-mini")
        #expect(args.contains("model_reasoning_effort=\"medium\""))
        #expect(args.firstIndex(of: "-o").map { args[$0 + 1] } == "/tmp/o")
    }
}
