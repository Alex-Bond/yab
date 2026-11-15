import AppKit
import CryptoKit
import UniformTypeIdentifiers
import WebKit

// A page an agent published with Claude Code's Artifact tool, kept by Yab
// (docs/artifact-cards.md, feedback #151). The tool writes it into the
// session's scratchpad under /private/tmp, which a restart wipes, and its
// claude.ai address opens only for the Claude Code account, behind a
// sign-in. So at publish Yab copies the file (and the files beside it the
// tool sent) into its own folder, per chat, gone with the chat, and shows
// that copy from a scheme of its own, yab-artifact://<key>/<file>, in web
// views of their own: one store in memory for all of them, no cookies,
// only the CDNs the visualize tool allows (ChatWidgetPage), nothing on the
// local network. It works after a restart, and offline but for those CDNs.
//
// The chat's card (ArtifactCard) shows a still of each version, taken off
// screen once and kept as a picture beside the copy; never a live page per
// card. Published again, the copy is replaced, the new version's still
// taken, and every open view of it (a Peek, a half, a tab) reloads in place.

/// One published artifact as its step keeps it (ChatPublished).
struct ArtifactRef: Equatable, Hashable {
    /// Its claude.ai address.
    let url: String
    let title: String
    let icon: String?
    /// The file the tool published, where it wrote it.
    let path: String?
    let id: String?
    /// Its version: 1, 2 once published again.
    let seq: Int
    /// Files beside it the tool sent too, relative to its folder.
    let files: [String]
    /// The step's id, for the bench.
    let item: String

    init?(_ item: ChatItem) {
        guard item.kind == .tool, item.name == "Artifact", item.state == .done,
              let extra = item.extra, let url = extra["artifact"], !url.isEmpty else { return nil }
        self.url = url
        let named = extra["title"].flatMap { $0.isEmpty ? nil : $0 }
        let path = extra["artifactPath"].flatMap { $0.isEmpty ? nil : $0 }
        self.title = named ?? path.map { ArtifactRef.titled(URL(fileURLWithPath: $0)) } ?? "Page"
        icon = extra["icon"]
        self.path = path
        id = extra["artifactID"]
        seq = max(1, Int(extra["artifactSeq"] ?? "") ?? 1)
        files = (extra["artifactFiles"] ?? "").split(separator: "\n").map(String.init)
        self.item = item.id
    }

    /// The artifact itself, whatever its version: what its copy is kept
    /// under and its pages are served at, a host's letters (lower case:
    /// WebKit lowers a host).
    var key: String { ArtifactRef.key(id: id, url: url) }

