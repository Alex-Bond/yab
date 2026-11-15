import AppKit
import AVFoundation
import UniformTypeIdentifiers
import WebKit

// Download Video from a video's right-click menu, done by Yab (#1057).
//
// WebKit's row never reaches this app's download delegate, the way its
// Download Image doesn't (ImageMenu.swift): the pick did nothing and Files
// stayed empty. And most videos on big sites aren't one file anyway: x.com,
// YouTube and the rest play through Media Source Extensions, a blob: address
// the page fills from an HLS playlist piece by piece, with nothing to save
// behind it. So the row is Yab's:
//
// - a plain address (the video's src or a <source>): an ordinary download,
//   in the downloads list and Files as any other;
// - HLS, the address itself or a playlist the page fetched for a blob:
//   video: the best variant's pieces fetched with the page's cookies, put
//   together into one .mp4 (its sound, when that is a playlist of its own
//   as on x.com, put in with it), and written to the downloads folder;
// - a blob: that is a whole file: read by the page and written out;
// - anything else (DASH, encrypted HLS, a live stream with no end): the
//   corner says this video can't be saved, rather than nothing at all.
//
// Which playlist: the page's contextmenu event says what the video has, and
// the playlists its frame fetched (ImageRelay.watch keeps them as they load),
// ranked by what they share with the video's poster and the piece it was
// last given (on x.com all three carry the tweet's video id).

/// The video or sound a right-click landed on, as its page tells it.
struct PointedMedia: Equatable {
    var src: String
    var sources: [String] = []
    var poster: String = ""
    /// HLS playlists (and DASH manifests) the frame fetched, oldest first.
    var playlists: [String] = []
    /// The last piece of media the frame fetched by script.
    var segment: String = ""
    var audio = false

    init(src: String, sources: [String] = [], poster: String = "", playlists: [String] = [],
         segment: String = "", audio: Bool = false) {
        self.src = src
        self.sources = sources
        self.poster = poster
        self.playlists = playlists
        self.segment = segment
        self.audio = audio
    }

    init?(_ body: [String: Any]) {
        guard let src = body["src"] as? String else { return nil }
        self.src = src
        sources = body["sources"] as? [String] ?? []
        poster = body["poster"] as? String ?? ""
        playlists = body["playlists"] as? [String] ?? []
        segment = body["segment"] as? String ?? ""
        audio = body["audio"] as? Bool == true
    }
}

enum VideoSave {
    /// What saving it takes.
    enum Route: Equatable {
        /// A file at an address: WebKit downloads it.
        case download(URL)
        /// HLS playlists to try, best guess first.
        case hls([URL])
        /// A blob: that may be a whole file, then these playlists.
        case blob(URL, [URL])
        /// Nothing that can be saved.
        case none
    }

