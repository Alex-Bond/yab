import Foundation
import Testing
@testable import Fast

@MainActor
struct AgentCatalogTests {
    /// `codex debug models` from 0.157, which predates gpt-6.1-sol.
    static let old = """
    {"models":[
      {"slug":"gpt-6-sol","display_name":"gpt-6-sol","visibility":"list","priority":2,"default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
      {"slug":"gpt-6-astra","display_name":"gpt-6-astra","visibility":"list","priority":1,"default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"},{"effort":"ultra"}]},
      {"slug":"gpt-6-luna","display_name":"gpt-6-luna","visibility":"list","priority":3,"default_reasoning_level":"medium",
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"},{"effort":"xhigh"},{"effort":"max"}]},
      {"slug":"codex-auto-review","visibility":"hide","priority":0,"supported_reasoning_levels":[{"effort":"low"}]}
    ]}
    """

    var catalog: CodexCatalog.Catalog { CodexCatalog.parse("WARN something first\n" + Self.old)! }

    @Test func catalogKeepsCodexOrderListedFirst() {
        #expect(catalog.models.map(\.slug) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "codex-auto-review"])
        #expect(catalog.shown.map(\.model) == ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"])
        #expect(catalog.first?.slug == "gpt-6-astra")
        #expect(CodexCatalog.parse("not json") == nil)
        #expect(CodexCatalog.parse(#"{"models":[]}"#) == nil)
    }

    @Test func modelFromANewerCodexIsSwapped() {
        // The ChatGPT app's config, read by an older Homebrew Codex.
        let fit = ModelFit.codex(model: "gpt-6.1-sol", effort: "ultra", in: catalog)
        #expect(fit.model == "gpt-6-astra")
        #expect(fit.effort == "ultra")
    }

    @Test func knownModelAndEffortStay() {
        #expect(ModelFit.codex(model: "gpt-6-sol", effort: "high", in: catalog) == ("gpt-6-sol", "high"))
        // A hidden one asked for by name is still one it has.
        #expect(ModelFit.codex(model: "codex-auto-review", effort: nil, in: catalog).model == "codex-auto-review")
        #expect(ModelFit.codex(model: nil, effort: nil, in: catalog) == (nil, nil))
    }

    @Test func effortItCannotTakeComesDownToTheClosest() {
        #expect(ModelFit.codex(model: "gpt-6-luna", effort: "ultra", in: catalog) == ("gpt-6-luna", "max"))
        // Below everything it takes: its own default.
        #expect(ModelFit.codex(model: "gpt-6-luna", effort: "minimal", in: catalog) == ("gpt-6-luna", "medium"))
        // No model named: Codex's first decides.
        #expect(ModelFit.codex(model: nil, effort: "ultra", in: catalog) == (nil, "ultra"))
    }

    @Test func refusedModelsAreSkipped() {
        let fit = ModelFit.codex(model: "gpt-6-astra", effort: "ultra", in: catalog, avoiding: ["gpt-6-astra"])
        #expect(fit.model == "gpt-6-sol")
        let next = ModelFit.codex(model: "gpt-6-sol", effort: "ultra", in: catalog, avoiding: ["gpt-6-astra", "gpt-6-sol"])
        #expect(next == ("gpt-6-luna", "max"))
    }

    @Test func customProviderModelAndEffortAreNotReplacedByTheCachedCatalog() {
        let config = Agents.codexTop("model_provider = \"example-direct\"\n")
        let fit = ModelFit.codex(model: "account/custom-model", effort: "ultra", in: catalog,
                                 avoiding: ["account/custom-model"], provider: config["model_provider"])
        #expect(fit == ("account/custom-model", "ultra"))
        // A known slug on another provider is still that provider's choice.
        let known = ModelFit.codex(model: "gpt-6-luna", effort: "ultra", in: catalog,
                                   avoiding: ["gpt-6-luna"], provider: config["model_provider"])
        #expect(known == ("gpt-6-luna", "ultra"))
    }

    @Test func ordinaryOpenAICatalogFallbackStillApplies() {
        for provider in [nil, "openai"] as [String?] {
            let fit = ModelFit.codex(model: "gpt-6-astra", effort: "ultra", in: catalog,
                                     avoiding: ["gpt-6-astra"], provider: provider)
            #expect(fit == ("gpt-6-sol", "ultra"))
        }
    }

    @Test func versionsAreReadAndCompared() {
        #expect(AgentCopies.version("codex-cli 0.160.0") == [0, 160, 0])
        #expect(AgentCopies.version("2.1.287 (Claude Code)") == [2, 1, 287])
        #expect(AgentCopies.version("no version here") == nil)
        #expect(AgentCopies.newer([0, 160, 0], than: [0, 157, 0]))
        #expect(!AgentCopies.newer([0, 157, 0], than: [0, 160, 0]))
        #expect(AgentCopies.newer([2, 1, 287], than: [2, 1]))
        #expect(!AgentCopies.newer([1, 0], than: [1, 0]))
    }

