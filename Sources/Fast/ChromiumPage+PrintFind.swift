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

    /// Printed Letter pages, including content outside the viewport and print
    /// styles. A stream keeps large documents below the wire's frame limit.
    func printedPDF(printSource: String? = nil) async throws -> Data {
        let remote = remoteID, epoch = nativePrintEpoch
        let parameters: [String: JSONValue] = printSource.map { ["printSource": .string($0)] } ?? [:]
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
              let operation = document.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true) else { return }
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
