import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// data: is the image itself; blob: belongs to the frame that made it.
/// Neither is a new HTTP navigation. Feed their bytes into the same
/// destination, progress and completion contract as a network download.
@MainActor
final class ImageDownload: PageDownload {
    let downloadID = UUID()
    let originalRequest: URLRequest?
    let isUserInitiated = true
    let progress = Progress(totalUnitCount: -1)
    let page: (any PageHandle)?
    var sourceView: NSView? { web }
    let pageURL: URL?
    let pageTitle: String?
    weak var downloadEvents: (any PageDownloadEvents)?
    private let web: WKWebView
    private let frame: WKFrameInfo?
    private var task: Task<Void, Never>?
    private var terminal = false
    private var canceled = false
    nonisolated static let limit = 64 << 20

    init(url: URL, page: WKWebView, frame: WKFrameInfo?) {
        originalRequest = URLRequest(url: url)
        self.page = page as? any PageHandle
        pageURL = frame?.request.url ?? page.url
        pageTitle = page.title
        web = page
        self.frame = frame
    }

    struct Bytes: Sendable {
        let data: Data
        let mime: String
    }

    nonisolated static func inline(_ url: URL, inferImageType: Bool = false) throws -> Bytes {
        let text = String(url.absoluteString.prefix { $0 != "#" })
        guard text.utf8.count <= limit * 2, text.lowercased().hasPrefix("data:"), let comma = text.firstIndex(of: ",") else {
            throw URLError(.cannotDecodeContentData)
        }
        let meta = text[text.index(text.startIndex, offsetBy: 5)..<comma].split(separator: ";", omittingEmptySubsequences: false)
        var mime = String(meta.first ?? "").lowercased()
        let raw = Array(text[text.index(after: comma)...].utf8)
        var decoded = Data(), i = 0
        func hex(_ c: UInt8) -> UInt8? {
            if (48...57).contains(c) { return c - 48 }
            if (65...70).contains(c) { return c - 55 }
            if (97...102).contains(c) { return c - 87 }
            return nil
        }
        while i < raw.count {
            if raw[i] == 37 {
                guard i + 2 < raw.count, let high = hex(raw[i + 1]), let low = hex(raw[i + 2]) else { throw URLError(.cannotDecodeContentData) }
                decoded.append(high * 16 + low); i += 3
            } else { decoded.append(raw[i]); i += 1 }
        }
        let data: Data
        if meta.last?.lowercased() == "base64" {
            let compact = Data(decoded.filter { ![9, 10, 12, 13, 32].contains($0) })
            guard let bytes = Data(base64Encoded: compact) else { throw URLError(.cannotDecodeContentData) }
            data = bytes
        } else { data = decoded }
        guard !data.isEmpty, data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        if !mime.hasPrefix("image/"), inferImageType,
           let image = CGImageSourceCreateWithData(data as CFData, nil),
           let kind = CGImageSourceGetType(image), let found = UTType(kind as String)?.preferredMIMEType { mime = found }
        if !mime.hasPrefix("image/"), inferImageType {
            let parser = XMLParser(data: data), root = SVGRoot()
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = root
            if parser.parse(), root.isSVG { mime = "image/svg+xml" }
        }
        guard mime.hasPrefix("image/") else { throw URLError(.cannotDecodeContentData) }
        return Bytes(data: data, mime: mime)
    }

    private final class SVGRoot: NSObject, XMLParserDelegate {
        var isSVG = false
        private var sawRoot = false
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard !sawRoot else { return }
            sawRoot = true
            isSVG = elementName == "svg" && (namespaceURI == nil || namespaceURI == "http://www.w3.org/2000/svg")
        }
    }

    private func read() async throws -> Bytes {
        guard let url = originalRequest?.url else { throw URLError(.badURL) }
        if url.scheme?.lowercased() == "data" { return try await Task.detached(priority: .utility) { try Self.inline(url) }.value }
        let value = try await web.callAsyncJavaScript("""
            const response = await fetch(src);
            if (!response.ok) throw new Error('HTTP ' + response.status);
            const blob = await response.blob();
            if (!blob.size || blob.size > limit) throw new Error('Invalid image');
            return await new Promise((resolve, reject) => {
              const reader = new FileReader();
              reader.onerror = () => reject(new Error('Image read failed'));
              reader.onload = () => resolve(reader.result);
              reader.readAsDataURL(blob);
            });
            """, arguments: ["src": url.absoluteString, "limit": Self.limit], in: frame, contentWorld: .defaultClient)
        guard let text = value as? String, let inline = URL(string: text) else { throw URLError(.cannotDecodeContentData) }
        return try await Task.detached(priority: .utility) { try Self.inline(inline, inferImageType: true) }.value
    }

    func start() {
        guard task == nil, !terminal else { return }
        task = Task { [self] in
            do {
                let bytes = try await read()
                try Task.checkCancellation()
                guard !canceled, let events = downloadEvents, let url = originalRequest?.url else { throw URLError(.cancelled) }
                progress.totalUnitCount = Int64(bytes.data.count)
                let ext = UTType(mimeType: bytes.mime)?.preferredFilenameExtension ?? "img"
                let response = URLResponse(url: url, mimeType: bytes.mime, expectedContentLength: bytes.data.count, textEncodingName: nil)
                let file: URL? = await withCheckedContinuation { done in
                    events.download(self, decideDestinationUsing: response, suggestedFilename: "image." + ext) { done.resume(returning: $0) }
                }
                try Task.checkCancellation()
                guard !canceled, let file else { throw URLError(.cancelled) }
                // Never overwrite a file created while destination consent was pending.
                try await Task.detached(priority: .utility) { try bytes.data.write(to: file, options: .withoutOverwriting) }.value
                try Task.checkCancellation()
                guard !canceled else { throw URLError(.cancelled) }
                progress.fileURL = file
                progress.completedUnitCount = Int64(bytes.data.count)
                terminal = true
                downloadEvents?.downloadDidFinish(self)
            } catch { fail(error) }
        }
    }

    private func fail(_ error: Error) {
        guard !terminal else { return }
        terminal = true
        downloadEvents?.download(self, didFailWithError: error, resumeData: nil)
    }

    func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) {
        canceled = true
        task?.cancel()
        fail(URLError(.cancelled))
        done(nil)
    }

    func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                         done: @escaping @MainActor ((any PageDownload)?) -> Void) {
        guard let url = originalRequest?.url else { done(nil); return }
        let next = ImageDownload(url: url, page: web, frame: frame)
        done(next)
        next.start()
    }
}
