import AppKit
import SwiftUI
import Testing
import Translation
import WebKit
@testable import Fast

/// Opt-in captures of the real Site Controls view, driven by the real page translator.
struct PageTranslationVisualTests {
    @Test @MainActor func captureStates() async throws {
        guard ProcessInfo.processInfo.environment["YAB_TRANSLATION_SHOTS"] == "1" else { return }
        let source = Locale.Language(identifier: "es")
        let target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en-US")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/evidence/site-translation-qa-2026-09-26")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        defer { tab.close() }
        let page = URL(string: "https://example.test/article")!
        tab.restore(url: page, title: "Artículo en español")
        let web = tab.page
        web.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let pageWindow = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        pageWindow.contentView = web
        pageWindow.setFrameOrigin(NSPoint(x: -1200, y: -1200))
        pageWindow.orderFront(nil)
        defer { pageWindow.orderOut(nil) }
        let paragraphs = (0..<120).map { "<p>Este es el párrafo número \($0). El navegador traduce el texto de la página al idioma del sistema.</p>" }.joined()
        web.navigate(html:"<html lang=es><body><h1>Un artículo largo en español</h1>\(paragraphs)</body></html>", base: page)
        for _ in 0..<100 {
            if (try? await web.run("document.querySelector('h1')?.textContent")) as? String == "Un artículo largo en español" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(web.url == page)
        try await savePage(web, to: folder.appendingPathComponent("page-original.png"))

        let translation = browser.pageTranslation
        let taskHost = NSHostingView(rootView: PageTranslationHost(translation: translation).frame(width: 1, height: 1))
        let taskWindow = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 20, height: 20),
                                  styleMask: .borderless, backing: .buffered, defer: false)
        taskWindow.contentView = taskHost
        taskWindow.orderFront(nil)
        defer { taskWindow.orderOut(nil) }

        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("01-original-light.png"), scheme: .light)
        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("02-original-dark.png"), scheme: .dark)
        translation.toggle(tab)
        for _ in 0..<100 {
            if translation.phase(for: tab) == .translating { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("03-translating-light.png"), scheme: .light)
        for _ in 0..<600 {
            if translation.phase(for: tab) == .translated { break }
            if case .failed = translation.phase(for: tab) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(translation.phase(for: tab) == .translated)
        try await savePage(web, to: folder.appendingPathComponent("page-translated.png"))
        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("04-translated-light.png"), scheme: .light)
        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("05-translated-dark.png"), scheme: .dark)
        translation.toggle(tab)
        try save(browser: browser, tab: tab, to: folder.appendingPathComponent("06-restored-light.png"), scheme: .light)
        #expect((try await web.run("document.querySelector('h1').textContent")) as? String == "Un artículo largo en español")
        try await savePage(web, to: folder.appendingPathComponent("page-restored.png"))

        web.navigate(html:"<html lang=en><body><h1>This page is already in English.</h1></body></html>", base: page)
        for _ in 0..<100 {
            if (try? await web.run("document.querySelector('h1')?.textContent")) as? String == "This page is already in English." { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        translation.navigationCommitted(tab)
        translation.toggle(tab)
        for _ in 0..<100 {
            if case .failed = translation.phase(for: tab) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        if case .failed = translation.phase(for: tab) {
            try save(browser: browser, tab: tab, to: folder.appendingPathComponent("07-same-language.png"), scheme: .light)
        } else { Issue.record("Same-language state did not fail") }
    }

    @MainActor
    private func save(browser: Browser, tab: Fast.Tab, to url: URL, scheme: ColorScheme) throws {
        let view = SiteControlsView(browser: browser, tab: tab, prefs: browser.prefs, translation: browser.pageTranslation, extensions: .shared)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(nsColor: NSColor(white: 0.18, alpha: 1)) : Color.white)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }

    @MainActor
    private func savePage(_ web: any PageHandle, to url: URL) async throws {
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
            web.snapshot(PageShot()) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url, options: .atomic)
    }
}
