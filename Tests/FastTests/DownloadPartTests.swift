import Foundation
import Network
import Testing
import WebKit
@testable import Fast

// What a stopped download leaves on disk (row 1005): Stop, a cancel, a
// failure with nothing to go on from and quitting take the piece away; a
// pause, or a failure WebKit can resume, keeps it until the row goes.
// Real WKDownloads from a local server that sends slowly.
@MainActor
@Suite(.serialized)
struct DownloadPartTests {
    /// Serves `/slow` a few KB at a time, with validators so WebKit can
    /// keep resume data, and `/cut`, a body that stops halfway with none.
    final class SlowServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "download-part-server")
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private let html: String?
        private(set) var port: UInt16 = 0
        static let total = 8 << 20

        init(html: String? = nil) throws {
            self.html = html
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: 0)!)
            listener = try NWListener(using: parameters)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed: ready.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                lock.lock(); connections.append(connection); lock.unlock()
                connection.start(queue: queue)
                read(connection, Data())
            }
            listener.start(queue: queue)
            guard ready.wait(timeout: .now() + 10) == .success, let assigned = listener.port else {
                listener.cancel()
                throw URLError(.cannotConnectToHost)
            }
            port = assigned.rawValue
        }

        func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

        func stop() {
            listener.cancel()
            lock.lock(); connections.forEach { $0.cancel() }; connections.removeAll(); lock.unlock()
        }

        private func read(_ connection: NWConnection, _ so: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, finished, error in
                guard let self else { return }
                var data = so
                if let bytes { data.append(bytes) }
                guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                      let head = String(data: data[..<end.lowerBound], encoding: .utf8) else {
                    if !finished, error == nil { read(connection, data) } else { connection.cancel() }
                    return
                }
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                if path == "/", let html {
                    let body = Data(html.utf8)
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
                let cut = path.hasPrefix("/cut")
                let headers = cut
                    ? "Content-Type: application/octet-stream\r\nContent-Length: \(Self.total)\r\nCache-Control: no-store\r\nConnection: close\r\n"
                    : "Content-Type: application/octet-stream\r\nContent-Length: \(Self.total)\r\nAccept-Ranges: bytes\r\n"
                        + "ETag: \"part-1005\"\r\nLast-Modified: Sat, 24 Oct 2026 10:00:00 GMT\r\nConnection: close\r\n"
                let response = "HTTP/1.1 200 OK\r\n\(headers)Content-Disposition: attachment; filename=\"part.bin\"\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
                    guard error == nil else { return connection.cancel() }
                    self?.send(connection, sent: 0, cutAt: cut ? 256 << 10 : nil)
                })
            }
        }

        /// 32 KB every 20 ms: well under two megabytes a second, so a test
        /// has seconds before the eight are in.
        private func send(_ connection: NWConnection, sent: Int, cutAt: Int?) {
            if let cutAt, sent >= cutAt { return connection.forceCancel() }
            guard sent < Self.total else { return connection.cancel() }
            let chunk = Data(repeating: 0x5A, count: min(32 << 10, Self.total - sent))
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { return connection.cancel() }
                queue.asyncAfter(deadline: .now() + 0.02) { self.send(connection, sent: sent + chunk.count, cutAt: cutAt) }
            })
        }
    }

    /// Stands where WebKit's delegate is: names the file in a folder of the
    /// test's own, as Browser does, and passes the failure on to Browser.
    @MainActor
    final class Saver: NSObject, WKDownloadDelegate {
        let browser: Browser
        let folder: URL
        var file: URL?
        var failures: [Data?] = []
        var finished = false

        init(browser: Browser, folder: URL) {
            self.browser = browser
            self.folder = folder
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            let url = Browser.free(suggestedFilename.isEmpty ? "part.bin" : suggestedFilename, in: folder)
            file = url
            browser.downloadFiles[ObjectIdentifier(download)] = url
            completionHandler(url)
            browser.hoard.begin(download, name: url.lastPathComponent, from: "127.0.0.1")
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            failures.append(resumeData)
            browser.download(download, didFailWithError: error, resumeData: resumeData)
        }

        func downloadDidFinish(_ download: WKDownload) { finished = true }
    }

    @MainActor
    final class World {
        let server: SlowServer
        let browser: Browser
        let folder: URL
        let saver: Saver
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        var download: WKDownload?

        init() throws {
            server = try SlowServer()
            browser = Browser(windowID: UUID())
            browser.lay([])
            browser.activeID = nil
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-part-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            saver = Saver(browser: browser, folder: folder)
        }

        /// Started, named, and with bytes already on disk (or, `cut`, over).
        func start(_ path: String, cut: Bool = false) async throws -> WKDownload {
            let download: WKDownload = await withCheckedContinuation { done in
                web.startDownload(using: URLRequest(url: server.url(path))) { download in
                    MainActor.assumeIsolated {
                        download.delegate = self.saver
                        self.browser.downloading.append(download)
                        self.download = download
                    }
                    done.resume(returning: download)
                }
            }
            // A cold network process on a busy Mac took over 15 s once.
            try await until("bytes on disk", timeout: 45) {
                guard let file = self.saver.file else { return false }
                if cut { return true }
                return (self.size(file) ?? 0) > 0
            }
            return download
        }

        func size(_ file: URL) -> Int? {
            (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue
        }

        func exists(_ file: URL?) -> Bool { file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

        func fetch() throws -> Hoard.Fetch {
            try #require(browser.hoard.fetches.first)
        }

        func until(_ what: String, timeout: Double = 15, _ ok: () -> Bool) async throws {
            let end = Date().addingTimeInterval(timeout)
            while !ok() {
                guard Date() < end else {
                    let got = download.map { "\($0.progress.completedUnitCount)" } ?? "no download"
                    Issue.record("Timed out waiting for \(what): file \(saver.file?.path ?? "none"), size \(saver.file.flatMap(size) ?? -1), progress \(got), failures \(saver.failures.count), finished \(saver.finished)")
                    throw CancellationError()
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        func close() {
            download?.cancel { _ in }
            server.stop()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    @Test func stopRemovesThePiece() async throws {
        let world = try World()
        defer { world.close() }
        _ = try await world.start("/slow")
        let file = try #require(world.saver.file)
        let fetch = try await waitForRow(world)
        world.browser.hoard.cancel(fetch)
        try await world.until("the piece gone") { !world.exists(file) }
        #expect(!world.exists(file))
        #expect(world.browser.downloadFiles.isEmpty)
        #expect(world.browser.hoard.fetches.isEmpty)
        #expect(!world.saver.finished)
    }

    /// An extension's chrome.downloads.cancel of one under way: as Stop.
    @Test func extensionCancelRemovesThePiece() async throws {
        let world = try World()
        defer { world.close() }
        _ = try await world.start("/slow")
        let file = try #require(world.saver.file)
        let fetch = try await waitForRow(world)
        world.browser.hoard.stop(fetch.id)
        try await world.until("the piece gone") { !world.exists(file) }
        #expect(!world.exists(file))
    }

    @Test func pauseKeepsThePieceUntilTheRowGoes() async throws {
        let world = try World()
        defer { world.close() }
        let download = try await world.start("/slow")
        let file = try #require(world.saver.file)
        _ = try await waitForRow(world)
        let kept = await world.browser.hoard.pause(download)
        #expect(kept, "WebKit kept resume data for a server with validators")
        // Give a late delete, if there were one, the time to happen.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(world.exists(file) == kept)
        let paused = try world.fetch()
        #expect(paused.paused)
        // Paused, then let go: the row and its piece go.
        world.browser.hoard.stop(paused.id)
        #expect(!world.exists(file))
        #expect(world.browser.hoard.fetches.isEmpty)
    }

    @Test func failureKeepsThePieceOnlyWhenResumable() async throws {
        let world = try World()
        defer { world.close() }
        _ = try await world.start("/cut", cut: true)
        let file = try #require(world.saver.file)
        try await world.until("the failure") { !world.saver.failures.isEmpty }
        let resume = world.saver.failures.first ?? nil
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(world.exists(file) == (resume != nil))
        // The row stays, failed, to try again or to let go.
        let failed = try world.fetch()
        #expect(failed.failed)
        world.browser.hoard.dismiss(failed)
        #expect(!world.exists(file))
    }

    @Test func quittingRemovesWhatIsUnfinished() async throws {
        let world = try World()
        defer { world.close() }
        _ = try await world.start("/slow")
        let file = try #require(world.saver.file)
        world.browser.discardUnfinishedDownloads()
        #expect(!world.exists(file))
        #expect(world.browser.downloadFiles.isEmpty)
    }

    /// The row is put in a moment after the name is known.
    private func waitForRow(_ world: World) async throws -> Hoard.Fetch {
        try await world.until("the row") { !world.browser.hoard.fetches.isEmpty }
        return try world.fetch()
    }
}