    static func key(id: String?, url: String) -> String {
        let digest = SHA256.hash(data: Data((id.flatMap { $0.isEmpty ? nil : $0 } ?? url).utf8))
        return "a" + digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// A page Yab draws itself, from its copy; anything else (a claude.ai
    /// canvas, a JSX file) opens on claude.ai.
    var local: Bool { path.map(ArtifactRef.drawable) ?? false }

    static func drawable(_ path: String) -> Bool {
        ["html", "htm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// A page with no title given: its file's name, as words.
    static func titled(_ file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        let base = name.lowercased() == "index" ? file.deletingLastPathComponent().lastPathComponent : name
        let words = base.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return words.isEmpty ? "Page" : words.prefix(1).uppercased() + words.dropFirst()
    }

    /// A turn's cards: one for each artifact it published, at the last
    /// version it published there, in the order they first came.
    static func cards(in turn: [ChatItem]) -> [ArtifactRef] {
        var out: [ArtifactRef] = []
        for item in turn {
            guard let ref = ArtifactRef(item) else { continue }
            if let at = out.firstIndex(where: { $0.key == ref.key }) {
                if ref.seq >= out[at].seq { out[at] = ref }
            } else {
                out.append(ref)
            }
        }
        return out
    }
}

/// What Yab keeps of one artifact: its copy, its stills, what was opened.
struct ArtifactKept: Codable, Equatable {
    var url: String
    var title: String
    var icon: String?
    /// The latest version copied.
    var seq: Int
    /// The page's own file in the copy, the one its address names.
    var entry: String
    /// Where it was copied from.
    var source: String
    /// Stills taken, by version, and how long each took.
    var stills: [Int] = []
    var stillMs: [String: Int]?
    /// The latest version someone opened: the card's line stays in ink
    /// until this catches up.
    var opened: Int = 0
}

@MainActor
@Observable
final class ArtifactPages {
    static let shared = ArtifactPages()
    nonisolated static let scheme = "yab-artifact"
    /// The cards in the chat, or not (YAB_ARTIFACT_CARDS=0), to weigh what
    /// they cost (evals/artifact-card).
    static let on = ProcessInfo.processInfo.environment["YAB_ARTIFACT_CARDS"] != "0"

    /// Each artifact as last read or written, by key.
    @ObservationIgnored private var known: [String: ArtifactKept] = [:]
    /// Bumped as any copy or still changes: the cards draw again, nothing
    /// else does.
    private(set) var changes = 0
    @ObservationIgnored private var folders: [String: URL] = [:]
    @ObservationIgnored private var read: Set<String> = []
    /// Copies under way, by key, and the version each is copying.
    @ObservationIgnored private var copying: [String: Int] = [:]
    @ObservationIgnored private var waiters: [String: [() -> Void]] = [:]
    /// Stills being taken, by key, and the version each is of.
    @ObservationIgnored private var shooting: [String: Int] = [:]

    nonisolated static var root: URL { Store.file("artifacts") }

    nonisolated static func isPage(_ url: URL?) -> Bool { url?.scheme?.lowercased() == scheme }

    /// Where a chat's copy of an artifact lives.
    nonisolated static func folder(chat: String, key: String) -> URL {
        let safe = chat.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
        return root.appendingPathComponent(safe.isEmpty ? "chat" : safe, isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// What is kept of an artifact, read from its folder the first time a
    /// card asks (a small file, once).
    func state(_ ref: ArtifactRef, chat: String) -> ArtifactKept? {
        _ = changes
        if let found = known[ref.key] { return found }
        guard !read.contains(ref.key) else { return nil }
        read.insert(ref.key)
        let folder = Self.folder(chat: chat, key: ref.key)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let found = try? JSONDecoder().decode(ArtifactKept.self, from: data),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("page").appendingPathComponent(found.entry).path)
        else { return nil }
        folders[ref.key] = folder
        known[ref.key] = found
        return found
    }

    /// What is kept under a key, as the scheme serves it.
    func entry(_ key: String) -> ArtifactKept? {
        _ = changes
        return known[key]
    }

    /// A folder the scheme found for a key no card has asked after since
    /// Yab started (a tab of it brought back): known from now on.
    func adopt(_ key: String, at folder: URL) {
        guard known[key] == nil, let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let found = try? JSONDecoder().decode(ArtifactKept.self, from: data) else { return }
        folders[key] = folder
        known[key] = found
        read.insert(key)
    }

    private func set(_ key: String, _ state: ArtifactKept) {
        known[key] = state
        changes += 1
        write(key)
    }

    /// Yab's own address for it, while its copy is there.
    func address(_ ref: ArtifactRef, chat: String) -> URL? {
        guard ref.local, let state = state(ref, chat: chat), let folder = folders[ref.key],
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("page").appendingPathComponent(state.entry).path)
        else { return nil }
        return Self.address(key: ref.key, entry: state.entry)
    }

    nonisolated static func address(key: String, entry: String) -> URL? {
        let path = entry.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(scheme)://\(key)/\(path)")
    }

    /// The still of this very version, once taken; never another version's.
    func still(_ ref: ArtifactRef, chat: String) -> (file: URL, seq: Int)? {
        guard let state = state(ref, chat: chat), let folder = folders[ref.key], state.stills.contains(ref.seq) else { return nil }
        return (folder.appendingPathComponent("still-\(ref.seq).png"), ref.seq)
    }

    /// Whether a version's card can be shown as it is: nothing of its own
    /// still on its way (its copy being made, its still being taken).
    /// Until then the chat keeps the card of the version before it.
    func ready(_ ref: ArtifactRef) -> Bool {
        _ = changes
        guard ref.local else { return true }
        return (copying[ref.key] ?? shooting[ref.key]) != ref.seq
    }

    func stillMs(_ key: String, seq: Int) -> Int? { known[key]?.stillMs?[String(seq)] }

    /// A card's line in ink: a version nobody has opened yet.
    func fresh(_ ref: ArtifactRef, chat: String) -> Bool {
        guard let state = state(ref, chat: chat) else { return false }
        return ref.seq > 1 && ref.seq > state.opened
    }

    func opened(_ ref: ArtifactRef) {
        guard var state = known[ref.key], state.opened < state.seq else { return }
        state.opened = state.seq
        set(ref.key, state)
    }

    /// The copy kept of the folder it came from, for Share… and Show in Finder.
    func file(_ ref: ArtifactRef, chat: String) -> URL? {
        guard let state = state(ref, chat: chat), let folder = folders[ref.key] else { return nil }
        return folder.appendingPathComponent("page").appendingPathComponent(state.entry)
    }

    // MARK: - keeping a copy

    /// Published, or a card come into view: a copy of this version, if
    /// there isn't one and the file is still where the tool wrote it, then
    /// its still. `done` once there is a copy, or none can be made.
    func take(_ ref: ArtifactRef, chat: String, done: (() -> Void)? = nil) {
        guard ref.local, let source = ref.path else { done?(); return }
        let key = ref.key
        if let state = state(ref, chat: chat), state.seq >= ref.seq {
            if !state.stills.contains(ref.seq), state.seq == ref.seq { shoot(ref, chat: chat) }
            done?(); return
        }
        if let done { waiters[key, default: []].append(done) }
        if let underway = copying[key], underway >= ref.seq { return }
        copying[key] = ref.seq
        changes += 1
        let folder = Self.folder(chat: chat, key: key)
        let files = ref.files
        Task.detached(priority: .userInitiated) {
            let entry = Self.copy(source, files: files, into: folder)
            await MainActor.run { self.copied(ref, chat: chat, folder: folder, entry: entry) }
        }
    }

    private func copied(_ ref: ArtifactRef, chat: String, folder: URL, entry: String?) {
        let key = ref.key
        if copying[key] == ref.seq { copying[key] = nil }
        defer { waiters.removeValue(forKey: key)?.forEach { $0() } }
        guard let entry else { changes += 1; return }
        var state = known[key] ?? ArtifactKept(url: ref.url, title: ref.title, icon: ref.icon, seq: ref.seq, entry: entry, source: ref.path ?? "")
        state.url = ref.url
        state.title = ref.title
        state.icon = ref.icon
        state.seq = ref.seq
        state.entry = entry
        state.source = ref.path ?? ""
        folders[key] = folder
        read.insert(key)
        set(key, state)
        reload(key)
        shoot(ref, chat: chat)
    }

    /// The file and the files beside it, into the folder's page/, the old
    /// copy replaced whole once the new one is in: a reload never meets
    /// half of each. Its file's name, or nil when it can't be read.
    nonisolated static func copy(_ source: String, files: [String], into folder: URL) -> String? {
        let manager = FileManager.default
        let from = URL(fileURLWithPath: source)
        guard manager.isReadableFile(atPath: from.path) else { return nil }
        let fresh = folder.appendingPathComponent("page.new", isDirectory: true)
        try? manager.removeItem(at: fresh)
        guard (try? manager.createDirectory(at: fresh, withIntermediateDirectories: true)) != nil else { return nil }
        let entry = from.lastPathComponent
        guard (try? manager.copyItem(at: from, to: fresh.appendingPathComponent(entry))) != nil else { return nil }
        // The tool's other files, each inside the page's folder, 50 MB in all.
        let base = from.deletingLastPathComponent().standardizedFileURL
        var room: Int64 = 50_000_000
        for name in files where !name.isEmpty && name != entry {
            let file = base.appendingPathComponent(name).standardizedFileURL
            guard file.path.hasPrefix(base.path + "/"), !name.contains(".."),
                  let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int64, size <= room else { continue }
            room -= size
            let to = fresh.appendingPathComponent(name)
            try? manager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.copyItem(at: file, to: to)
        }
        let page = folder.appendingPathComponent("page", isDirectory: true)
        try? manager.removeItem(at: page)
        guard (try? manager.moveItem(at: fresh, to: page)) != nil else { return nil }
        return entry
    }

    private func write(_ key: String) {
        guard let state = known[key], let folder = folders[key], let data = try? JSONEncoder().encode(state) else { return }
        let file = folder.appendingPathComponent("meta.json")
        Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
    }

    /// A chat gone: its copies with it.
    nonisolated static func forget(chat: String) {
        let folder = folder(chat: chat, key: "x").deletingLastPathComponent()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - stills

    private func shoot(_ ref: ArtifactRef, chat: String) {
        let key = ref.key
        guard let state = known[key], let folder = folders[key], !state.stills.contains(state.seq), shooting[key] != state.seq,
              let url = Self.address(key: key, entry: state.entry) else { return }
        let seq = state.seq
        let file = folder.appendingPathComponent("still-\(seq).png")
        shooting[key] = seq
        changes += 1
        ArtifactStills.shared.take(url, to: file) { [weak self] ms in
            guard let self else { return }
            if self.shooting[key] == seq { self.shooting[key] = nil }
            guard let ms, var now = self.known[key] else { self.changes += 1; return }
            if !now.stills.contains(seq) { now.stills.append(seq) }
            now.stillMs = (now.stillMs ?? [:]).merging([String(seq): ms]) { $1 }
            self.set(key, now)
        }
    }

    // MARK: - its open views

    /// Every view showing an artifact's pages, as their requests come.
    @ObservationIgnored private var views: [String: NSHashTable<WKWebView>] = [:]

    func showing(_ key: String, in view: WKWebView) {
        let table = views[key] ?? NSHashTable<WKWebView>.weakObjects()
        table.add(view)
        views[key] = table
    }

    /// Published again: a Peek, a half or a tab on it shows the new
    /// version where it is, scrolled where it was.
    func reload(_ key: String) {
        for view in views[key]?.allObjects ?? [] where view.url?.scheme == Self.scheme && view.url?.host() == key && !(view is ArtifactStillView) {
            // Where it was scrolled, for the new version to come back to (`served`).
            view.evaluateJavaScript("try{sessionStorage.setItem('\(Self.scrollKey)',String(scrollY))}catch(e){}") { [weak view] _, _ in
                view?.reload()
            }
        }
    }

    func folder(for key: String) -> URL? { folders[key] }

    // MARK: - the web views

    /// One store in memory for every artifact's page: nothing kept, no
    /// cookies, so no page of an agent's is sent with your sign-ins.
    static let store: WKWebsiteDataStore = {
        let store = WKWebsiteDataStore.nonPersistent()
        store.httpCookieStore.setCookiePolicy(.disallow, completionHandler: nil)
        return store
    }()

    /// A configuration for one view of an artifact: a Peek, a half, a tab
    /// or a still. Made fresh for each, as a tab's is.
    static func configuration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.processPool = Web.pool
        config.websiteDataStore = store
        config.setURLSchemeHandler(ArtifactScheme.shared, forURLScheme: scheme)
        config.applicationNameForUserAgent = Web.userAgentName
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isElementFullscreenEnabled = true
        LocalNetwork.protect(config.userContentController)
        return config
    }

    /// What an artifact's page may load: its own files, and the visualize
    /// tool's CDNs (ChatWidgetPage), nothing else; no form sent anywhere.
    nonisolated static let policy: String = {
        let cdn = ChatWidgetPage.scripts
        let own = "'self' \(scheme):"
        return "default-src 'none'; script-src \(own) 'unsafe-inline' 'unsafe-eval' \(cdn); "
            + "style-src \(own) 'unsafe-inline' https://fonts.googleapis.com \(cdn); "
            + "font-src \(own) data: https://fonts.gstatic.com \(cdn); img-src \(own) data: blob: \(cdn); "
            + "media-src \(own) data: blob:; connect-src \(own) \(cdn); frame-src \(own); worker-src \(own) blob:; "
            + "form-action 'none'; base-uri 'self'"
    }()

    nonisolated static let scrollKey = "yab-artifact-scroll"
    /// A new version, loaded where the old one was being read: back to the
    /// place it was scrolled to (`reload`), once, as its content arrives.
    nonisolated static let scrollBack = """
    <script>(function(){try{var y=sessionStorage.getItem('\(scrollKey)');if(y===null)return;\
    sessionStorage.removeItem('\(scrollKey)');var go=function(){scrollTo(0,+y)};\
    document.addEventListener('DOMContentLoaded',go);addEventListener('load',go)}catch(e){}})();</script>
    """

    /// The page's own file as served: the policy first in its head, and
    /// its title where it has none, so its tab and Peek are named by it,
    /// never by a file path.
    nonisolated static func served(_ html: Data, title: String) -> Data {
        guard var text = String(data: html, encoding: .utf8) else { return html }
        let escaped = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        var head = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">" + scrollBack
        if text.range(of: "<title[\\s>]", options: [.regularExpression, .caseInsensitive]) == nil { head += "<title>\(escaped)</title>" }
        if let open = text.range(of: "<head(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            text.insert(contentsOf: head, at: open.upperBound)
        } else if let open = text.range(of: "<html(\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            text.insert(contentsOf: "<head>" + head + "</head>", at: open.upperBound)
        } else {
            text = "<head>" + head + "</head>" + text
        }
        return Data(text.utf8)
    }
}

/// Serves an artifact's copy: yab-artifact://<key>/<file>, from its folder's
/// page/, never above it; the page's policy as a header too.
final class ArtifactScheme: NSObject, WKURLSchemeHandler {
    static let shared = ArtifactScheme()
    /// Tasks WebKit stopped before their file was read: told nothing more.
    @MainActor private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url, let key = url.host()?.lowercased() else {
                task.didFailWithError(URLError(.badURL))
                return
            }
            let pages = ArtifactPages.shared
            guard let folder = pages.folder(for: key) ?? Self.find(key) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            pages.adopt(key, at: folder)
            pages.showing(key, in: webView)
            let state = pages.entry(key)
            let asked = url.path().removingPercentEncoding ?? url.path()
            let name = asked.split(separator: "/").joined(separator: "/")
            let entry = state?.entry ?? ""
            let title = state?.title ?? "Page"
            let id = ObjectIdentifier(task)
            stopped.remove(id)
            Task.detached(priority: .userInitiated) {
                let page = folder.appendingPathComponent("page", isDirectory: true).standardizedFileURL
                let file = (name.isEmpty ? page.appendingPathComponent(entry) : page.appendingPathComponent(name)).standardizedFileURL
                var body = file.path.hasPrefix(page.path + "/") ? try? Data(contentsOf: file) : nil
                let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                if let found = body, type == "text/html" { body = ArtifactPages.served(found, title: title) }
                await MainActor.run {
                    guard !self.stopped.contains(id) else { self.stopped.remove(id); return }
                    guard let body else {
                        task.didFailWithError(URLError(.fileDoesNotExist))
                        return
                    }
                    let headers = [
                        "Content-Type": type.hasPrefix("text/") ? type + "; charset=utf-8" : type,
                        "Content-Security-Policy": ArtifactPages.policy,
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                    ]
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                        ?? URLResponse(url: url, mimeType: type, expectedContentLength: body.count, textEncodingName: "utf-8")
                    task.didReceive(response)
                    task.didReceive(body)
                    task.didFinish()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        MainActor.assumeIsolated { _ = stopped.insert(ObjectIdentifier(task)) }
    }

    /// A key no card has asked after since Yab started (a tab brought
    /// back): its folder found among the chats'.
    @MainActor private static func find(_ key: String) -> URL? {
        let chats = (try? FileManager.default.contentsOfDirectory(at: ArtifactPages.root, includingPropertiesForKeys: nil)) ?? []
        return chats.map { $0.appendingPathComponent(key, isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("page").path) }
    }
}

/// A still's web view: off every screen, and seen there all the same, so
/// its page paints (PageView.seenOffscreen).
final class ArtifactStillView: WKWebView {
    private static let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")

    func seen() {
        guard responds(to: Self.occlusion) else { return }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method(for: Self.occlusion), to: Set.self)(self, Self.occlusion, false)
    }
}

/// The still of each version, one at a time: the page laid out off screen
/// at twice the card's width, pictured once it has drawn, the view gone.
@MainActor
final class ArtifactStills: NSObject, WKNavigationDelegate {
    static let shared = ArtifactStills()
    /// The page's width in the still, and as much of its top as a card can show.
    static let size = NSSize(width: 664, height: 400)
    private var queue: [(url: URL, file: URL, done: (Int?) -> Void)] = []
    private var busy: (view: ArtifactStillView, file: URL, done: (Int?) -> Void, began: Date)?
    private var room: NSWindow?
    private var finished = false

    func take(_ url: URL, to file: URL, done: @escaping (Int?) -> Void) {
        queue.append((url, file, done))
        next()
    }

    private func next() {
        guard busy == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let window = room ?? makeRoom()
        let view = ArtifactStillView(frame: NSRect(origin: .zero, size: Self.size), configuration: ArtifactPages.configuration())
        view.seen()
        view.navigationDelegate = self
        window.contentView?.addSubview(view)
        busy = (view, job.file, job.done, Date())
        finished = false
        view.load(URLRequest(url: job.url))
        // A page that never says it has finished is pictured as it stands.
        let shown = view
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.busy?.view === shown, !self.finished else { return }
                self.shoot()
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            guard busy?.view === webView, !finished else { return }
            finished = true
            // A moment for its fonts and first motion.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated { self?.shoot() }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if busy?.view === webView { end(nil) } }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { if busy?.view === webView { end(nil) } }
    }

    private func shoot() {
        guard let job = busy else { return }
        finished = true
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: Self.size)
        config.afterScreenUpdates = true
        // Twice the page's points, whatever the room's screen.
        let scale = max(1, job.view.window?.backingScaleFactor ?? 1)
        config.snapshotWidth = NSNumber(value: Double(Self.size.width * 2 / scale))
        job.view.takeSnapshot(with: config) { [weak self] image, _ in
            MainActor.assumeIsolated {
                guard let self, self.busy?.view === job.view else { return }
                guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return self.end(nil) }
                let file = job.file
                let ms = Int(Date().timeIntervalSince(job.began) * 1000)
                Task.detached(priority: .utility) {
                    let wrote = (try? png.write(to: file, options: .atomic)) != nil
                    await MainActor.run { self.end(wrote ? ms : nil) }
                }
            }
        }
    }

    private func end(_ ms: Int?) {
        guard let job = busy else { return }
        busy = nil
        job.view.navigationDelegate = nil
        job.view.stopLoading()
        job.view.removeFromSuperview()
        job.done(ms)
        next()
    }

    /// Off every screen, never key or main, below the windows: only so the
    /// page has a window to be laid out and drawn in (Bench's room).
    private func makeRoom() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -24000, y: -24000), size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        room = window
        return window
    }
}