    static func isPlaylist(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".m3u8")
    }

    /// An address that is a video or a sound file, or an HLS playlist.
    static func isMediaFile(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if isPlaylist(url) { return true }
        return UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }

    static func audioDocument(_ address: URL?, standalone: Bool) -> PointedMedia? {
        guard standalone, let address, isMediaFile(address),
              UTType(filenameExtension: address.pathExtension)?.conforms(to: .audio) == true else { return nil }
        return PointedMedia(src: address.absoluteString, audio: true)
    }

    private static func web(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func route(_ media: PointedMedia) -> Route {
        let addresses = ([media.src] + media.sources).compactMap(web)
        if let file = addresses.first(where: { !isPlaylist($0) }) { return .download(file) }
        let ranked = rank(media)
        if let list = addresses.first(where: isPlaylist) {
            return .hls([list] + ranked.filter { $0 != list })
        }
        if let blob = URL(string: media.src), blob.scheme?.lowercased() == "blob" {
            return .blob(blob, ranked)
        }
        return ranked.isEmpty ? .none : .hls(ranked)
    }

    /// The HLS playlists heard, those sharing most with the video's poster
    /// and its latest piece first, then the newest.
    static func rank(_ media: PointedMedia) -> [URL] {
        let hints = tokens(media.poster).union(tokens(media.segment))
        var seen = Set<URL>()
        var unique: [URL] = []
        for url in media.playlists.reversed().compactMap(web) where isPlaylist(url) && seen.insert(url).inserted {
            unique.append(url)
        }
        let scored: [(index: Int, url: URL, score: Int)] = unique.enumerated().map { pair in
            (pair.offset, pair.element, tokens(pair.element.absoluteString).intersection(hints).count)
        }
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.map(\.url)
    }

    /// The long parts of an address's path: ids, not "pl" or "avc1".
    static func tokens(_ address: String) -> Set<String> {
        guard let url = URL(string: address) else { return [] }
        let parts = url.path.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
        return Set(parts.map(String.init).filter { $0.count >= 8 })
    }

    // MARK: - HLS

    struct Variant: Equatable {
        var url: URL
        var bandwidth: Int
        var audio: String?
    }

    struct Rendition: Equatable {
        var url: URL
        var group: String
        var preferred: Bool
    }

    struct Track: Equatable {
        var map: URL?
        var segments: [URL]
        /// Something this can't put together: a key, byte ranges, no end.
        var unsupported: String?
        /// MPEG-TS pieces rather than fragmented MP4.
        var transport: Bool {
            map == nil && segments.contains { $0.path.lowercased().hasSuffix(".ts") }
        }
    }

    enum Playlist: Equatable {
        case master([Variant], [Rendition])
        case media(Track)
        case none
    }

    /// `KEY=value,KEY="a, quoted value"`.
    static func attributes(_ text: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[name] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in text {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return out
    }

    static func parse(_ text: String, base: URL) -> Playlist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else { return .none }
        let resolve = { (path: String) in URL(string: path, relativeTo: base)?.absoluteURL }
        var variants: [Variant] = []
        var renditions: [Rendition] = []
        var pending: [String: String]?
        var track = Track(map: nil, segments: [])
        var piece = false, ended = false, vod = false
        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                if a["TYPE"] == "AUDIO", let uri = a["URI"], let url = resolve(uri) {
                    renditions.append(Rendition(url: url, group: a["GROUP-ID"] ?? "",
                                                preferred: a["DEFAULT"] == "YES"))
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let a = attributes(line.dropFirst("#EXT-X-MAP:".count))
                if a["BYTERANGE"] != nil { track.unsupported = "byte ranges" }
                track.map = a["URI"].flatMap(resolve)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attributes(line.dropFirst("#EXT-X-KEY:".count))["METHOD"] ?? "NONE"
                if method != "NONE" { track.unsupported = "encrypted" }
            } else if line.hasPrefix("#EXT-X-BYTERANGE") {
                track.unsupported = "byte ranges"
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                ended = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                vod = line.hasSuffix("VOD")
            } else if line.hasPrefix("#EXTINF") {
                piece = true
            } else if !line.hasPrefix("#") {
                if let a = pending {
                    if let url = resolve(line) {
                        variants.append(Variant(url: url, bandwidth: Int(a["BANDWIDTH"] ?? "") ?? 0, audio: a["AUDIO"]))
                    }
                    pending = nil
                } else if piece, let url = resolve(line) {
                    track.segments.append(url)
                    piece = false
                }
            }
        }
        if !variants.isEmpty { return .master(variants, renditions) }
        guard !track.segments.isEmpty else { return .none }
        if !ended && !vod && track.unsupported == nil { track.unsupported = "live" }
        return .media(track)
    }

    /// The best variant, and its sound when that is a playlist of its own.
    static func choose(_ variants: [Variant], _ renditions: [Rendition]) -> (video: URL, audio: URL?)? {
        guard let best = variants.max(by: { $0.bandwidth < $1.bandwidth }) else { return nil }
        let group = renditions.filter { $0.group == best.audio }
        let sound = group.first(where: \.preferred) ?? group.first
        return (best.url, sound?.url)
    }

    // MARK: - fetching

    /// Why a video wasn't saved, for the corner.
    struct Refusal: Error { let words: String }

    static let cannot = Refusal(words: "This video can\u{2019}t be saved")

    /// What a request needs to be the page's own: its cookies, its address
    /// as the referrer, Yab's user agent.
    typealias Context = (cookies: [HTTPCookie], page: URL?, agent: String)

    @MainActor static func headers(for tab: Tab) async -> Context {
        let cookies = await tab.webKitOnly("WebKit video-save cookie context", build: false)?.configuration.websiteDataStore.httpCookieStore.allCookies() ?? []
        return (cookies, tab.address, AgentRead.userAgent)
    }

    static func request(_ url: URL, _ context: Context) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        for (field, value) in HTTPCookie.requestHeaderFields(with: context.cookies.filter { AgentRead.sent($0, to: url) }) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue(context.agent, forHTTPHeaderField: "User-Agent")
        if let page = context.page?.absoluteString { request.setValue(page, forHTTPHeaderField: "Referer") }
        return request
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }

    static func fetch(_ url: URL, _ context: Context, in session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request(url, context))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Refusal(words: "HTTP \(http.statusCode)")
        }
        return data
    }

    static func playlist(_ url: URL, _ context: Context, in session: URLSession) async -> Playlist {
        guard let data = try? await fetch(url, context, in: session), let text = String(data: data, encoding: .utf8) else { return .none }
        return parse(text, base: url)
    }

    /// One track's pieces, in order, into one file: six at a time.
    static func write(_ track: Track, to file: URL, _ context: Context, in session: URLSession) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw cannot }
        defer { try? handle.close() }
        let pieces = (track.map.map { [$0] } ?? []) + track.segments
        var index = 0
        while index < pieces.count {
            let batch = Array(pieces[index..<min(index + 6, pieces.count)])
            let got = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for (n, url) in batch.enumerated() {
                    group.addTask { (n, try await fetch(url, context, in: session)) }
                }
                var out = [Data](repeating: Data(), count: batch.count)
                for try await (n, data) in group { out[n] = data }
                return out
            }
            for data in got { try handle.write(contentsOf: data) }
            index += batch.count
        }
    }

    /// The video and its sound in one .mp4, as they are (no re-encoding).
    static func mux(video: URL, audio: URL?, to out: URL) async -> Bool {
        let composition = AVMutableComposition()
        let picture = AVURLAsset(url: video)
        guard let tracks = try? await picture.load(.tracks), !tracks.isEmpty else { return false }
        var length = CMTime.zero
        for source in tracks where source.mediaType == .video || (audio == nil && source.mediaType == .audio) {
            guard let range = try? await source.load(.timeRange),
                  let into = composition.addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid),
                  (try? into.insertTimeRange(range, of: source, at: .zero)) != nil else { return false }
            if source.mediaType == .video {
                into.preferredTransform = (try? await source.load(.preferredTransform)) ?? .identity
                length = max(length, range.duration)
            }
        }
        if let audio {
            let sound = AVURLAsset(url: audio)
            guard let source = try? await sound.loadTracks(withMediaType: .audio).first,
                  var range = try? await source.load(.timeRange),
                  let into = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return false }
            if length > .zero, range.duration > length { range.duration = length }
            guard (try? into.insertTimeRange(range, of: source, at: .zero)) != nil else { return false }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { return false }
        try? FileManager.default.removeItem(at: out)
        return (try? await session.export(to: out, as: .mp4)) != nil
    }

    /// An HLS video put together in `folder`: the file, or why not.
    static func assemble(_ lists: [URL], in folder: URL, _ context: Context) async throws -> URL {
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        // A master playlist among them first: the pieces' own playlists
        // share the video's id with it, and the newest heard is often the
        // sound's alone (x.com fetches master, picture, then sound).
        var video: Track?, sound: Track?, pieces: [Track] = [], refusal: Refusal?
        func refuse(_ why: String) {
            refusal = Refusal(words: why == "live" ? "A live video can\u{2019}t be saved" : cannot.words)
        }
        for list in lists.prefix(6) {
            switch await playlist(list, context, in: session) {
            case .master(let variants, let renditions):
                guard let (v, a) = choose(variants, renditions),
                      case .media(let picture) = await playlist(v, context, in: session) else { continue }
                var heard: Track?
                if let a, case .media(let track) = await playlist(a, context, in: session) { heard = track }
                if let why = picture.unsupported ?? heard?.unsupported { refuse(why); continue }
                video = picture
                sound = heard
            case .media(let track):
                if let why = track.unsupported { refuse(why) } else { pieces.append(track) }
                continue
            case .none:
                continue
            }
            break
        }
        if video == nil { video = pieces.first }
        guard let video else { throw refusal ?? cannot }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = folder.appendingPathComponent(video.transport ? "video.ts" : "video.mp4")
        try await write(video, to: picture, context, in: session)
        // Pieces of a transport stream are one file put end to end; the
        // Mac's player doesn't open it, but it is the video as sent.
        if video.transport { return picture }
        var heard: URL?
        if let sound, !sound.transport {
            let file = folder.appendingPathComponent("audio.mp4")
            if (try? await write(sound, to: file, context, in: session)) != nil { heard = file }
        }
        let out = folder.appendingPathComponent("out.mp4")
        if await mux(video: picture, audio: heard, to: out) { return out }
        // Fragmented MP4 is a video as it is.
        return picture
    }

    /// A blob: read by its page, when it is a whole file rather than a
    /// MediaSource: at most `limit` bytes.
    @MainActor static func blob(_ url: URL, in tab: Tab, limit: Int = 512 << 20) async -> Data? {
        guard let web = tab.webKitOnly("WebKit video-save cookie context", build: false) else { return nil }
        let read = """
        try {
          const r = await fetch(src);
          const b = await r.blob();
          if (!b.size || b.size > limit) return '';
          const bytes = new Uint8Array(await b.arrayBuffer());
          let s = '';
          for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          return btoa(s);
        } catch (e) { return ''; }
        """
        let found = try? await web.callAsyncJavaScript(read, arguments: ["src": url.absoluteString, "limit": limit],
                                                       in: nil, contentWorld: .defaultClient)
        return (found as? String).flatMap { $0.isEmpty ? nil : Data(base64Encoded: $0) }
    }

    /// The file's name: the page's title, else "yab-<site>-video".
    static func name(title: String, host: String, ext: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"[/:\\\x{00}-\x{1f}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "yab-\(host.isEmpty ? "page" : host)-video" : String(cleaned.prefix(80))
        return base + "." + ext
    }
}

