import AppKit
import Foundation
import Testing

// A window made in code is let go by AppKit when it closes (an NSWindow's
// isReleasedWhenClosed is true), once more than Swift's hold on it gave it.
// The window is then freed while the run loop's autorelease pool still
// holds it, and Yab crashes as the pool drains: EXC_BAD_ACCESS in
// objc_release under AutoreleasePoolPage::releaseUntil, no frame of
// Yab's (crashes #41, #42, #51, #52; BrowserWindows' window, 68403a36).
// An NSPanel is not let go that way. So every NSWindow, or a class of
// ours under it, made in Sources says isReleasedWhenClosed = false.
@MainActor
struct WindowsReleasedWhenClosedTests {
    @Test func aWindowIsLetGoWhenClosedAPanelIsNot() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled, .closable],
                              backing: .buffered, defer: true)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled, .closable],
                            backing: .buffered, defer: true)
        #expect(window.isReleasedWhenClosed)
        #expect(!panel.isReleasedWhenClosed)
        window.isReleasedWhenClosed = false
    }

    @Test func everyWindowMadeInCodeIsKeptByItsOwner() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100)
        let texts = try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        // NSWindow and every class of ours beneath it, however deep.
        var windows: Set<String> = ["NSWindow"]
        let subclass = try NSRegularExpression(pattern: #"class\s+(\w+)\s*:\s*(\w+)"#)
        var grew = true
        while grew {
            grew = false
            for (_, text) in texts {
                for match in subclass.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let name = Range(match.range(at: 1), in: text), let base = Range(match.range(at: 2), in: text),
                          windows.contains(String(text[base])), windows.insert(String(text[name])).inserted else { continue }
                    grew = true
                }
            }
        }
        try #require(windows.contains("BrowserWindow"))
        let made = try NSRegularExpression(pattern: #"(?<![\w.])(?:"# + windows.sorted().joined(separator: "|") + #")\(\s*contentRect:"#)
        var missing: [String] = []
        for (name, text) in texts {
            let lines = text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where !line.contains("super.init") {
                guard made.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                let after = lines[index..<min(lines.count, index + 30)].joined(separator: "\n")
                if !after.contains("isReleasedWhenClosed = false") { missing.append("\(name):\(index + 1)") }
            }
        }
        #expect(missing.isEmpty, "made without isReleasedWhenClosed = false: \(missing.joined(separator: ", "))")
    }
}
