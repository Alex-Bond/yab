import Foundation
import Observation
import ImageIO
import UIKit
import WebKit

/// Public page icons, in memory and in Caches so a site whose icon only its
/// page declares keeps it across launches. Requests use the page's own origin
/// without browser cookies, credentials, a shared URL cache, or external services.
@MainActor
@Observable
final class SiteIcons {
    static let shared = SiteIcons(accepts: { url in
        // Native tests use only their loopback fixture servers.
        !LaunchOptions.current.isTestRun || ["localhost", "127.0.0.1", "::1"].contains(url.host()?.lowercased() ?? "")
    })
    @ObservationIgnored private var checked: Set<String> = []
    @ObservationIgnored private var declarations: [String: [URL]] = [:]
    private var pictures: [String: UIImage] = [:]
    @ObservationIgnored private var requests: [String: Request] = [:]
    @ObservationIgnored private var failures: [String: Failure] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var restoration: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let accepts: (URL) -> Bool
    private let retryDelay: TimeInterval
    private let keptDirectory: URL?
    private static let byteLimit = 1_048_576

    private struct Request { let token: UUID; let task: Task<Bool, Never> }
    private struct Failure { let address: URL; let at: Date }

    init(retryDelay: TimeInterval = 30, now: @escaping () -> Date = Date.init, keptDirectory: URL? = nil,
         accepts: @escaping (URL) -> Bool = { _ in true }) {
        self.retryDelay = retryDelay
        self.now = now
        self.accepts = accepts
        self.keptDirectory = keptDirectory
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        session = URLSession(configuration: config, delegate: SiteIconRedirects(), delegateQueue: nil)
    }

    func image(for url: URL) -> UIImage? {
        Self.origin(of: url).flatMap { pictures[$0.absoluteString] }
    }

    @ObservationIgnored private lazy var keptFolder: URL? = {
        // An explicit profile can restore fixtures without using personal cache
        // files or enabling the network in a test run.
        let profileFolder: URL? = LaunchOptions.current.profileDirectory.flatMap {
            guard !$0.isEmpty else { return nil }
            return URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("SiteIcons", isDirectory: true)
        }
        guard profileFolder != nil || accepts(URL(string: "https://example.com")!) else { return nil }
        let folder = keptDirectory ?? profileFolder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("SiteIcons")
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        return folder
    }()

    private func keptFile(_ key: String) -> URL? {
        keptFolder?.appendingPathComponent(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)
    }

    /// Profile observation can ask again before the first read finishes. Disk
    /// reads and image creation must not hold up the launch field or its keyboard.
    func restoreKept() async {
        if let restoration { await restoration.value; return }
        guard let keptFolder else { return }
        let generation = generation
        let task = Task { @MainActor [weak self] in
            let reader = Task.detached(priority: .utility) { Self.readKept(in: keptFolder) }
            let saved = await withTaskCancellationHandler {
                await reader.value
            } onCancel: {
                reader.cancel()
            }
            for (index, picture) in saved.enumerated() {
                guard let self, !Task.isCancelled, self.generation == generation else { return }
                // A page may have fetched a fresher icon while disk was read.
                if self.pictures[picture.key] == nil { self.pictures[picture.key] = picture.image }
                if index % 32 == 31 { await Task.yield() }
            }
        }
        restoration = task
        await task.value
    }

    /// Images are immutable after construction; only publication is on main.
    private struct KeptPicture: @unchecked Sendable {
        let key: String
        let image: UIImage
    }