extension Browser {
    /// Download Video (or Audio) picked: see VideoSave.
    func saveMedia(_ media: PointedMedia, from tab: Tab) {
        guard tab.webKitOnly("Video save authenticated source context", build: false) != nil else { return }
        let route = VideoSave.route(media)
        let destination = downloadFolder(for: tab)
        DebugLog.note("media.save", ["route": String(describing: route).prefix(200).description])
        switch route {
        case .download(let url):
            guard let web = tab.webKitOnly("WebKit video-save cookie context", build: false) else { return }
            web.startDownload(using: DownloadRequest.resource(url, from: tab.address)) { [weak self] download in
                self?.downloadFolders[ObjectIdentifier(download)] = destination
                self?.keep(download)
            }
        case .none:
            announce(VideoSave.cannot.words, mark: "exclamationmark.triangle")
        case .hls(let lists):
            assembleVideo(lists, from: tab, media: media, destination: destination)
        case .blob(let url, let lists):
            Task {
                if let data = await VideoSave.blob(url, in: tab) {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-video/" + UUID().uuidString)
                    let file = folder.appendingPathComponent(media.audio ? "audio.m4a" : "video.mp4")
                    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                          (try? data.write(to: file)) != nil else { return announce(VideoSave.cannot.words, mark: "exclamationmark.triangle") }
                    keepVideo(file, from: tab, source: nil, destination: destination)
                } else if lists.isEmpty {
                    announce(VideoSave.cannot.words, mark: "exclamationmark.triangle")
                } else {
                    assembleVideo(lists, from: tab, media: media, destination: destination)
                }
            }
        }
    }

