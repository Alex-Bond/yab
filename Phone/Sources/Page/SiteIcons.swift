import Foundation
import Observation
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
                  let data = try? Data(contentsOf: file), let image = UIImage(data: data) else { continue }
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
    func prefetch(_ space: Space) async {
        guard !space.isPrivate else { return }
        var seen: Set<String> = []
        let addresses = space.allTabs.compactMap { tab -> URL? in
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

    func read(from view: WKWebView) {
        guard view.configuration.websiteDataStore.isPersistent, let page = view.url,
              let origin = Self.origin(of: page), accepts(origin) else { return }
        view.evaluateJavaScript("Array.from(document.querySelectorAll('link[rel]')).map(link => { const copy = link.cloneNode(); copy.href = link.href; return copy.outerHTML; }).join('\\n')") { [weak self, weak view] value, _ in
            MainActor.assumeIsolated {
                guard let self, let view, view.url == page,
                      view.configuration.websiteDataStore.isPersistent else { return }
                let declared = Self.declaredIcons(in: value as? String ?? "", page: page)
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
        if pictures[key] != nil { return true }
        let fallback = origin.appendingPathComponent("favicon.ico")
        let declared = declaredIcons.filter { candidate in
            guard let candidateOrigin = Self.origin(of: candidate) else { return false }
            return candidateOrigin == origin || candidateOrigin.scheme == "https"
        }
        let address = declared.first ?? fallback
        if let existing = requests[key] {
            let loaded = await existing.task.value
            if loaded { return true }
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
            let candidates = (declared + [fallback]).filter { seen.insert($0).inserted }
            for candidate in candidates {
                guard !Task.isCancelled, generation == currentGeneration else { return false }
                if let fetched = await fetch(candidate, origin: origin),
                   !Task.isCancelled, generation == currentGeneration,
                   let image = UIImage(data: fetched.data) {
                    pictures[key] = image
                    failures[key] = nil
                    if let file = keptFile(key) { try? fetched.data.write(to: file, options: .atomic) }
                    return true
                }
            }
            if origin.scheme == "https", !Task.isCancelled, generation == currentGeneration, let home = await fetch(origin, origin: origin),
               let html = String(data: home.data, encoding: .utf8) {
                for candidate in Self.declaredIcons(in: html, page: home.url) {
                    guard !Task.isCancelled, generation == currentGeneration else { return false }
                    if let fetched = await fetch(candidate, origin: origin), let image = UIImage(data: fetched.data) {
                        pictures[key] = image
                        failures[key] = nil
                        if let file = keptFile(key) { try? fetched.data.write(to: file, options: .atomic) }
                        return true
                    }
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
    nonisolated static func declaredIcons(in html: String, page: URL) -> [URL] {
        guard let tag = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive),
              let attribute = try? NSRegularExpression(
                pattern: #"(?:^|\s)([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        var touch: [URL] = [], plain: [URL] = []
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
            guard isTouch || kinds.contains("icon"),
                  let address = values["href"]?.replacingOccurrences(of: "&amp;", with: "&"), !address.isEmpty,
                  let url = URL(string: address, relativeTo: page)?.absoluteURL,
                  let origin = Self.origin(of: url), origin == Self.origin(of: page) || origin.scheme == "https",
                  url.pathExtension.lowercased() != "svg",
                  values["type"]?.lowercased() != "image/svg+xml" else { continue }
            if isTouch { touch.append(url) } else { plain.append(url) }
        }
        var seen: Set<URL> = []
        return Array((touch + plain).filter { seen.insert($0).inserted }.prefix(4))
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
