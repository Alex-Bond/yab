import Foundation
import Testing
@testable import Fast

// What `yab mcp` says on the wire, held still: tools/list for every kind of
// server the browser starts (a client's own, a task's, a subagent's, a
// context_explorer's, an iPhone task's), with the user's caps off, all on,
// and mail alone, and the refusal each of them gives for every tool. Kept in
// Tests/Snapshots/mcp-tools.json; a change to a tool's words or to who gets
// it shows up as a change there. YAB_RECORD_MCP=1 prints the new one.
@Suite struct McpSnapshotTests {
    static let modes: [(String, Mcp.Audience)] = [
        ("main", Mcp.Audience()),
        ("inner", Mcp.Audience(inner: true)),
        ("sub", Mcp.Audience(inner: true, sub: true)),
        ("context_explorer", Mcp.Audience(inner: true, sub: true, profile: "context_explorer")),
        ("phone", Mcp.Audience(inner: true, phoneReadOnly: true)),
        ("phone_sub", Mcp.Audience(inner: true, phoneReadOnly: true, sub: true)),
    ]

    static let caps: [(String, (inout Mcp.Audience) -> Void)] = [
        ("none", { _ in }),
        ("all", { a in
            a.knowing = true; a.keepsFolder = true; a.mailbox = true; a.mailAgents = true; a.recall = true
            a.mailCodes = true; a.messages = true; a.boost = true
        }),
        ("mailbox", { a in a.mailbox = true; a.mailAgents = true }),
    ]