    private nonisolated static func readKept(in folder: URL) -> [KeptPicture] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var saved: [KeptPicture] = []
        for file in files {
            if Task.isCancelled { break }
            guard let key = file.lastPathComponent.removingPercentEncoding,
                  let data = try? Data(contentsOf: file), let image = Self.decode(data) else { continue }
            saved.append(KeptPicture(key: key, image: image))
        }
        return saved
    }

    /// Legacy callers without a URL may use only an unambiguous public origin.
    func image(for host: String) -> UIImage? {
        let matches = pictures.filter { URL(string: $0.key)?.host()?.lowercased() == host.lowercased() }
        return matches.count == 1 ? matches.first?.value : nil
    }

    /// Loading a space must not visit its pages, or disclose any private tab.
    /// `shown` are tabs the space shows that aren't its own: pins shared
    /// from Personal or only on the Mac stayed letters until visited.
    func prefetch(_ space: Space, shown: [Tab] = []) async {
        guard !space.isPrivate else { return }
        var seen: Set<String> = []
        let addresses = (space.allTabs + shown).compactMap { tab -> URL? in
            guard !tab.isPrivate, !tab.isMail, let url = tab.navigationURL,
                  let origin = Self.origin(of: url), seen.insert(origin.absoluteString).inserted else { return nil }
            return url
        }
        await withTaskGroup(of: Void.self) { group in
            var next = addresses.makeIterator()
            for _ in 0..<4 {
                if let url = next.next() { group.addTask { _ = await self.load(for: url) } }
            }
            while await group.next() != nil {
                if let url = next.next() { group.addTask { _ = await self.load(for: url) } }
            }
        }
    }

    /// One page of each public origin the space's page shows, pins first.
    static func addresses(_ space: Space, pins: [Tab] = []) -> [URL] {
        guard !space.isPrivate else { return [] }
        var seen: Set<String> = []
        return (pins + space.allTabs).compactMap { tab -> URL? in
            guard !tab.isPrivate, !tab.isMail, let url = tab.navigationURL,
                  let origin = Self.origin(of: url), seen.insert(origin.absoluteString).inserted else { return nil }
            return url
        }
    }

    func read(from view: WKWebView) {
        guard view.configuration.websiteDataStore.isPersistent, let page = view.url,
              let origin = Self.origin(of: page), accepts(origin) else { return }
        view.evaluateJavaScript("Array.from(document.querySelectorAll('link[rel]')).map(link => { const copy = link.cloneNode(); copy.href = link.href; return copy.outerHTML; }).join('\\n')") { [weak self, weak view] value, _ in
            MainActor.assumeIsolated {
                guard let self, let view, view.url == page,
                      view.configuration.websiteDataStore.isPersistent else { return }
                let html = value as? String ?? ""
                let declared = Self.declaredIcons(in: html, page: page) + Self.declaredIcons(in: html, page: page, vectors: true)
                Task { @MainActor [weak self] in await self?.load(for: page, declaredIcons: declared) }
            }
        }
    }

    /// A declared icon on the same origin, or on any https host (a CDN). The root
    /// icon is the fallback for a cold tab; failing that, an https site's own home
    /// page names its icon. No cookies either way.
    @discardableResult
    func load(for page: URL, declaredIcon: URL? = nil, isPrivate: Bool = false) async -> Bool {
        await load(for: page, declaredIcons: declaredIcon.map { [$0] } ?? [], isPrivate: isPrivate)
    }

    @discardableResult
    func load(for page: URL, declaredIcons: [URL], isPrivate: Bool = false) async -> Bool {
        guard !isPrivate, let origin = Self.origin(of: page), accepts(origin) else { return false }
        let key = origin.absoluteString
        if pictures[key] != nil, (origin.scheme != "https" || checked.contains(key)),
           declaredIcons.isEmpty || declarations[key] == declaredIcons { return true }
        let fallback = origin.appendingPathComponent("favicon.ico")
        let declared = declaredIcons.filter { candidate in
            if Self.vectorData(candidate) != nil { return true }
            guard let candidateOrigin = Self.origin(of: candidate) else { return false }
            return candidateOrigin == origin || candidateOrigin.scheme == "https"
        }
        let address = declared.first ?? fallback
        if let existing = requests[key] {
            let loaded = await existing.task.value
            if loaded, declared.isEmpty || declarations[key] == declaredIcons { return true }
            // A page may offer a custom icon while its cold root request runs.
            if address == fallback { return false }
            return await load(for: page, declaredIcons: declared)
        }
        if let failure = failures[key], failure.address == address,
           now().timeIntervalSince(failure.at) < retryDelay { return false }
        let token = UUID()
        let currentGeneration = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { if requests[key]?.token == token { requests[key] = nil } }
            var seen: Set<URL> = []
            var discovered: [URL] = []
            // Cold synced tabs have no live DOM. Discover the public home page
            // before accepting a tiny root favicon as the permanent picture.
            if declared.isEmpty, origin.scheme == "https",
               let home = await fetch(origin, origin: origin),
               let html = String(data: home.data, encoding: .utf8) {
                let touch = Self.declaredIcons(in: html, page: home.url, relation: "apple-touch-icon")
                discovered = touch
                if let manifest = Self.manifest(in: html, page: home.url),
                   let file = await fetch(manifest, origin: origin) {
                    discovered += Self.manifestIcons(in: file.data, page: file.url)
                    discovered += Self.manifestIcons(in: file.data, page: file.url, vectors: true)
                }
                discovered += Self.declaredIcons(in: html, page: home.url)
                discovered += Self.declaredIcons(in: html, page: home.url, vectors: true)
            }
            let candidates = (declared + discovered + [fallback]).filter { seen.insert($0).inserted }
            for candidate in candidates {
                // A failed refresh must not downgrade a kept touch icon to
                // the site's smaller generic root favicon.
                if candidate == fallback, pictures[key] != nil { continue }
                guard !Task.isCancelled, generation == currentGeneration else { return false }
                let bytes = Self.vectorData(candidate)
                let fetched: (data: Data, url: URL)?
                if let bytes { fetched = (bytes, candidate) } else { fetched = await fetch(candidate, origin: origin) }
                if let fetched, let image = await decodeIcon(fetched.data),
                   !Task.isCancelled, generation == currentGeneration {
                    checked.insert(key)
                    declarations[key] = declaredIcons
                    pictures[key] = image
                    failures[key] = nil
                    if let file = keptFile(key) { try? image.pngData()?.write(to: file, options: .atomic) }
                    return true
                }
            }
            if !Task.isCancelled, generation == currentGeneration { failures[key] = Failure(address: address, at: now()) }
            return false
        }
        requests[key] = Request(token: token, task: task)
        return await task.value
    }

    private func fetch(_ url: URL, origin: URL) async -> (data: Data, url: URL)? {
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: url))
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let final = response.url, Self.origin(of: final) == origin || final.scheme == "https",
                  response.expectedContentLength <= Int64(Self.byteLimit) else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard !Task.isCancelled, data.count < Self.byteLimit else { return nil }
                data.append(byte)
            }
            return (data, final)
        } catch { return nil }
    }

    /// Prefer touch icons, then raster favicons. A first SVG must not hide a
    /// later PNG. Match attribute names and rel tokens, including unquoted HTML.
    nonisolated static func declaredIcons(in html: String, page: URL, relation: String? = nil, vectors: Bool = false) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attribute = try? NSRegularExpression(
                pattern: #"(?:^|\s)([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        var ranked: [(url: URL, touch: Bool, pixels: Int)] = []
        for match in tag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range, in: html) else { continue }
            let link = String(html[range])
            var values: [String: String] = [:]
            for item in attribute.matches(in: link, range: NSRange(link.startIndex..., in: link)) {
                guard let key = Range(item.range(at: 1), in: link),
                      let value = (2...4).compactMap({ Range(item.range(at: $0), in: link) }).first else { continue }
                values[String(link[key]).lowercased()] = String(link[value])
            }
            let kinds = Set((values["rel"] ?? "").lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init))
            let isTouch = !kinds.isDisjoint(with: ["apple-touch-icon", "apple-touch-icon-precomposed"])
            let accepted = relation.map { $0 == "apple-touch-icon" ? isTouch : kinds.contains($0) } ?? (isTouch || kinds.contains("icon"))
            guard accepted,
                  let address = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"), !address.isEmpty,
                  let url = URL(string: address, relativeTo: page)?.absoluteURL,
                  (Self.origin(of: url).map { $0 == Self.origin(of: page) || $0.scheme == "https" } ?? (vectors && Self.vectorData(url) != nil)) else { continue }
            let isVector = url.pathExtension.lowercased() == "svg" || values["type"]?.lowercased() == "image/svg+xml" || Self.vectorData(url) != nil
            guard vectors == isVector else { continue }
            let pixels = (values["sizes"] ?? "").split(separator: " ").compactMap {
                Int($0.lowercased().split(separator: "x").first ?? "")
            }.max() ?? 0
            ranked.append((url, isTouch, pixels))
        }
        var seen: Set<URL> = []
        return ranked.enumerated().sorted {
            if $0.element.touch != $1.element.touch { return $0.element.touch }
            if $0.element.pixels != $1.element.pixels { return $0.element.pixels > $1.element.pixels }
            return $0.offset < $1.offset
        }.map { $0.element.url }.filter { seen.insert($0).inserted }.prefix(12).map { $0 }
    }

    func decodeIcon(_ data: Data) async -> UIImage? {
        if let image = Self.decode(data) { return image }
        guard data.count <= Self.byteLimit, String(data: data, encoding: .utf8)?.contains("<svg") == true else { return nil }
        return await SiteIconVector.image(data)
    }

    nonisolated static func vectorData(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard text.lowercased().hasPrefix("data:image/svg+xml"), let comma = text.firstIndex(of: ",") else { return nil }
        let header = String(text[..<comma]).lowercased()
        guard header == "data:image/svg+xml" || header == "data:image/svg+xml;base64" || header == "data:image/svg+xml;charset=utf-8" else { return nil }
        let payload = String(text[text.index(after: comma)...])
        let data = header.hasSuffix(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding?.data(using: .utf8)
        guard let data, data.count <= byteLimit else { return nil }
        return data
    }

    /// Decode the largest ICO representation, rather than UIKit's first frame.
    nonisolated static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let index = (0..<CGImageSourceGetCount(source)).max { a, b in
            func area(_ i: Int) -> Int {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                return (properties?[kCGImagePropertyPixelWidth] as? Int ?? 0) *
                    (properties?[kCGImagePropertyPixelHeight] as? Int ?? 0)
            }
            return area(a) < area(b)
        }
        guard let index, let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    nonisolated static func manifest(in html: String, page: URL) -> URL? {
        declaredIcons(in: html, page: page, relation: "manifest").first
    }

    nonisolated static func manifestIcons(in data: Data, page: URL, vectors: Bool = false) -> [URL] {
        struct Manifest: Decodable {
            struct Icon: Decodable { let src: String; let sizes: String?; let type: String? }
            let icons: [Icon]?
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return [] }
        return (manifest.icons ?? []).sorted {
            func size(_ value: String?) -> Int {
                (value ?? "").split(separator: " ").compactMap { Int($0.split(separator: "x").first ?? "") }.max() ?? 0
            }
            return size($0.sizes) > size($1.sizes)
        }.compactMap {
            guard let url = URL(string: $0.src, relativeTo: page)?.absoluteURL,
                  Self.origin(of: url).map({ $0 == Self.origin(of: page) || $0.scheme == "https" }) ?? (vectors && Self.vectorData(url) != nil) else { return nil }
            let isVector = $0.type?.lowercased() == "image/svg+xml" || url.pathExtension.lowercased() == "svg" || Self.vectorData(url) != nil
            return vectors == isVector ? url : nil
        }
    }

    /// Same host on HTTP, HTTPS, or another port is a different icon origin.
    nonisolated static func origin(of url: URL) -> URL? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        if let port = parts.port, !(scheme == "http" && port == 80), !(scheme == "https" && port == 443) { origin.port = port }
        return origin.url
    }

    func removeAll() {
        generation = UUID()
        restoration?.cancel()
        restoration = nil
        requests.values.forEach { $0.task.cancel() }
        requests = [:]
        failures = [:]
        pictures = [:]
        declarations = [:]
        checked = []
        if let keptFolder { try? FileManager.default.removeItem(at: keptFolder) }
        keptFolder = nil
    }
}

