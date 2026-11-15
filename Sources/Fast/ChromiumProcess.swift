import AppKit
import YabCoreClient

/// One lazy page process per application. The socket is private and disposable;
/// the data root is stable within Store's app/test world.
@MainActor
final class ChromiumProcess {
    static let shared = ChromiumProcess()
    private var client: YabCoreClient?
    var originalCallerDiagnostic: ChromiumOriginalCallerDiagnostic?
    var mayBeginOriginalCallerDiagnostic: Bool { originalCallerDiagnostic == nil && client == nil && process == nil && starting == nil }
    private var nativeHooks: [String: JSONValue] = [:]
    private var starting: Task<YabCoreClient, Error>?
    private var process: Process?
    var processID: pid_t? { process?.isRunning == true ? process?.processIdentifier : nil }
    private var directory: URL?
    private var generation = UUID()
    private var pages: [String: WeakPage] = [:]
    private var early: [YabCoreEvent] = []
    private var adopting: Set<String> = []
    private var downloads: [String: ChromiumDownload] = [:]
    private var endingRenderers: [String: Task<Void, Never>] = [:]
    private struct WeakPage { weak var value: ChromiumPage? }

    /// Local mirrors only. A census never creates or wakes a remote page.
    var livePages: [ChromiumPage] { pages.values.compactMap(\.value) }
    /// Popup retirement must never start a replacement helper.
    var connectedClient: YabCoreClient? { client }
    /// Identity of this helper lifetime, never a renderer document identity.
    var connectionGeneration: UUID { generation }
    func isCurrent(_ core: YabCoreClient) -> Bool { client === core }
    func isCurrent(_ core: YabCoreClient, generation expected: UUID) -> Bool {
        client === core && generation == expected
    }

    func connection() async throws -> YabCoreClient {
        if let client { return client }
        if let starting { return try await starting.value }
        if let diagnostic = originalCallerDiagnostic {
            guard !diagnostic.launchConsumed else { throw YabCoreError.disconnected }
            diagnostic.launchConsumed = true // Failed/lost original diagnostic never reconnects.
        }
        let token = UUID()
        generation = token
        let task = Task { @MainActor () throws -> YabCoreClient in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yc-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            directory = dir
            let socket = dir.appendingPathComponent("core.sock").path
            // SwiftPM's synchronous AppKit host is outside an app bundle.
            // Tests point to the exact CEF app assembled in this farm job.
            let testApp = Store.unitTests ? ProcessInfo.processInfo.environment["YAB_TEST_CEF_APP"] : nil
            let app = testApp.map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
            let helper = app.appendingPathComponent("Contents/MacOS/YabCore")
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw YabCoreError.transport("This dev app has no YabCore helper. Build with YAB_CEF=1.")
            }
            let child = Process()
            child.executableURL = helper
            child.arguments = ["--socket=" + socket, "--data-root=" + Store.file("Chromium").path]
            if Store.testing {
                // YAB_REAL_KEYCHAIN: a folder standing in for the helper's home,
                // whose search list holds a throwaway keychain. The real
                // keychain code runs; the Mac's login keychain is not touched.
                if let home = ProcessInfo.processInfo.environment["YAB_REAL_KEYCHAIN"], !home.isEmpty {
                    var environment = ProcessInfo.processInfo.environment
                    environment["HOME"] = home
                    child.environment = environment
                } else {
                    child.arguments?.append("--use-mock-keychain")
                }
                if ProcessInfo.processInfo.environment["YAB_CHROMIUM_FAKE_MEDIA"] == "1" {
                    child.arguments?.append("--use-fake-device-for-media-stream")
                }
            }
            // Avoid pipe backpressure; the farm app log owns stderr.
            child.standardOutput = FileHandle.standardError
            child.standardError = FileHandle.standardError
            let preparedPeer: NativePeerIdentity.PreparedLaunch?
            if let diagnostic = originalCallerDiagnostic {
                child.arguments?.append("--observe-original-caller")
                if diagnostic.deadline { child.arguments?.append("--original-caller-deadline-gate") }
                switch NativePeerIdentity.prepareDiagnosticLaunchResult(child) {
                case .prepared(let prepared): preparedPeer = prepared
                case .helperImageRefused:
                    diagnostic.helperImageRefused = true
                    throw YabCoreError.transport("Original diagnostic exact helper image refused")
                case .unavailable: throw YabCoreError.transport("Original diagnostic static helper preparation unavailable")
                }
            } else { preparedPeer = NativePeerIdentity.prepareLaunch(child) }
            try child.run()
            let originalPeer = preparedPeer?.captureLaunched() // Actual same child, before the first await.
            process = child
            originalCallerDiagnostic?.process = child
            originalCallerDiagnostic?.witness = originalPeer
            do {
                if originalCallerDiagnostic != nil && originalPeer == nil {
                    throw YabCoreError.transport("Original diagnostic child birth witness unavailable")
                }
                let until = Date().addingTimeInterval(20)
                while !FileManager.default.fileExists(atPath: socket) {
                    guard child.isRunning, Date() < until else { throw YabCoreError.transport("YabCore did not start") }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                let core = try await YabCoreClient.connect(path: socket, originalLaunch: originalPeer)
                nativeHooks = await core.nativeHooks
                client = core
                ChromiumTabGroups.shared.start()
                originalCallerDiagnostic?.client = core
                Task { @MainActor [weak self] in
                    for await event in core.events {
                        guard let self, self.generation == token else { return }
                        self.receive(event, from: core, generation: token)
                    }
                    guard let self, self.generation == token else { return }
                    self.exited()
                }
                return core
            } catch {
                if child.isRunning { child.terminate() }
                throw error
            }
        }
        starting = task
        do { let core = try await task.value; starting = nil; return core }
        catch { starting = nil; exited(); throw error }
    }

