import AppKit
import PDFKit
import YabCoreClient

extension ChromiumPage {
    /// Original native RFH print source, retained across print.finish.
    /// This is an opaque capability, never a caller-selected frame or URL.
    struct NativePrintSource {
        let token: String
        init?(_ params: [String: JSONValue]) {
            guard params["sourceVersion"] == .number(1),
                  let token = params["source"]?.string, !token.isEmpty, token.count <= 256,
                  let document = params["nativeDocument"]?.string, !document.isEmpty, document.count <= 256,
                  let frame = params["frameId"]?.string, !frame.isEmpty, frame.count <= 256 else { return nil }
            self.token = token
        }
    }

    struct NativeFindResult {
        let total: Int
        let index: Int
        let capped: Bool
    }

    /// CEF assigns find identifiers itself. Serialize calls through their final
    /// result, including Stop, so a late count cannot answer a newer query.
    func nativeFind(_ text: String, forward: Bool, done: @escaping @MainActor (NativeFindResult?) -> Void) {
        let previous = nativeFindTask, epoch = nativeFindEpoch
        nativeFindTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.nativeFindEpoch == epoch else { return }
            do {
                let result = try await self.navigationRequest("page.find", ["text": .string(text), "forward": .bool(forward)])
                guard self.nativeFindEpoch == epoch else { return }
                let count = max(0, Int(result["count"].number ?? 0))
                let ordinal = Int(result["ordinal"].number ?? 0)
                let index = count == 0 || ordinal == 0 ? -1 : min(ordinal - 1, min(count, 1000) - 1)
                done(NativeFindResult(total: min(count, 1000), index: index, capped: count > 1000))
            } catch { if self.nativeFindEpoch == epoch { done(nil) } }
        }
    }

    func stopNativeFind() {
        nativeFindEpoch += 1
        let previous = nativeFindTask
        nativeFindTask = Task { @MainActor [weak self] in
            await previous?.value
            _ = try? await self?.navigationRequest("page.find.stop")
        }
    }

    /// Printed pages, including content outside the viewport and print
    /// styles, as Chromium prints them: on the sheet's paper, 1 cm margins,
    /// 100% (YabCore's page.printPDF). A stream keeps large documents below
    /// the wire's frame limit.
    func printedPDF(printSource: String? = nil) async throws -> Data {
        let remote = remoteID, epoch = nativePrintEpoch
        let paper = NSPrintInfo.shared.paperSize
        var parameters: [String: JSONValue] = ["paperWidth": .number(Double(paper.width) / 72), "paperHeight": .number(Double(paper.height) / 72)]
        if let printSource { parameters["printSource"] = .string(printSource) }
        let started = try await navigationRequest("page.printPDF", parameters)
        guard remoteID == remote, nativePrintEpoch == epoch else { throw CancellationError() }
        guard let token = started["stream"].string else { throw YabCoreError.remote("PDF stream missing") }
        defer {
            Task { @MainActor [weak self] in
                guard let self, let remote, self.remoteID == remote else { return }
                _ = try? await self.navigationRequest("page.pdf.close", ["stream": .string(token)])
            }
        }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let part = try await navigationRequest("page.pdf.read", ["stream": .string(token)])
            guard remoteID == remote, nativePrintEpoch == epoch else { throw CancellationError() }
            guard let text = part["data"].string else { throw YabCoreError.remote("PDF stream data missing") }
            let bytes: Data
            if part["base64Encoded"] == .bool(true) {
                guard let decoded = Data(base64Encoded: text) else { throw YabCoreError.remote("Invalid PDF stream") }
                bytes = decoded
            } else { bytes = Data(text.utf8) }
            guard data.count + bytes.count <= 64 * 1024 * 1024 else { throw YabCoreError.remote("Printed PDF exceeds 64 MiB") }
            data.append(bytes)
            if part["eof"] == .bool(true) { break }
        }
        guard data.starts(with: Data("%PDF-".utf8)), let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw YabCoreError.remote("Chromium returned an invalid PDF")
        }
        return data
    }

    func savePrintedPDF(to file: URL, done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        Task { @MainActor in
            do { try await printedPDF().write(to: file, options: .atomic); done(.success(file)) }
            catch { done(.failure(error)) }
        }
    }

    func printSheet(in window: NSWindow) {
        let epoch = nativePrintEpoch
        Task { @MainActor [weak self, weak window] in
            guard let self, let window else { return }
            do {
                let data = try await self.printedPDF()
                guard self.nativePrintEpoch == epoch else { return }
                self.presentPrintedPDF(data, in: window)
            } catch { DebugLog.note("print", ["error": error.localizedDescription]) }
        }
    }

    private func presentPrintedPDF(_ data: Data, in window: NSWindow, nativeRequest: [String: JSONValue]? = nil) {
        guard self.window === window, window.attachedSheet == nil, let document = PDFDocument(data: data),
              let operation = printOperation(for: document) else { return }
        Browser.printed = url
        if Store.testing {
            printPreviewForTesting = ["pages": document.pageCount,
                                      "text": String((document.string ?? "").prefix(100_000)),
                                      "native": nativeRequest != nil,
                                      "requestURL": nativeRequest?["url"]?.string ?? "",
                                      "mainFrame": nativeRequest?["mainFrame"] == .bool(true)]
        }
        let end = PrintEnd { _ = document }
        operation.runModal(for: window, delegate: end, didRun: PrintEnd.selector, contextInfo: nil)
    }

    /// The sheet for Chromium's printed pages. They already carry Chrome's
    /// margins, so each goes on the paper as Chromium puts it there
    /// (PrintingContextMac::PrintDocument): at 100%, from the paper's top
    /// left corner. PDFKit's sheet fitted the page inside the sheet's own
    /// margins and the printer's area, a second frame over an inch at the
    /// top and right and the page shrunk (#2001).
    func printOperation(for document: PDFDocument) -> NSPrintOperation? {
        guard document.pageCount > 0 else { return nil }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: PrintedPages(document, paper: info.paperSize), printInfo: info)
        // The sheet's rows as PDFKit's operation had them.
        operation.printPanel.options = [.showsCopies, .showsPageRange, .showsPreview]
        return operation
    }

    func cancelNativePrint() {
        nativePrintEpoch &+= 1
        nativePrintRequestID = nil
        nativePrintTask?.cancel()
        nativePrintTask = nil
        printPreviewForTesting = [:]
    }

    /// Own-CEF suspends window.print() until this continuation is finished.
    /// Starting printToPDF before finishing fails and withdraws the request.
    func receiveNativePrint(_ params: [String: JSONValue]) {
        guard let request = params["request"]?.string, !request.isEmpty,
              request != nativePrintRequestID, let remote = remoteID else { return }
        nativePrintTask?.cancel()
        nativePrintRequestID = request
        DebugLog.note("print.request", ["pdf": params["pdf"] == .bool(true),
            "scripted": params["scripted"] == .bool(true), "mainFrame": params["mainFrame"] == .bool(true)])
        let epoch = nativePrintEpoch
        nativePrintTask = Task { @MainActor [weak self, weak window = window] in
            guard let self else { return }
            let source = NativePrintSource(params)
            // Cleanup must use this existing process generation directly,
            // even when the original print script still holds the page queue.
            // Browser loss already invalidates every native source token.
            let core = ChromiumProcess.shared.connectedClient
            defer {
                if let source, let core {
                    Task { @MainActor in
                        guard ChromiumProcess.shared.isCurrent(core) else { return }
                        _ = try? await core.request("print.source.release", params: [
                            "tab": .string(remote), "profile": .string(self.profile), "source": .string(source.token)])
                    }
                }
            }
            do {
                guard let core, ChromiumProcess.shared.isCurrent(core), self.remoteID == remote else { throw CancellationError() }
                let finished = try await self.finishNativePrint(request, remote: remote)
                DebugLog.note("print.finish", ["finished": finished, "pdf": params["pdf"] == .bool(true)])
                guard finished, !Task.isCancelled, self.remoteID == remote,
                      self.nativePrintEpoch == epoch, self.nativePrintRequestID == request,
                      let window, self.window === window else { return }
                guard let source else { throw YabCoreError.remote("Original native print source is unavailable") }
                let data = try await self.printedPDF(printSource: source.token)
                guard !Task.isCancelled, self.nativePrintEpoch == epoch,
                      self.nativePrintRequestID == request else { return }
                self.presentPrintedPDF(data, in: window, nativeRequest: params)
            } catch {
                if !Task.isCancelled { DebugLog.note("print", ["error": error.localizedDescription]) }
            }
        }
    }
}

