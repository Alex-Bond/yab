import AppKit
import Foundation
import Network
import Testing
import WebKit
@testable import Fast

/// Real HTTP on an owned loopback port, with one bounded unfinished body.
private final class LifetimeFetchSite: @unchecked Sendable {
    static let host = "127.0.0.1"
    static let body = Data(repeating: 0x5a, count: 65_536)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "extension-fetch-lifetime-http")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var stopped = false
    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/stream")! }
    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            self.connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: self.queue)
            self.receive(connection, Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 4) == .success, listener.port != nil else {
            listener.cancel(); throw URLError(.cannotConnectToHost)
        }
    }
    func stop() {
        queue.sync {
            stopped = true; listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
            for connection in connections.values { connection.cancel() }; connections = [:]
        }
    }
    private func receive(_ connection: NWConnection, _ previous: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.stopped else { connection.cancel(); return }
            var head = previous; if let data { head.append(data) }
            guard head.count <= 16_384, error == nil else { self.finish(connection); return }
            guard head.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { self.finish(connection) } else { self.receive(connection, head) }; return
            }
            let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
            guard lines.contains(where: { $0.lowercased().hasPrefix("cookie:") && $0.contains("lifetime=fixture") }) else {
                self.finish(connection); return
            }
            var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nX-Lifetime-Fixture: stream\r\nTransfer-Encoding: chunked\r\n\r\n10000\r\n".utf8)
            response.append(Self.body); response.append(Data("\r\n".utf8))
            // No terminating zero chunk or FIN: the client must cancel it.
            connection.send(content: response, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(connection) }
            })
            self.untilCancelled(connection)
        }
    }
    private func untilCancelled(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
            guard let self else { connection.cancel(); return }
            if complete || error != nil || self.stopped { self.finish(connection) }
            else { self.untilCancelled(connection) }
        }
    }
    private func finish(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = nil
        connection.cancel()
    }
}