private final class SiteIconRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // An icon may live on the site's www host or a CDN: https only, no cookies are ever sent.
        guard let initial = task.originalRequest?.url, let redirected = request.url,
              let origin = SiteIcons.origin(of: initial), SiteIcons.origin(of: redirected) == origin || redirected.scheme == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// SVG is rendered as an inert image, never as a document from a website.
/// The isolated ephemeral renderer has no scripts, cookies or network sources.
@MainActor
private final class SiteIconVector: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var view: WKWebView?
    private var deadline: Task<Void, Never>?

    static func image(_ data: Data) async -> UIImage? {
        let renderer = SiteIconVector()
        return await renderer.render(data)
    }

    private func render(_ data: Data) async -> UIImage? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = false
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 256, height: 256), configuration: config)
            web.isOpaque = false
            web.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false
            web.navigationDelegate = self
            view = web
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
            web.loadHTMLString("""
            <!doctype html><meta name="viewport" content="width=256,initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
            <style>html,body{margin:0;width:256px;height:256px;background:transparent}img{width:256px;height:256px;object-fit:contain}</style>
            <img src="data:image/svg+xml;base64,\(data.base64EncodedString())">
            """, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { [weak self] in
            let config = WKSnapshotConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 256, height: 256)
            config.snapshotWidth = 256
            let image = try? await webView.takeSnapshot(configuration: config)
            self?.finish(image)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func finish(_ image: UIImage?) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        view?.stopLoading(); view?.navigationDelegate = nil; view = nil
        continuation.resume(returning: image)
    }
}
