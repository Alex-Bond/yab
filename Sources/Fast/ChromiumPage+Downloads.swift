import AppKit
import YabCoreClient

@MainActor
final class ChromiumDownload: PageDownload {
    let downloadID = UUID()
    // Provenance only: the native item's original URL, for the list's source,
    // Where From and quarantine. Its method/body stay native; Try Again
    // resumes that same item (download.resume), never a replayed request.
    let originalRequest: URLRequest?
    // True only for a download Yab itself started from a row of its own
    // (a page menu's Download Linked File or Download Image), never a page's.
    let isUserInitiated: Bool
    let isExtensionDownload: Bool
    private let profile: String
    private let nativeID: Int?
    let publishesNativePath: Bool
    private var completedNativePath: String?
    let progress = Progress(totalUnitCount: -1)
    weak var page: (any PageHandle)?
    var sourceView: NSView? { page }
    let pageURL: URL?
    let pageTitle: String?
    weak var downloadEvents: (any PageDownloadEvents)?
    let remoteID: String
    let tabID: String
    private var ended = false
    private var resumable = false
    /// Marks a failure Chromium can resume in place (Hoard keeps it as resume data).
    static let resumeMark = Data("chromium-native-resume".utf8)
    /// Downloads Yab asked a page for, by page and address, for a few seconds.
    private static var asked: [String: TimeInterval] = [:]