@MainActor
@Suite(.serialized)
struct ExtensionFetchLifetimeTests {
    @MainActor
    private final class Fixture {
        let owner: Extensions
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fetch-lifetime-\(UUID())")
        let site: LifetimeFetchSite
        var url: URL { site.url }
        var installed: [(Extensions, String)] = []
        var tokens: [String] = []
        var cookie: HTTPCookie?
        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            owner = Extensions(signIn: nil)
            site = try LifetimeFetchSite()
        }
        func prepare() async throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            let cookie = try #require(HTTPCookie(properties: [.name: "lifetime", .value: "fixture",
                .domain: LifetimeFetchSite.host, .path: "/",
                .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue]))
            try #require(cookie.sameSitePolicy != nil)
            self.cookie = cookie
            await Store.websites.httpCookieStore.setCookie(cookie)
            let roundTrip = await Store.websites.httpCookieStore.allCookies().filter {
                $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() == LifetimeFetchSite.host && $0.name == "lifetime"
            }
            let metadata = roundTrip.map { ["name": $0.name, "sameSite": $0.sameSitePolicy?.rawValue ?? "", "secure": $0.isSecure] as [String: Any] }
            print("fetch lifetime loopback cookie metadata:", metadata)
            try #require(roundTrip.contains { $0.sameSitePolicy != nil && !$0.isSecure })
        }
        func admit(_ id: String = "fetch" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                   in other: Extensions? = nil) async throws -> String {
            let target = other ?? owner
            installed.append((target, id))
            let staged = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Fetch lifetime","version":"1.0","host_permissions":["http://127.0.0.1/*"]}"#
                .write(to: staged.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let loaded = try await target.admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id),
                confirm: false, quiet: true, synced: .init(enabled: true, pinned: false,
                                                         allowed: Extensions.grants(found, in: staged)))
            try #require(loaded)
            try #require(target.contexts[id]?.isLoaded == true)
            return id
        }
        func start(_ context: WKWebExtensionContext) async throws -> String {
            let reply = try #require(try await ExtensionFetch.run("sitefetch.start", [["url": url.absoluteString]], context: context) as? [String: Any])
            print("fetch lifetime loopback start reply:", reply)
            let id = try #require(reply["id"] as? String)
            tokens.append(id)
            try #require(reply["status"] as? Int == 200)
            let headers = try #require(reply["headers"] as? [[String]])
            try #require(headers.contains { $0.count == 2 && $0[0].lowercased() == "x-lifetime-fixture" && $0[1] == "stream" })
            // The header callback and body callback are separate delegate turns.
            try await Task.sleep(for: .milliseconds(100))
            return id
        }

        func read(_ token: String, using context: WKWebExtensionContext) async throws -> [String: Any] {
            try #require(try await ExtensionFetch.run("sitefetch.read", [token], context: context) as? [String: Any])
        }

        func cleanUp() async {
            if let context = installed.compactMap({ $0.0.contexts[$0.1] }).first {
                for token in tokens { _ = try? await ExtensionFetch.run("sitefetch.cancel", [token], context: context) }
            }
            for (target, id) in installed { target.setEnabled(id, false) }
            for (target, id) in installed { target.remove(id) }
            owner.shutDown()
            if let cookie { await Store.websites.httpCookieStore.deleteCookie(cookie) }
            try? FileManager.default.removeItem(at: root)
            site.stop()
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await fixture.prepare(); try await body(fixture) }
        catch { await fixture.cleanUp(); throw error }
        await fixture.cleanUp()
    }

    @Test func unloadReleasesRequestContextAndBuffer() async throws {
        for removing in [false, true] {
            try await withFixture { fixture in
                let id = try await fixture.admit()
                let sibling = try await fixture.admit()
                let reader = try #require(fixture.owner.contexts[sibling])
                weak var old = fixture.owner.contexts[id]
                let token = try await fixture.start(try #require(fixture.owner.contexts[id]))
                if removing { fixture.owner.remove(id) } else { fixture.owner.setEnabled(id, false) }
                try #require(fixture.owner.contexts[id] == nil)
                let reply = try await fixture.read(token, using: reader)
                #expect(reply["done"] as? Bool == true)
                #expect((reply["chunk"] as? String ?? "").isEmpty)
                for _ in 0..<100 where old != nil { try await Task.sleep(for: .milliseconds(10)) }
                #expect(old == nil)
            }
        }
    }

    @Test func unloadedContextCannotStartRequest() async throws {
        try await withFixture { fixture in
            let id = try await fixture.admit()
            let context = try #require(fixture.owner.contexts[id])
            fixture.owner.setEnabled(id, false)
            try #require(!context.isLoaded)
            try #require(context.hasAccess(to: fixture.url))
            let reply = try #require(try await ExtensionFetch.run("sitefetch.start", [["url": fixture.url.absoluteString]], context: context) as? [String: Any])
            print("fetch lifetime loopback unloaded-context reply:", reply)
            if let token = reply["id"] as? String { fixture.tokens.append(token) }
            #expect(reply["id"] == nil)
            // The parent token must also be explicitly cancelled on failure.
            if let token = reply["id"] as? String { _ = try? await ExtensionFetch.run("sitefetch.cancel", [token], context: context) }
        }
    }

    @Test func loadedRequestStillStreams() async throws {
        try await withFixture { fixture in
            let id = try await fixture.admit()
            let context = try #require(fixture.owner.contexts[id])
            let token = try await fixture.start(context)
            var received = Data()
            for _ in 0..<64 where received.count < LifetimeFetchSite.body.count {
                let reply = try await fixture.read(token, using: context)
                try #require(reply["done"] as? Bool == false)
                let chunk = try #require((reply["chunk"] as? String).flatMap { Data(base64Encoded: $0) })
                try #require(!chunk.isEmpty)
                received.append(chunk)
            }
            #expect(received == LifetimeFetchSite.body)
            #expect(context.isLoaded)
        }
    }

    @Test func siblingAndReplacementRequestsSurvive() async throws {
        try await withFixture { fixture in
            let id = try await fixture.admit()
            let sibling = try await fixture.admit()
            let siblingContext = try #require(fixture.owner.contexts[sibling])
            let siblingToken = try await fixture.start(siblingContext)
            let foreign = Extensions(signIn: UUID())
            defer { foreign.shutDown() }
            _ = try await fixture.admit(id, in: foreign)
            let foreignContext = try #require(foreign.contexts[id])
            let foreignToken = try await fixture.start(foreignContext)
            let oldToken = try await fixture.start(try #require(fixture.owner.contexts[id]))
            fixture.owner.setEnabled(id, false)
            fixture.owner.setEnabled(id, true)
            for _ in 0..<100 where fixture.owner.contexts[id] == nil { try await Task.sleep(for: .milliseconds(50)) }
            let replacement = try #require(fixture.owner.contexts[id])
            let replacementToken = try await fixture.start(replacement)
            _ = try await ExtensionFetch.run("sitefetch.cancel", [oldToken], context: replacement)
            let foreignReply = try await fixture.read(foreignToken, using: foreignContext)
            #expect(foreignReply["done"] as? Bool == false)
            #expect(!(foreignReply["chunk"] as? String ?? "").isEmpty)
            foreign.setEnabled(id, false)
            let siblingReply = try await fixture.read(siblingToken, using: siblingContext)
            let replacementReply = try await fixture.read(replacementToken, using: replacement)
            #expect(siblingReply["done"] as? Bool == false)
            #expect(!(siblingReply["chunk"] as? String ?? "").isEmpty)
            #expect(replacementReply["done"] as? Bool == false)
            #expect(!(replacementReply["chunk"] as? String ?? "").isEmpty)
            #expect(siblingContext.isLoaded && replacement.isLoaded)
            // The foreign request was independently valid before its own unload.
            #expect(foreignToken != replacementToken)
        }
    }
}
