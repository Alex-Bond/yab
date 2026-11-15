import Foundation
import Testing
@testable import Fast

/// Conservative module-page normalization. The native Vimium C eval covers
/// its integration with installation and the complete extension module graph.
@Suite struct ExtensionPageModuleTests {
    private func prepare(_ tags: String, extra: String = "") throws -> (String, [String: String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-modules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = folder.appendingPathComponent("pages/options.html")
        try FileManager.default.createDirectory(at: page.deletingLastPathComponent(), withIntermediateDirectories: true)
        for name in ["a.js", "b.js", "c.js"] {
            try "export const ready = true;".write(to: page.deletingLastPathComponent().appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let html = "<!doctype html><html><head>\(extra)\(tags)</head><body>Options</body></html>"
        try html.write(to: page, atomically: true, encoding: .utf8)
        let first = try ExtensionPageModules.join(html, page: page, folder: folder)
        try first.write(to: page, atomically: true, encoding: .utf8)
        #expect(try ExtensionPageModules.join(first, page: page, folder: folder) == first)
        let entries = try FileManager.default.contentsOfDirectory(at: page.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.contains("yab-modules") }
        return (first, try Dictionary(uniqueKeysWithValues: entries.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }))
    }

    @Test func adjacentModulesShareOneGraph() throws {
        let (html, files) = try prepare(#"<script defer="defer" src="a.js" type="module" blocking="render"></script><script type="module" src="b.js" blocking="render" defer="defer"></script>"#)
        #expect(files.count == 1)
        #expect(files.values.first == "import \"./a.js\";\nimport \"./b.js\";\n")
        #expect(html.contains("blocking=\"render\""))
        #expect(!html.contains("src=\"b.js\""))
    }

    @Test(arguments: [
        #"<script type="module" async="async" src="a.js"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="a.js"></script><script src="c.js"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="a.js"></script><!-- keep order --><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="a.js" integrity="sha256-x"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="a.js" onload="loaded()"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="https://example.com/a.js"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="../../outside.js"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module" src="missing.js"></script><script type="module" src="b.js"></script>"#,
        #"<script type="module">import './a.js';</script><script type="module" src="b.js"></script>"#,
    ])
    func independentScriptsStayUnchanged(tags: String) throws {
        let (html, files) = try prepare(tags)
        #expect(files.isEmpty)
        #expect(html.contains(tags))
    }

    @Test func baseElementKeepsHTMLResolution() throws {
        let (_, files) = try prepare(#"<script type="module" src="a.js"></script><script type="module" src="b.js"></script>"#, extra: #"<base href="/pages/">"#)
        #expect(files.isEmpty)
    }
}
