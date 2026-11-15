import AppKit
import PDFKit
import Testing
import WebKit
@testable import Fast

@MainActor
@Suite(.serialized)
struct PageSaveRoutingTests {
    /// A selected engine with a separate native print capability. The drawn
    /// PDF primitive deliberately fails, as Chromium's currently does.
    private class Page: NSView, PageHandle {
        let engine: PageEngineKind
        weak var events: (any PageEvents)?
        weak var stateEvents: (any PageStateEvents)?
        var url: URL?
        var committedURL: URL? { url }
        var historyEntry: PageHistoryEntry? { nil }
        var title: String?
        var isLoading = false
        var estimatedProgress = 1.0
        var canGoBack = false
        var canGoForward = false
        var pageZoom: CGFloat = 1
        var magnification: CGFloat = 1
        var themeColor: NSColor?
        var lastInput: TimeInterval?
        var contentProcess: pid_t? { nil }
        var gpuProcess: pid_t? { nil }
        var captureStatus = PageCaptureStatus(camera: .none, microphone: .none, screen: .none)
        var drawnCalls = 0
        var scripts = 0
        var drawn: Result<Data, Error> = .failure(PageSave.Failure("Drawn full-document PDF unavailable"))
        init(_ engine: PageEngineKind) { self.engine = engine; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        func navigate(to request: URLRequest) { url = request.url }
        func navigate(html: String, base: URL?) { }
        func reload(fromOrigin: Bool) { }
        func stopLoading() { }
        func navigateBack() { }
        func navigateForward() { }
        func retire(call: Bool, pictureInPicture: Bool) { }
        func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) { done([]) }
        func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) { done(nil, nil) }
        func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) { drawnCalls += 1; done(drawn) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                      done: (@MainActor (Result<Any?, Error>) -> Void)?) { scripts += 1; done?(.success(nil)) }
        func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? { scripts += 1; return nil }
        func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool { false }
        func agentHover(x: Double, y: Double) -> Bool { false }
        func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) { done(false) }
        func insertAgentText(_ text: String) { }
        func sendAgentKeys(_ strokes: [PageKey]) { }
        func setCameraCapture(_ state: PageMediaState) { }
        func setMicrophoneCapture(_ state: PageMediaState) { }
        func stopDisplayCapture() { }
        func killContent() { }
    }
    private final class PrintedPage: Page, PagePrintedPDF {
        let data: Data
        var printedCalls = 0
        var failure: Error?
        init(_ text: String) {
            _ = NSApplication.shared
            let buffer = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            let consumer = CGDataConsumer(data: buffer as CFMutableData)!
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 740)
            // Use the same AppKit text path as the independently validated
            // PDFSign fixture. CoreText/system-font draw can reorder underscores
            // during PDFKit extraction before PageSave ever sees the input.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 16)!,
                .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 40, y: 740))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage(); context.closePDF()
            data = buffer as Data
            super.init(.chromium)
        }
        required init?(coder: NSCoder) { nil }
        func savePrintedPDF(to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
            printedCalls += 1
            if let failure { done(.failure(failure)); return }
            do { try data.write(to: file); done(.success(file)) } catch { done(.failure(error)) }
        }
    }
    private func tab(_ page: Page, choices: @escaping (PageEngineKind) -> Void = { _ in }) -> Tab {
        _ = NSApplication.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let factory = PageEngineFactory(kinds: [.webKit, .chromium]) { _, kind in choices(kind); return page }
        let tab = Tab(configuration: config, engine: page.engine, factory: factory)
        tab.restore(url: URL(string: "https://save-routing.test/" + UUID().uuidString)!, title: page.title ?? "Printed fixture")
        return tab
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func selectedChromiumBookUsesEveryNativePrintProducerAndPreservesOrder() async throws {
        let a = PrintedPage("BOOK_A_NATIVE"), b = PrintedPage("BOOK_B_NATIVE")
        a.title = "Source A"; b.title = "Source B"
        // Validate each independent source before any routing/join operation,
        // so bad fixture text cannot be mistaken for a product merge failure.
        let inputA = try #require(PDFDocument(data: a.data)), inputB = try #require(PDFDocument(data: b.data))
        try #require(inputA.pageCount == 1 && inputB.pageCount == 1)
        let textA = inputA.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let textB = inputB.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(textA == "BOOK_A_NATIVE" && textB == "BOOK_B_NATIVE", "Original PDF fixtures retain exact markers")
        var choices: [PageEngineKind] = []
        let first = tab(a) { choices.append($0) }, second = tab(b) { choices.append($0) }
        let folder = try folder()
        defer { first.close(); second.close(); try? FileManager.default.removeItem(at: folder) }
        let file: URL = try await withCheckedThrowingContinuation { done in
            PageSave.book([second, first], reader: false, title: "Native book", in: folder) { done.resume(with: $0) }
        }
        let pdf = try #require(PDFDocument(url: file))
        #expect(pdf.pageCount == 2 && pdf.string?.contains("BOOK_A_NATIVE") == true && pdf.string?.contains("BOOK_B_NATIVE") == true)
        #expect(pdf.outlineRoot?.child(at: 0)?.label == "Source B" && pdf.outlineRoot?.child(at: 1)?.label == "Source A")
        #expect(pdf.page(at: 0)?.string?.contains("BOOK_B_NATIVE") == true && pdf.page(at: 1)?.string?.contains("BOOK_A_NATIVE") == true)
        #expect(a.printedCalls == 1 && b.printedCalls == 1 && a.drawnCalls == 0 && b.drawnCalls == 0)
        #expect(choices == [.chromium, .chromium] && first.builtPage === a && second.builtPage === b)
        #expect(a.scripts == 0 && b.scripts == 0)
    }

    @Test func singleSaveAndBookArticleFallbackShareTheNativePrintRoute() async throws {
        let page = PrintedPage("SAME_NATIVE_PRINT_ROUTE"), tab = tab(page), folder = try folder()
        defer { tab.close(); try? FileManager.default.removeItem(at: folder) }
        let single: URL = try await withCheckedThrowingContinuation { done in
            PageSave.save(tab, as: "pdf", in: folder) { done.resume(with: $0) }
        }
        let article = folder.appendingPathComponent("article-fallback.pdf")
        let fallback: URL = try await withCheckedThrowingContinuation { done in
            PageSave.article(tab, to: article) { done.resume(with: $0) }
        }
        let singleData = try Data(contentsOf: single), fallbackData = try Data(contentsOf: fallback)
        #expect(singleData == page.data && fallbackData == page.data)
        #expect(page.printedCalls == 2 && page.drawnCalls == 0 && page.scripts == 1)
    }

    @Test func nativePrintFailureNeverFallsBackToDrawnOrOriginalPDFBytes() async throws {
        let page = PrintedPage("DO_NOT_SUBSTITUTE"), folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        page.failure = PageSave.Failure("Original native print failed")
        page.drawn = .success(Data("Original resource bytes are not a printed page".utf8))
        let file = folder.appendingPathComponent("failed.pdf")
        let result: Result<URL, Error> = await withCheckedContinuation { done in PageSave.pdfPage(page, to: file) { done.resume(returning: $0) } }
        if case .success = result { Issue.record("Native failure must propagate") }
        #expect(page.printedCalls == 1 && page.drawnCalls == 0 && !FileManager.default.fileExists(atPath: file.path))
    }

    @Test func genericDrawnPDFRouteStaysAvailableForAnEngineWithoutPrintCapability() async throws {
        let page = Page(.webKit), folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let expected = PrintedPage("GENERIC_DRAWN_PDF").data; page.drawn = .success(expected)
        let file = folder.appendingPathComponent("generic.pdf")
        let saved: URL = try await withCheckedThrowingContinuation { done in PageSave.pdfPage(page, to: file) { done.resume(with: $0) } }
        let savedData = try Data(contentsOf: saved)
        #expect(savedData == expected && page.drawnCalls == 1)
    }

    @Test func fullPagePNGDoesNotSubstitutePaginatedPrintPDF() async throws {
        let page = PrintedPage("NOT_A_FULL_PAGE_PNG"), tab = tab(page), folder = try folder()
        defer { tab.close(); try? FileManager.default.removeItem(at: folder) }
        let result: Result<URL, Error> = await withCheckedContinuation { done in PageSave.save(tab, as: "png", in: folder) { done.resume(returning: $0) } }
        if case .success = result { Issue.record("The unsupported drawn document primitive must remain explicit") }
        #expect(page.drawnCalls == 1 && page.printedCalls == 0)
    }
}