/// Chromium's printed PDF as the sheet prints it: a page of the PDF on each
/// sheet of paper, unscaled, from the paper's top left corner, turned a quarter when
/// the paper is turned the other way from the page, as Chromium's
/// PdfMetafileCg::RenderPage does with autorotate and no fit to page.
final class PrintedPages: NSView {
    let document: PDFDocument
    private let paper: NSSize

    init(_ document: PDFDocument, paper: NSSize) {
        self.document = document
        self.paper = paper
        let side = max(paper.width, paper.height, 1)
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side * CGFloat(max(document.pageCount, 1))))
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The paper as the sheet now has it: its size or orientation may have
    /// changed in the sheet since the operation began.
    private var sheet: NSSize { NSPrintOperation.current?.printInfo.paperSize ?? paper }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: document.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let size = sheet, side = max(paper.width, paper.height, 1)
        return NSRect(x: 0, y: CGFloat(page - 1) * side, width: min(size.width, side), height: min(size.height, side))
    }

    override func draw(_ dirty: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // AppKit puts a page no nearer the paper's edge than the printer can
        // print, though the margins are none: drawn back by as much, the
        // page sits on the paper where Chrome puts it, and only what lies in
        // the printer's own edge, inside Chrome's 1 cm, is not printed.
        let info = NSPrintOperation.current?.printInfo
        let printable = info?.imageablePageBounds ?? .zero
        let edge = info.map { CGPoint(x: max(0, printable.minX), y: max(0, $0.paperSize.height - printable.maxY)) } ?? .zero
        for index in 0..<document.pageCount {
            let slot = rectForPage(index + 1)
            guard slot.intersects(dirty), let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let quarter = page.rotation % 180 != 0
            let size = quarter ? NSSize(width: box.height, height: box.width) : box.size
            let turn = (size.width > size.height) != (slot.width > slot.height) && size.width != size.height
            context.saveGState()
            context.clip(to: slot)
            context.translateBy(x: -edge.x, y: -edge.y)
            if turn {
                // A quarter to the left, as Chromium's RotatePage turns it: the
                // page's top along the paper's left edge.
                context.concatenate(CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: slot.minX + size.height, ty: slot.minY + size.width))
            } else {
                context.translateBy(x: slot.minX, y: slot.minY + size.height)
                context.scaleBy(x: 1, y: -1)
            }
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
        }
    }
}