    static func json(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The whole snapshot: each tool's definitions (one per wording it has
    /// in some mode), each mode's list as names with that wording's number,
    /// and each mode's refusals.
    static func snapshot() -> String {
        var definitions: [String: [String]] = [:]
        var lists: [String: [String]] = [:]
        for (mode, base) in modes {
            for (capsName, set) in caps {
                var a = base
                set(&a)
                lists["\(mode)/\(capsName)"] = Mcp.list(for: a).map { tool in
                    let name = tool["name"] as? String ?? "?"
                    let said = json(tool)
                    var known = definitions[name] ?? []
                    if !known.contains(said) { known.append(said) }
                    definitions[name] = known
                    return "\(name)#\(known.firstIndex(of: said) ?? 0)"
                }
            }
        }
        var refusals: [String: [String: String]] = [:]
        let names = definitions.keys.sorted() + ["made_up", "plugin.tool"]
        for (mode, a) in modes {
            var said: [String: String] = [:]
            for name in names {
                if let no = Mcp.phoneRefusal(name, a) ?? Mcp.refusal(name, [:], a) { said[name] = no }
            }
            if let no = Mcp.phoneRefusal("native_operation", a) ?? Mcp.refusal("native_operation", ["cancel": true], a) {
                said["native_operation+cancel"] = no
            }
            refusals[mode] = said
        }
        let parsed = definitions.mapValues { $0.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) } }
        return json(["definitions": parsed, "lists": lists, "refusals": refusals]) + "\n"
    }

    static var file: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Snapshots/mcp-tools.json")
    }

    /// An argument a tool doesn't take is refused with the ones it does,
    /// for every tool: mail_file's `file` for its `name`.
    @Test func anUnknownArgumentSaysWhatTheToolTakes() throws {
        let file = try #require(Mcp.byName["mail_file"])
        #expect(file.strangers(["thread": "t1", "file": "a.pdf"]) == "mail_file has no argument `file`; it takes thread (required), index, name.")
        #expect(file.strangers(["thread": "t1", "name": "a.pdf", "index": 2]) == nil)
        // `tab` goes to any tool; a client's own underscored keys are let be.
        #expect(file.strangers(["thread": "t1", "tab": "x", "_meta": [:] as [String: Any]]) == nil)
        let read = try #require(Mcp.byName["files_read"])
        #expect(read.strangers(["path": "/tmp/a", "words": true]) == "files_read has no arguments `path`, `words`; it takes id (required).")
        if let none = Mcp.registry.first(where: { $0.properties.isEmpty }) {
            #expect(none.strangers(["x": 1])?.hasSuffix("it takes none.") == true)
        }
        // Every tool says its own: no tool takes what its schema doesn't list.
        for tool in Mcp.registry {
            #expect(tool.strangers(tool.properties.mapValues { _ in "" as Any }) == nil, "\(tool.name)")
            #expect(tool.strangers(["made_up_argument": 1])?.contains(tool.name) == true, "\(tool.name)")
        }
    }

    /// `yab mail file` and `yab files read` are those tools' calls, and a
    /// task is still a task.
    @Test func theTerminalVerbsAreTheToolsCalls() throws {
        #expect(CliFiles.mailWords(["file", "me@example.com|19a2f0c4e1b2d3a4", "2"]))
        #expect(CliFiles.mailWords(["read", "19a2f0c4e1b2d3a4"]))
        #expect(!CliFiles.mailWords(["read", "my", "latest", "email"]))
        #expect(CliFiles.filesWords(["search", "lease"]) && CliFiles.filesWords(["read", "mail.me@x.test|m1|1"]))
        #expect(!CliFiles.filesWords(["from", "last", "week"]))
        let file = try #require(CliFiles.call("mail", ["file", "t1", "2", "--path"]))
        #expect(file.tool == "mail_file" && file.input["index"] as? Double == 2 && file.path)
        let named = try #require(CliFiles.call("mail", ["file", "t1", "Signed", "lease.pdf"]))
        #expect(named.input["name"] as? String == "Signed lease.pdf" && !named.path)
        let search = try #require(CliFiles.call("files", ["search", "signed", "lease", "--from", "mail", "--limit", "5"]))
        #expect(search.tool == "files_search" && search.input["query"] as? String == "signed lease"
                && search.input["from"] as? String == "mail" && search.input["limit"] as? Double == 5)
        let read = try #require(CliFiles.call("files", ["read", "/tmp/a.mov", "--path"]))
        #expect(read.tool == "files_read" && read.input["id"] as? String == "/tmp/a.mov" && read.path)
        for call in [file, named, search, read] {
            #expect(Mcp.byName[call.tool]?.strangers(call.input) == nil, "\(call.tool)")
        }
        #expect(CliFiles.path(in: "File a.mov.\npath: /x/a.mov\n(No words)") == "/x/a.mov")
    }

    @Test func theWireStaysAsItWas() throws {
        let now = Self.snapshot()
        let kept = try? String(contentsOf: Self.file, encoding: .utf8)
        if kept == nil || ProcessInfo.processInfo.environment["YAB_RECORD_MCP"] == "1" {
            print("MCP-SNAPSHOT-BEGIN\n" + now + "MCP-SNAPSHOT-END")
        }
        // A farm job keeps the new one beside its evidence: ./farm fetch
        // brings it home to be looked over and put in place.
        if kept != now, let out = ProcessInfo.processInfo.environment["YAB_FARM_OUT"] {
            try? now.write(to: URL(fileURLWithPath: out).appendingPathComponent("mcp-tools.json"), atomically: true, encoding: .utf8)
        }
        let had = try #require(kept, "no snapshot at \(Self.file.path); printed between MCP-SNAPSHOT-BEGIN and -END")
        if had != now {
            let a = had.components(separatedBy: "\n"), b = now.components(separatedBy: "\n")
            let first = zip(a, b).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(a.count, b.count)
            let from = max(0, first - 3)
            Issue.record("""
            The MCP wire changed at line \(first + 1) of mcp-tools.json.
            was:
            \(a[from..<min(a.count, first + 4)].joined(separator: "\n"))
            now:
            \(b[from..<min(b.count, first + 4)].joined(separator: "\n"))
            """)
        }
    }

    /// The modes are the ones the browser starts `yab mcp` in (Agents).
    @Test func everyModeListsSomething() {
        for (mode, a) in Self.modes { #expect(!Mcp.list(for: a).isEmpty, "\(mode)") }
    }
}

/// Whatever a mode is offered it may call: no tool in tools/list is one its
/// own call would refuse.
@Suite struct McpListedIsCallableTests {
    @Test func everyListedToolIsOneTheModeMayCall() {
        for (mode, base) in McpSnapshotTests.modes {
            for (cap, set) in McpSnapshotTests.caps {
                var a = base
                set(&a)
                for tool in Mcp.list(for: a) {
                    let name = tool["name"] as? String ?? ""
                    #expect(Mcp.phoneRefusal(name, a) == nil, "\(mode)/\(cap) lists \(name), refused on the phone")
                    #expect(Mcp.refusal(name, [:], a) == nil, "\(mode)/\(cap) lists \(name), refused when called")
                }
            }
        }
    }
}