    init(page: ChromiumPage, id: String, tab: String, source: URL? = nil, userInitiated: Bool = false,
         nativeID: Int? = nil, extensionDownload: Bool = false, publishesNativePath: Bool = false) {
        self.page = page; remoteID = id; tabID = tab
        originalRequest = source.map { URLRequest(url: $0) }
        isUserInitiated = userInitiated
        isExtensionDownload = extensionDownload
        profile = page.profile
        self.nativeID = nativeID
        self.publishesNativePath = publishesNativePath
        pageURL = page.committedURL; pageTitle = page.title
        progress.kind = .file
        progress.fileOperationKind = .downloading
    }
    static func byteCount(_ value: JSONValue?, unknown: Int64) -> Int64 {
        guard let number = value?.number, number.isFinite, number >= 0,
              number < Double(Int64.max) else { return unknown }
        return Int64(number)
    }
    static func nativeIdentifier(_ value: JSONValue?) -> Int? {
        guard let number = value?.number, number.isFinite, number >= 1,
              number <= Double(UInt32.max), number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
    private func send(_ method: String, _ fields: [String: JSONValue] = [:]) async throws {
        let core = try await ChromiumProcess.shared.connection()
        var p = fields; p["tab"] = .string(tabID); p["download"] = .string(remoteID)
        _ = try await core.request(method, params: p)
    }
    func destination(_ url: URL?) {
        guard !ended else { return }
        progress.fileURL = url
        Task { @MainActor in
            do { try await send("download.destination", ["path": .string(url?.path ?? "")]) }
            catch { fail(error) }
        }
    }
    static func ask(_ url: URL, on page: ChromiumPage) {
        let now = ProcessInfo.processInfo.systemUptime
        asked = asked.filter { now - $0.value < 10 }
        asked["\(ObjectIdentifier(page))|\(url.absoluteString)"] = now
    }
    /// How long after a press a file that starts is that press's. Long enough for a link's redirects.
    static let pressReach: TimeInterval = 10

    /// Save Video Frame As pressed: the next blob or data file of this page is that press's.
    static func askFrame(on page: ChromiumPage) {
        let now = ProcessInfo.processInfo.systemUptime
        asked = asked.filter { now - $0.value < 10 }
        asked["\(ObjectIdentifier(page))|frame"] = now
    }

    static func wasAsked(_ urls: [URL], on page: ChromiumPage) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if urls.contains(where: { ["blob", "data"].contains($0.scheme?.lowercased() ?? "") }),
           let at = asked.removeValue(forKey: "\(ObjectIdentifier(page))|frame"), now - at < pressReach { return true }
        for url in urls {
            let key = "\(ObjectIdentifier(page))|\(url.absoluteString)"
            if let at = asked.removeValue(forKey: key), now - at < 10 { return true }
        }
        return false
    }
    func receive(_ p: [String: JSONValue]) {
        guard !ended else { return }
        progress.totalUnitCount = Self.byteCount(p["total"], unknown: -1)
        progress.completedUnitCount = Self.byteCount(p["received"], unknown: 0)
        if p["complete"] == .bool(true) {
            ended = true
            if let path = p["path"]?.string, !path.isEmpty {
                completedNativePath = path
                progress.fileURL = URL(fileURLWithPath: path)
            }
            downloadEvents?.downloadDidFinish(self)
        } else if p["canceled"] == .bool(true) {
            fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        } else if p["interrupted"] == .bool(true) {
            resumable = p["resumable"] == .bool(true)
            fail(NSError(domain: "ChromiumDownload", code: Int(p["reason"]?.number ?? 0),
                         userInfo: [NSLocalizedDescriptionKey: "The download was interrupted"]))
        }
    }
    func didPublish(to file: URL) async throws {
        // OnDownloadUpdated already confirmed the transfer; Browser has now
        // atomically published its bytes. Older SDKs have no journal relocation
        // API. Their completed file must not become a failed download because
        // of an unsupported metadata operation. Advertised APIs still must ack.
        guard publishesNativePath else { return }
        guard let nativeID, let previous = completedNativePath else {
            throw NSError(domain: "ChromiumDownload", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The native download has no publication identity"])
        }
        let core = try await ChromiumProcess.shared.connection()
        _ = try await core.request("download.published", params: ["profile": .string(profile),
            "nativeId": .number(Double(nativeID)), "previousPath": .string(previous), "path": .string(file.path)])
        completedNativePath = file.path
    }
    func fail(_ error: Error) {
        guard !ended else { return }
        ended = true
        downloadEvents?.download(self, didFailWithError: error, resumeData: resumable ? Self.resumeMark : nil)
    }
    func cancelDownload(_ done: @escaping @MainActor (Data?) -> Void) {
        guard !ended else { done(nil); return }
        Task { @MainActor in
            try? await send("download.cancel")
            fail(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            done(nil)
        }
    }
    func restartDownload(from resumeData: Data?, fallback: (any PageHandle)?,
                         done: @escaping @MainActor ((any PageDownload)?) -> Void) {
        // Only Chromium's own resumable item goes on, in its partial file.
        // Starting over would replay a request whose method/body is native.
        guard resumeData == Self.resumeMark, resumable, let page = page as? ChromiumPage else { done(nil); return }
        resumable = false
        let next = ChromiumDownload(page: page, id: remoteID, tab: tabID, source: originalRequest?.url,
                                    userInitiated: isUserInitiated, nativeID: nativeID, extensionDownload: isExtensionDownload, publishesNativePath: publishesNativePath)
        next.progress.totalUnitCount = progress.totalUnitCount
        next.progress.completedUnitCount = progress.completedUnitCount
        next.progress.fileURL = progress.fileURL
        Task { @MainActor in
            do {
                ChromiumProcess.shared.keepDownload(next)
                try await send("download.resume")
                done(next)
            } catch { done(nil) }
        }
    }
}

extension ChromiumPage {
    /// Opened only to fetch a file: nothing to go back or forward to, and no
    /// document but the blank one or the file's own address.
    func onlyFetched(_ fetching: [URL?]) -> Bool {
        guard !canGoBack, !canGoForward else { return false }
        guard let shown = committedURL, shown.scheme != "about" else { return true }
        return fetching.contains { $0 == shown }
    }

    func receiveDownload(_ p: [String: JSONValue]) {
        guard let id = p["download"]?.string, let tabID = remoteID,
              let url = p["url"]?.string.flatMap(URL.init(string:)) else { return }
        let original = p["originalURL"]?.string.flatMap(URL.init(string:))
        // A person's click is what makes a file theirs, as WKDownload says of
        // it. Chromium knows: the request carries the page's user activation.
        let clicked = p["provenance"]?.string == "native" && p["userGesture"] == .bool(true)
        let download = ChromiumDownload(page: self, id: id, tab: tabID, source: original ?? url,
                                        userInitiated: clicked || ChromiumDownload.wasAsked([url, original].compactMap { $0 }, on: self),
                                        nativeID: ChromiumDownload.nativeIdentifier(p["nativeId"]),
                                        extensionDownload: p["initiator"]?.string.flatMap(URL.init(string:))?.scheme == "chrome-extension",
                                        publishesNativePath: p["publication"] == .bool(true))
        ChromiumProcess.shared.keepDownload(download)
        SiteDownloads.became(download, in: self, url: committedURL)
        guard let events else { download.destination(nil); return }
        // No document of its own yet: a tab or a window opened only to fetch this,
        // which steps aside and goes as WebKit's does.
        events.page(self, became: download, isMainFrame: committedURL == nil || committedURL?.scheme == "about")
        let response = URLResponse(url: url, mimeType: p["mime"]?.string,
                                   expectedContentLength: Int(ChromiumDownload.byteCount(p["total"], unknown: -1)), textEncodingName: nil)
        guard let listener = download.downloadEvents else { download.destination(nil); return }
        listener.download(download, decideDestinationUsing: response, suggestedFilename: p["name"]?.string ?? "download") {
            download.destination($0)
        }
    }
}
