import AppKit
import CryptoKit

/// A portable, content-addressed Look package. The digest pins bytes, not an
/// author's identity. Executable plugins travel as recipes until reviewed;
/// a reviewed one comes only from the Store's catalog, by its revision.
enum BoostShare {
    struct Payload: Codable { let format: Int; let id: String; let sites: [String]; let files: [String: String] }
    struct Envelope: Codable { let revision: String; let payload: Payload }
    /// The payload as its revision is the hash of: sorted keys, no spaces.
    static func encoded(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }
    static func digest(_ payload: Payload) throws -> String {
        SHA256.hash(data: try encoded(payload)).map { String(format: "%02x", $0) }.joined()
    }
    static func export(_ package: BoostPackage) throws -> Data {
        guard package.rung == .look else { throw BoostPackage.Invalid("Share the recipe for executable plugins. Code sharing needs a reviewed store release.") }
        let payload = Payload(format: 1, id: package.id, sites: package.sites, files: package.files)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Envelope(revision: digest(payload), payload: payload))
    }
    /// A shared package, Look only, unless `reviewed` names its revision:
    /// the Store's catalog, read from yetanotherbrowser.com, vouches for that
    /// exact code (StoreCatalog.codeRefusal). `id` keeps a kept package's
    /// name for its update; otherwise it is "shared-" and the revision's start.
    static func read(_ data: Data, id: String? = nil, reviewed: String? = nil) throws -> BoostPackage {
        guard data.count <= 1_000_000 else { throw BoostPackage.Invalid("This shared boost is too large.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.payload.format == 1, envelope.revision == (try digest(envelope.payload)) else { throw BoostPackage.Invalid("The shared boost's revision does not match its contents.") }
        let package = try BoostPackage.read(id: id ?? "shared-" + String(envelope.revision.prefix(16)), files: envelope.payload.files, sites: envelope.payload.sites)
        guard package.rung == .look || (reviewed != nil && reviewed == envelope.revision) else {
            throw BoostPackage.Invalid(reviewed == nil ? "Only Look boosts may be imported without store review. Ask your agent to build the recipe instead."
                                       : "This package is not the reviewed release the Store names.")
        }
        return package
    }
    /// The Store's site busy or down for the moment (5xx, 429, 408): asked
    /// again later, unlike a revision it doesn't have.
    struct Busy: LocalizedError {
        var errorDescription: String? { "The Store isn't answering right now." }
    }
    static func validRevision(_ revision: String) -> Bool { revision.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
    @discardableResult
    @MainActor static func fetch(_ revision: String, in browser: Browser, id: String? = nil, reviewed: Bool = false) async throws -> BoostPackage {
        let package = try read(await download(revision), id: id, reviewed: reviewed ? revision : nil)
        try await preview(package, in: browser)
        return package
    }
    /// A pinned revision's package from the Store, checked against its name.
    static func download(_ revision: String) async throws -> Data {
        guard validRevision(revision), let url = URL(string: "https://yetanotherbrowser.com/b/" + revision + "/package.boost") else { throw BoostPackage.Invalid("Invalid shared revision.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 20))
        if let code = (response as? HTTPURLResponse)?.statusCode, code >= 500 || code == 429 || code == 408 { throw Busy() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == url.host, http.url?.scheme == "https", data.count <= 1_000_000 else { throw BoostPackage.Invalid("This pinned boost is not available from the store.") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.revision == revision else { throw BoostPackage.Invalid("The server returned another revision.") }
        return data
    }
    @MainActor static func choose(in browser: Browser) async throws {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a .boost file to preview. Nothing is installed until Keep."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_000_000 else { throw BoostPackage.Invalid("This shared boost is too large.") }
        try await preview(read(Data(contentsOf: file)), in: browser)
    }
    @MainActor static func preview(_ package: BoostPackage, in browser: Browser) async throws {
        guard let site = package.sites.first, package.sites.count == 1, let address = package.previewURL else {
            throw BoostPackage.Invalid("Preview shared boosts one site at a time.")
        }
        let owner = Agents.shared.scripted(), tab = browser.benchOpen(address, space: nil)
        tab.agent = owner.id; browser.select(tab)
        for _ in 0..<150 {
            if tab.address?.host == site, !tab.page.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A trial merges into the saved files; a newer release replaces them whole.
        var changes = package.files.mapValues { $0 as Any }
        for path in ((try? Boosts.shared.files(package.id, session: owner.id)) ?? [:]).keys where package.files[path] == nil { changes[path] = NSNull() }
        _ = try await Boosts.shared.stage(name: package.id, changes: changes, sites: package.sites, tab: tab, session: owner.id)
    }
}
