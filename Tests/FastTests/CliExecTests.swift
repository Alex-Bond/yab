import Foundation
import Testing
@testable import Fast

struct CliExecTests {
    @Test func readsInlineFileAndStdin() throws {
        let inline = try CliExec.parse(["--json", "return 42", "--timeout", "2.5", "--output-limit", "512", "--socket", "/tmp/test.sock"])
        #expect(inline.json && inline.timeout == 2.5 && inline.outputLimit == 512)
        #expect(inline.socket == "/tmp/test.sock")
        #expect(try CliExec.source(inline) { Issue.record("unexpected stdin"); return Data() } == "return 42")
        #expect(try CliExec.source(CliExec.parse(["-"])) { Data("return 1".utf8) } == "return 1")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".js")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("return 2".utf8).write(to: file)
        #expect(try CliExec.source(CliExec.parse(["-f", file.path])) { Data() } == "return 2")
    }

    @Test func refusesAmbiguousInvalidAndOversizedInputs() {
        for args in [["-f"], ["-f", "a", "return 2"], ["--unknown"], ["a", "b"], ["--timeout", "nan"], ["--timeout", "0"], ["--output-limit", "255"]] {
            #expect(throws: (any Error).self) { try CliExec.parse(args) }
        }
        for data in [Data(), Data([0xff]), Data(repeating: 65, count: 1_048_577)] {
            #expect(throws: (any Error).self) { try CliExec.source(CliExec.parse(["-"])) { data } }
        }
    }

    @Test func reportsNeedsUserSeparatelyFromFailure() {
        #expect(CliExec.status(["isError": false]) == 0)
        #expect(CliExec.status(["isError": true, "content": [["text": "bad step"]]]) == 1)
        #expect(CliExec.status(["isError": true, "content": [["text": "Error: status: needs_user"]]]) == 3)
    }
}