    private func assembleVideo(_ lists: [URL], from tab: Tab, media: PointedMedia, destination: URL) {
        guard tab.webKitOnly("Video save authenticated source context", build: false) != nil else { return }
        announce(media.audio ? "Saving audio\u{2026}" : "Saving video\u{2026}", mark: "arrow.down.circle")
        Task {
            let context = await VideoSave.headers(for: tab)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-video/" + UUID().uuidString)
            do {
                let file = try await VideoSave.assemble(lists, in: folder, context)
                keepVideo(file, from: tab, source: lists.first, destination: destination)
            } catch {
                DebugLog.note("media.save", ["failed": "\(error)"])
                // A refusal's own words, never a server's status.
                let words = (error as? VideoSave.Refusal).flatMap { $0.words.hasPrefix("HTTP") ? nil : $0.words }
                announce(words ?? VideoSave.cannot.words, mark: "exclamationmark.triangle")
            }
        }
    }

    /// The finished file into the downloads folder and Files, as a JSON
    /// page's ⌘S is.
    private func keepVideo(_ file: URL, from tab: Tab, source: URL?, destination: URL) {
        let page = tab.address
        let title = tab.title
        let name = VideoSave.name(title: title, host: page?.host() ?? "", ext: file.pathExtension)
        DownloadFolder.check(destination) { [self] open in
            if !open { downloadFolderClosed(destination) }
            let token = UUID()
            let requested = DownloadDestinations.reserve(name, in: open ? destination : DownloadFolder.own, for: token)
            Task {
                defer { DownloadDestinations.release(token) }
                let target: URL
                do {
                    target = try await Task.detached(priority: .utility) {
                        try FileManager.default.createDirectory(at: requested.deletingLastPathComponent(), withIntermediateDirectories: true)
                        return try DownloadFile(destination: requested, ownedStaging: file).publish()
                    }.value
                } catch {
                    let fallback = DownloadDestinations.reserve(name, in: DownloadFolder.own, for: token)
                    do {
                        target = try await Task.detached(priority: .utility) {
                            try FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)
                            return try DownloadFile(destination: fallback, ownedStaging: file).publish()
                        }.value
                    } catch {
                        DownloadFile(destination: fallback, ownedStaging: file).discard()
                        announce("Couldn\u{2019}t save \(name)", mark: "exclamationmark.triangle")
                        return
                    }
                }
                Browser.writeWhereFrom(target, [source, page].compactMap { $0 })
                SiteDownloads.quarantine(target, from: source, page: page)
                loot.add(Keep(name: target.lastPathComponent, from: (source ?? page)?.host() ?? "", path: target.path, date: Date(),
                              page: page, pageTitle: title.isEmpty ? nil : title, source: source))
                hoard.lifting()
                hoard.touched(target.lastPathComponent)
                // Said in words only where no downloads button stands to take it.
                announce(bandDoors ? "Video saved" : "Saved to Downloads as \(target.lastPathComponent)", mark: "arrow.down.circle",
                         feedback: .success)
            }
        }
    }
}
