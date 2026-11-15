import AppKit
import Darwin
import Foundation
import Translation
import WebKit

@main struct PageCompare {
    @MainActor static func main() async throws {
        guard #available(macOS 26.4, *) else { fatalError("Requires macOS 26.4") }
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let source = Locale.Language(identifier: "en"), target = Locale.Language(identifier: "ru")
        let status = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
        print("PAIR en→ru: \(status)")
        let session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 750))
        var window: NSWindow?
        if ProcessInfo.processInfo.environment["YAB_TRANSLATION_SHOTS"] == "1" {
            window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window!.contentView = web
            window!.setFrameOrigin(NSPoint(x: -1200, y: -1200))
            window!.orderFront(nil)
        }
        defer { window?.orderOut(nil) }
        let article = """
        <html lang=en><meta charset=utf-8><style>body{font:22px/1.6 -apple-system;margin:30px}p{margin:18px 0}</style>
        <h1>Translation context comparison</h1>
        <p>The bank of the <strong>river</strong> was covered with reeds.</p>
        <p>Please <a href="/booking">book</a> a table for two at the restaurant.</p>
        <p>The browser <strong>tab</strong> is using too much memory.</p>
        <p>She <strong>gave up</strong> smoking last year.</p>
        <p>Read <strong>every</strong> page carefully before signing the contract.</p>
        <p>The <strong>charge</strong> against the defendant was dismissed by the court.</p>
        <p>The computer <strong>mouse</strong> stopped working after the update.</p>
        <p>The discussion <a href="/thread">thread</a> has been closed by the moderator.</p>
        </html>
        """
        web.loadHTMLString(article, baseURL: URL(string: "https://example.test/article"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && document.querySelectorAll('p').length === 8")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let code = try String(contentsOfFile: "Sources/Fast/PageTranslation.swift", encoding: .utf8)
        let collector = code.components(separatedBy: "static let collectScript = #\"\"\"")[1].components(separatedBy: "\"\"\"#")[0]
        let world = WKContentWorld.world(name: "translation-context-check")
        func isolated(_ js: String) async throws -> Any? {
            try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(js, in: nil, in: world) { result in
                    continuation.resume(with: result)
                }
            }
        }
        func apply(_ values: [[String: String]]) async throws {
            let json = String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
            _ = try await isolated("window.__yabPageTranslation.apply(\(json))")
        }
        func paragraphs() async throws -> [String] {
            try await web.evaluateJavaScript("[...document.querySelectorAll('p')].map(p=>p.textContent)") as! [String]
        }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["APP"]!).deletingLastPathComponent().appendingPathComponent("translation-context")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func picture(_ name: String) async throws {
            guard window != nil else { return }
            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
        }
        let original = try await web.evaluateJavaScript("document.body.innerHTML") as! String
        let originals = try await paragraphs()
        _ = try await web.evaluateJavaScript("window.link = document.querySelector('a'); link.addEventListener('click', e=>{e.preventDefault();window.clicked=true})")
        let data = try await isolated(collector) as! [String: Any]
        let items = data["items"] as! [[String: String]]
        let oldStart = Date()
        var oldValues: [[String: String]] = []
        for try await answer in session.translate(batch: items.map { .init(sourceText: $0["text"]!, clientIdentifier: $0["id"]!) }) {
            oldValues.append(["id": answer.clientIdentifier!, "text": answer.targetText])
        }
        try await apply(oldValues)
        let old = try await paragraphs(), oldSeconds = Date().timeIntervalSince(oldStart)
        try await picture("before")
        _ = try await isolated("window.__yabPageTranslation.restore()")
        let oldRestored = try await web.evaluateJavaScript("document.body.innerHTML") as! String == original
        precondition(oldRestored)
        let fresh = try await isolated(collector) as! [String: Any]
        let contexts = (fresh["groups"] as! [[String: Any]]).map { group in
            PageTranslationContext(id: group["id"] as! String, parts: (group["parts"] as! [[String: String]]).map { .init(id: $0["id"]!, text: $0["text"]!, anchored: $0["anchor"] != "false") })
        }
        let newStart = Date()
        var newValues: [[String: String]] = [], accepted: [String] = [], fallback: [String] = []
        var covered = Set<String>()
        if ProcessInfo.processInfo.environment["YAB_TRANSLATION_BATCH_DEBUG"] == "1" {
            for try await answer in session.translate(batch: contexts.map { $0.request }) {
                print("BATCH", answer.clientIdentifier!, answer.targetText, "ATTR", answer.attributedTargetText.map { String(describing: $0) } ?? "nil")
            }
        }
        for context in contexts {
            let answer = try await session.translate(context.source)
            if let values = context.aligned(answer) {
                newValues += values
                accepted.append(context.id)
                covered.formUnion(context.parts.map(\.id))
            } else { fallback.append(context.id) }
        }
        let remaining = (fresh["items"] as! [[String: String]]).filter { !covered.contains($0["id"]!) }
        for try await answer in session.translate(batch: remaining.map { .init(sourceText: $0["text"]!, clientIdentifier: $0["id"]!) }) {
            newValues.append(["id": answer.clientIdentifier!, "text": answer.targetText])
        }
        try await apply(newValues)
        let new = try await paragraphs(), newSeconds = Date().timeIntervalSince(newStart)
        try await picture("after")
        let preserved = try await web.evaluateJavaScript("document.querySelector('a') === window.link && link.getAttribute('href') === '/booking' && document.querySelectorAll('strong').length === 6") as! Bool
        _ = try await web.evaluateJavaScript("link.click()")
        let clickable = try await web.evaluateJavaScript("window.clicked === true") as! Bool
        _ = try await isolated("window.__yabPageTranslation.restore()")
        let restored = try await web.evaluateJavaScript("document.body.innerHTML") as! String == original
        precondition(preserved && clickable && restored)
        let rows = originals.indices.map { ["source": originals[$0], "old": old[$0], "new": new[$0]] }
        let result: [String: Any] = ["rows": rows, "accepted": accepted, "fallback": fallback, "oldSeconds": oldSeconds, "newSeconds": newSeconds, "linksPreserved": preserved, "clickHandlerPreserved": clickable, "restored": restored]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: out.appendingPathComponent("results.json"))
        print(String(data: json, encoding: .utf8)!)
        print("EVIDENCE \(out.path)")
    }
}