    func attach(_ page: ChromiumPage, id: String) {
        pages[id] = WeakPage(value: page)
        let buffered = early.filter { $0.tab == id }
        early.removeAll { $0.tab == id }
        if let client {
            page.refreshNativeMediaState(core: client, remote: id, hooks: nativeHooks)
            page.refreshOriginalPDFPresence(core: client, remote: id, hooks: nativeHooks)
        }
        buffered.forEach(page.receive)
    }
    func detach(_ id: String) {
        pages.removeValue(forKey: id)
        guard let client else { return }
        let ending = endingRenderers.removeValue(forKey: id)
        Task {
            await ending?.value
            try? await client.closeTab(id)
        }
    }

    /// Ending a hung renderer must survive retirement of its page and must
    /// precede closing its native browser. Never start a helper for cleanup.
    func endRenderer(tab id: String, pid: pid_t) {
        guard let client, endingRenderers[id] == nil else { return }
        endingRenderers[id] = Task {
            _ = try? await client.request("page.killRenderer", params: ["tab": .string(id), "rendererPID": .number(Double(pid))])
            self.endingRenderers[id] = nil
        }
    }
    func keepDownload(_ download: ChromiumDownload) { downloads[download.remoteID] = download }
    private func receive(_ event: YabCoreEvent, from source: YabCoreClient, generation sourceGeneration: UUID) {
        guard isCurrent(source, generation: sourceGeneration) else { return }
        if ChromiumDRMExtensionSession.receive(event, from: client) { return }
        if ChromiumConsent.receive(event, from: client) { return }
        if ChromiumColumn.receive(event) { return }
        if event.name == "download.updated", let id = event.params["download"]?.string, let download = downloads[id] {
            download.receive(event.params)
            if event.params["complete"] == .bool(true) || event.params["canceled"] == .bool(true) || event.params["interrupted"] == .bool(true) {
                downloads[id] = nil
            }
            return
        }
        guard let id = event.tab else { return }
        if let page = pages[id]?.value {
            if event.name == "tab.closed" { pages.removeValue(forKey: id) }
            if event.name == "page.originalPDF.changed" {
                page.receiveOriginalPDFPresence(event, from: source, generation: sourceGeneration)
            } else { page.receive(event) }
        }
        else if event.name == "tab.created" {
            adoptCreatedTab(event)
        } else {
            early.append(event)
            if early.count > 256 { early.removeFirst() }
        }
    }
    private func exited() {
        ChromiumConsent.disconnected(client)
        generation = UUID()
        client = nil
        nativeHooks = [:]
        process = nil
        let lostDownloads = Array(downloads.values); downloads.removeAll()
        lostDownloads.forEach { $0.fail(YabCoreError.disconnected) }
        let live = pages.values.compactMap(\.value)
        pages.removeAll(); early.removeAll(); adopting.removeAll()
        live.forEach { $0.helperExited() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    // Used only by the isolated acceptance probe. Closing the socket also makes
    // CEF close all producer windows when the application exits.
    func crashForTesting() { if Store.testing { process?.terminate() } }

    /// Mark the native tab adopted before any input/binding command is sent.
    /// Replies and events from a replaced helper must never attach to this one.
    private func adoptCreatedTab(_ event: YabCoreEvent) {
        guard let client, let id = event.tab, let profile = event.params["profile"]?.string,
              case .bool(let privateMode) = event.params["private"] else { return }
        guard adopting.insert(id).inserted else { return }
        let token = generation
        Task { @MainActor [weak self] in
            guard let self, self.generation == token else { return }
            defer { if self.generation == token { self.adopting.remove(id) } }
            do {
                let receipt = try await client.request("tab.adopt", params: ["tab": .string(id), "profile": .string(profile), "private": .bool(privateMode)])
                guard self.generation == token else { return }
                var params = event.params
                if case .object(let fields) = receipt { params.merge(fields) { _, new in new } }
                let accepted = YabCoreEvent(name: event.name, params: params)
                let opener = params["opener"]?.string.flatMap { self.pages[$0]?.value?.navigationTab }
                if params["source"]?["documentPiP"] == .bool(true) {
                    guard let opener, let browser = opener.delegate as? Browser,
                          opener.documentPiP.openChromium(accepted, source: opener, browser: browser) else {
                        try? await client.closeTab(id); return
                    }
                } else if ChromiumTabAdoption.install(accepted, opener: opener,
                    owner: params["extensionCreation"]?["ownerTab"].string.flatMap { self.pages[$0]?.value?.navigationTab }) == nil {
                    try? await client.closeTab(id); return
                }
            } catch { try? await client.closeTab(id) }
        }
    }
}