    /// A copy that leaves a mark when anything runs it.
    static func tripwire(_ path: URL, marker: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\necho run >> '\(marker.path)'\necho 'codex-cli 9.9.9'\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    static func json(_ object: [String: Any], at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func newestCopyIsToldFromItsFilesWithoutRunningIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("copies-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("ran")
        // npm's, linked from a bin folder as npm does.
        let npm = root.appendingPathComponent("lib/node_modules/@openai/codex")
        try Self.json(["name": "@openai/codex", "version": "0.157.0"], at: npm.appendingPathComponent("package.json"))
        try Self.tripwire(npm.appendingPathComponent("bin/codex.js"), marker: marker)
        let link = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: npm.appendingPathComponent("bin/codex.js"))
        // The ChatGPT app's, beside its codex-package.json.
        let app = root.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli")
        try Self.json(["layoutVersion": 1, "version": "0.160.0"], at: app.appendingPathComponent("codex-package.json"))
        try Self.tripwire(app.appendingPathComponent("bin/codex"), marker: marker)
        // Codex's own releases, and Homebrew's Cellar: the folder's name.
        let release = root.appendingPathComponent(".codex/packages/standalone/releases/0.149.1-aarch64-apple-darwin/bin/codex")
        try Self.tripwire(release, marker: marker)
        let cellar = root.appendingPathComponent("Cellar/codex/0.158.0/bin/codex")
        try Self.tripwire(cellar, marker: marker)
        // Claude Code's native installer names each version's file.
        let claude = root.appendingPathComponent(".local/share/claude/versions/2.1.287")
        try Self.tripwire(claude, marker: marker)
        // Under nvm, a folder named for node's version says nothing of its own.
        let plain = root.appendingPathComponent(".nvm/versions/node/v22.15.0/bin/codex")
        try Self.tripwire(plain, marker: marker)

        #expect(AgentCopies.installed(link.path) == [0, 157, 0])
        #expect(AgentCopies.installed(app.appendingPathComponent("bin/codex").path) == [0, 160, 0])
        #expect(AgentCopies.installed(release.path) == [0, 149, 1])
        #expect(AgentCopies.installed(cellar.path) == [0, 158, 0])
        #expect(AgentCopies.installed(claude.path) == [2, 1, 287])
        #expect(AgentCopies.installed(plain.path) == nil)

        let newest = AgentCopies.newest([cellar.path, "/nowhere/codex", link.path, app.appendingPathComponent("bin/codex").path, release.path])
        #expect(newest?.path == app.appendingPathComponent("bin/codex").path)
        #expect(newest?.version == [0, 160, 0])
        // A copy that says nothing loses to one that does, wherever it is.
        #expect(AgentCopies.newest([plain.path, release.path])?.path == release.path)
        // None says: the first that is there, as before.
        #expect(AgentCopies.newest(["/nowhere/codex", plain.path])?.path == plain.path)
        #expect(AgentCopies.newest(["/nowhere/codex"]) == nil)
        // The same file twice, or a tie: the first.
        let same = root.appendingPathComponent("again/codex")
        try FileManager.default.createDirectory(at: same.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: same, withDestinationURL: cellar)
        #expect(AgentCopies.newest([cellar.path, same.path])?.path == cellar.path)
        #expect(AgentCopies.newest([same.path, cellar.path])?.path == same.path)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func modelCacheCountsOnlyForTheVersionThatFetchedIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let cached = Self.old.replacingOccurrences(of: #"{"models":["#, with: #"{"client_version":"0.160.0","models":["#)
        try cached.write(to: home.appendingPathComponent("models_cache.json"), atomically: true, encoding: .utf8)
        #expect(CodexCatalog.cache(home: home.path, version: [0, 160, 0])?.first?.slug == "gpt-6-astra")
        #expect(CodexCatalog.cache(home: home.path, version: [0, 157, 0]) == nil)
        #expect(CodexCatalog.cache(home: home.path, version: nil) == nil)
    }

    @Test func configTopKeys() {
        let config = """
        model = "gpt-6.1-sol"
        model_reasoning_effort = 'ultra' # comment
        approval_policy = "never"

        [model_providers.azure]
        model = "inside a table"
        """
        let top = Agents.codexTop(config)
        #expect(top["model"] == "gpt-6.1-sol")
        #expect(top["model_reasoning_effort"] == "ultra")
        #expect(top["model_provider"] == nil)
    }

    @Test func modelNamesWithoutACatalog() {
        #expect(AgentModels.name("claude", "opus") == "Claude Opus")
        #expect(AgentModels.name("claude", "claude-made-up") == "claude-made-up")
    }

    @Test func claudeCodeModelErrorIsModelUnavailable() {
        let raw = "There's an issue with the selected model (fable). It may not exist or you may not have access to it. Run /model to pick a different model."
        #expect(ChatProblem(raw, agent: "Claude").kind == .modelUnavailable)
        #expect(ChatProblem(ChatProblemTests.unsupported + "\nERROR: stderr", agent: "ChatGPT").kind == .modelUnavailable)
    }
}
