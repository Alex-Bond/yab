import XCTest
@testable import Fast

// Codex with only the browser: none of the person's config, no shell, and a
// sandbox that reads Codex's own folder and what macOS needs, never home.

@MainActor
final class CodexBrowserOnlyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    func testTheArgumentsShutOutFilesAndConfig() {
        let args = Agents.codexBrowserOnly("/nowhere/codex", ignoresConfig: true, config: "")
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("default_permissions=\"yab\""))
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertTrue(args.contains("features.browser_use=false"))
        XCTAssertTrue(args.contains("features.in_app_browser=false"))
        XCTAssertTrue(args.contains("features.standalone_web_search=false"))
        XCTAssertTrue(args.contains("web_search=\"disabled\""))
        XCTAssertTrue(args.contains("features.unified_exec=false"))
        XCTAssertTrue(args.contains("project_root_markers=[]"))
        let table = args.first { $0.hasPrefix("permissions.yab.filesystem=") } ?? ""
        XCTAssertTrue(table.contains("\":minimal\"=\"read\""))
        XCTAssertTrue(table.contains("\"/private/tmp\"=\"none\""))
        XCTAssertFalse(table.contains(NSHomeDirectory() + "\""), table)
    }

    private let config = """
    model = "gpt-5.1" # the one I like
    model_provider = "azure"
    sandbox_mode = "danger-full-access"
    approval_policy = "never"

    [model_providers.azure]
    name = "Azure"
    base_url = "https://example.openai.azure.com/openai" # mine
    env_key = "AZURE_OPENAI_API_KEY"
    query_params = { api-version = "2025-04-01-preview" }
    wire_api = "responses"
    note = \"\"\"
    two lines
    \"\"\"

    [model_providers.azure.http_headers]
    X-Team = "browser"

    [mcp_servers.node_repl]
    command = "/usr/local/bin/node_repl"

    [mcp_servers."yab-browser"]
    command = "/Applications/yab.app/Contents/MacOS/yab"

    [mcp_servers.notion]
    url = "https://mcp.notion.com/mcp"

    [[profiles]]
    model = "o3"
    """

    func testTheModelAndItsProviderComeAlongAndNothingElse() {
        let carried = Agents.codexCarried(config)
        XCTAssertEqual(carried, [
            "model=\"gpt-5.1\"",
            "model_provider=\"azure\"",
            "model_providers.azure.name=\"Azure\"",
            "model_providers.azure.base_url=\"https://example.openai.azure.com/openai\"",
            "model_providers.azure.env_key=\"AZURE_OPENAI_API_KEY\"",
            "model_providers.azure.query_params={ api-version = \"2025-04-01-preview\" }",
            "model_providers.azure.wire_api=\"responses\"",
            "model_providers.azure.http_headers.X-Team=\"browser\"",
        ])
        let args = Agents.codexBrowserOnly("/nowhere/codex", ignoresConfig: true, config: config)
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("model_provider=\"azure\""))
        XCTAssertFalse(args.contains { $0.contains("danger-full-access") || $0.contains("mcp_servers") })
    }

    func testAnOldCodexHasEveryServerOfTheConfigTurnedOff() {
        let args = Agents.codexBrowserOnly("/nowhere/codex", ignoresConfig: false, config: config)
        XCTAssertFalse(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("mcp_servers.node_repl.enabled=false"))
        XCTAssertTrue(args.contains("mcp_servers.notion.enabled=false"))
        XCTAssertFalse(args.contains("mcp_servers.yab-browser.enabled=false"))
        XCTAssertTrue(args.contains("features.plugins=false"))
        XCTAssertFalse(args.contains { $0.hasPrefix("model_provider") })
    }

    func testTheFixtureCodexSaysWhetherItIgnoresConfig() async throws {
        let domain = "codex-help-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        let consent = ProviderConsent(settings: settings, history: [])
        consent.grant("codex")
        let permit = try XCTUnwrap(consent.permit("codex"))
        let modern = try file("modern/codex")
        try "#!/bin/sh\necho 'Usage: codex exec --ignore-user-config'\n".write(to: modern, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: modern.path)
        await Agents.learn(codex: modern.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"], permit: permit)
        XCTAssertEqual(Agents.codexIgnoresConfig[modern.path], true)
        let stub = try file("old/codex")
        try "#!/bin/sh\necho 'Usage: codex exec [OPTIONS]'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        await Agents.learn(codex: stub.path, env: ["HOME": root.path, "PATH": "/usr/bin:/bin"], permit: permit)
        XCTAssertEqual(Agents.codexIgnoresConfig[stub.path], false)
    }

    func testALinkedBinaryReadsItsReleaseFolder() throws {
        let binary = try file("releases/1.0/bin/codex")
        let link = root.appendingPathComponent("home/.local/bin/codex")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        XCTAssertEqual(Agents.real(link.path), binary.path)
        XCTAssertEqual(Agents.codexFolder(link.path, home: root.appendingPathComponent("home").path), root.appendingPathComponent("releases/1.0").path)
    }

    func testABinaryInHomesOwnBinFolderReadsOnlyThatFolder() throws {
        let binary = try file("home/.local/bin/codex")
        XCTAssertEqual(Agents.codexFolder(binary.path, home: root.appendingPathComponent("home").path), root.appendingPathComponent("home/.local/bin").path)
    }

    func testHomeItselfIsNeverRead() throws {
        let binary = try file("home/codex")
        XCTAssertNil(Agents.codexFolder(binary.path, home: root.appendingPathComponent("home").path))
        let bin = try file("home/bin/codex")
        XCTAssertEqual(Agents.codexFolder(bin.path, home: root.appendingPathComponent("home").path), root.appendingPathComponent("home/bin").path)
    }
}
