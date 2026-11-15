import AppKit
import QuartzCore
import Combine
import YabCoreClient

/// Remote pixels and native input only. StageView owns clipping and corners.
@MainActor
final class ChromiumPage: NSView, PageHandle, PageAudioControl, NSTextInputClient {
    let engine = PageEngineKind.chromium
    weak var events: (any PageEvents)?
    weak var stateEvents: (any PageStateEvents)?
    private(set) var url: URL?
    private(set) var committedURL: URL?
    var historyEntry: PageHistoryEntry? { committedURL.map { PageHistoryEntry(url: $0, title: title ?? "") } }
    private(set) var title: String?
    private(set) var isLoading = false
    var estimatedProgress: Double { isLoading ? 0.5 : 1 }
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var themeColor: NSColor?
    var lastInput: TimeInterval?
    var pageZoom: CGFloat = 1 { didSet { applyZoom() } }
    var magnification: CGFloat = 1 { didSet { applyZoom() } }
    private(set) var contentProcess: pid_t?
    private(set) var audioMuted = false
    var gpuProcess: pid_t? { nil }
    var captureStatus: PageCaptureStatus { media.captureStatus }
    /// Sound, Now Playing, capture and full screen (ChromiumPage+Media.swift).
    let media = ChromiumMedia()
    let sleepState = ChromiumSleep()
    var videoPiP: ChromiumVideoPiP?
    var nativeVideoPiPKnown = false
    var nativeVideoPiPRevision: UInt64 = 0
    private(set) var remoteID: String?
    private(set) var contextID: UInt32 = 0
    let scripts = ChromiumScripts()
    lazy var swipe = ChromiumSwipe(self)
    let fileRequests = PageFileRequests()
    let questionRequests = ChromiumQuestionRequests()
    /// A native document child has a panel owner, never a tab-strip row.
    var onDocumentClosed: (@MainActor () -> Void)?
    /// This page is Chrome's DevTools for another (ChromiumDevTools.swift).
    var isDevToolsFrontend = false
    weak var navigationTab: Tab?
    private var tab: Tab? { get { navigationTab } set { navigationTab = newValue } }
    private(set) var diagnosticFailure: String?
    var nativeFindTask: Task<Void, Never>?
    var nativeFindEpoch = 0
    var nativePrintTask: Task<Void, Never>?
    var nativePrintRequestID: String?
    var nativePrintEpoch = 0
    var originalPDFPresence = ChromiumOriginalPDFPresenceState()
    var originalPDFObservationTask: Task<Void, Never>?
    var originalPDFPeer: YabCoreClient?
    var originalPDFHooks: [String: JSONValue] = [:]
    /// Local navigation blocks re-observation until native commit/adoption.
    var originalPDFAdmissionAllowed = true
    /// Actual PDF handed to the native sheet, exposed only in disposable probes.
    var printPreviewForTesting: [String: Any] = [:]
    let profile: String
    let privateMode: Bool
    var profileSpaceID: UUID? {
        guard !privateMode, let tab = navigationTab else { return nil }
        return ChromiumPersistentProfiles.plan(for: tab.pageStore).logical
    }
    private weak var extensionTab: Tab?
    private var extensionWatch: AnyCancellable?
    private(set) lazy var extensions = ChromiumExtensions.shared(profile: profile, privateMode: privateMode, store: navigationTab?.pageStore)
    private(set) var retired = false
    private var helperWasLost = false
    private var operationEpoch = 0
    private var documentTurn = 0
    private var scriptTarget: URL?
    private var lastReadiness: [String: Any] = [:]
    private var lastLoadError: [String: Any] = [:]
    private var drmTurn = 0
    private var creating: Task<(YabCoreClient, String), Error>?
    private var navigationBinding: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private let remoteParent = CALayer()
    private var remoteLayer: CALayer?
    private var extensionPageOffset: CGPoint = .zero
    private var resizeState = ChromiumResize()
    private var desiredGeometry: ChromiumResize.Geometry?
    private var sentGeometry: ChromiumResize.Geometry?
    private var geometryQueued = false
    private var navigation: PageNavigation?
    private var awaitingInitialDocument = false
    private var initialNativeLoading: Bool?
    private var initialRequestedURL: URL?
    private var tracking: NSTrackingArea?
    /// The pointer moved inside since it last came in (ChromiumPage+Hover).
    var hoverAdmitted = false
    var hoverMovePending = false
    var hoverMovedAt: TimeInterval = 0
    /// For the acceptance eval: pointer moves seen, and helper status messages heard.
    var hoverCounts = (moved: 0, status: 0, last: "", heard: [String]())
    var editingKeyCodes = Set<UInt16>()
    var pageCopyTurn = 0
    private var marked = NSAttributedString(string: "")
    /// Where the marked text starts in the field, until the page's own
    /// composition range says (markedRange).
    private var markedStart = NSNotFound
    /// Local invalidation only, never a native document lease.
    private(set) var inputMethodGeneration = 0
    private(set) var inputMethodDispatched = 0
    private(set) var inputMethodTicket: ChromiumInputMethodTicket?
    var inputMethodTurn: Int { documentTurn }
    var inputMethodLive: Bool { !retired && !helperWasLost && remoteID != nil }
    func afterInputMethodDispatch(_ done: @escaping @MainActor () -> Void) {
        let accepted = tail
        Task { @MainActor in await accepted?.value; done() }
    }
    func discardNativeComposition() {
        inputMethodGeneration &+= 1
        marked = NSAttributedString(string: "")
        imeHandled = false
        imeKeys.removeAll()
    }
    // Own CEF text input (ChromiumPage+TextInput.swift).
    var nativeText: [String: JSONValue]?
    // AppKit reads this Objective-C getter from its actual input client.
    // Until an authenticated field report arrives, offer no guessed OTP hint.
    @objc var contentType: NSTextContentType? = .URL {
        didSet {
            if contentType != oldValue { inputContext?.invalidateCharacterCoordinates() }
        }
    }
    var remoteFocused: Bool?
    var keyWatch: [NSObjectProtocol] = []
    var imeHandled = false
    var imeKeys: Set<UInt16> = []
    /// Edits Yab's input context makes while it reads a key, held until the
    /// key's route is known (composeKey, ChromiumPage+TextInput.swift).
    var keyInterpretation: ChromiumKeyInterpretation?
    /// The last keys' routes, kept only in test worlds for evals.
    var keyRoutes: [String] = []
    var pressureStage = 0
    private var stepButton: Int?
    var selectMenu: NSMenu?
    var selectToken: Int?
    // Own CEF extension hooks (ChromiumPage+Popup.swift).
    var extensionPopup: ChromiumExtensionPopup?
    var onExtensionPopup: (@MainActor (ChromiumExtensionPopup?) -> Void)?
    var onExtensionTabCreated: (@MainActor (ExtensionTabRequest) -> Void)?
    private var desiredAudioMuted: Bool

    init(tab: Tab, profile: String? = nil) {
        navigationTab = tab
        self.profile = profile ?? tab.chromiumProfile
        privateMode = tab.shy || !tab.pageStore.isPersistent
        extensionTab = tab
        desiredAudioMuted = tab.muted
        super.init(frame: .zero)
        scripts.page = self
        scripts.tab = tab
        wantsLayer = true
        // Match Chromium's CALayerHost geometry. Its bounds MUST stay zero.
        remoteParent.isGeometryFlipped = true
        layer?.addSublayer(remoteParent)
        extensionWatch = extensions.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.tellNativeStore() }
        }
    }
    required init?(coder: NSCoder) { nil }
    func adoptRemote(_ id: String) {
        precondition(remoteID == nil && creating == nil && !retired)
        remoteID = id
        ChromiumProcess.shared.attach(self, id: id)
        if desiredAudioMuted { command("media.mute", ["muted": .bool(true)]) }
        command("script.bind", ["world": .string("yab-world-yab"), "name": .string("yabFindChanged")])
        syncGeometry()
    }
    // Match the separate-process reference host: an ordinary AppKit view
    // with one flipped child layer, not two nested flipped coordinate spaces.
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    func endpoint() async throws -> (YabCoreClient, String) {
        guard let owner = navigationTab, owner.chromiumProfile == profile else { throw SiteEngineError.profileChanged }
        try ChromiumPrivateProfiles.authorize(profile, store: owner.pageStore, privateMode: privateMode)
        // Geometry, snapshots and script refreshes cannot replace a lost
        // document with an empty bootstrap tab. Navigation owns recovery.
        guard !retired, !helperWasLost else { throw YabCoreError.disconnected }
        if let creating { return try await creating.value }
        if let remoteID { return (try await ChromiumProcess.shared.connection(), remoteID) }
        // DevTools' frontend only ever adopts Chrome's own tab: an empty one
        // made here would race devtools.open.
        guard !isDevToolsFrontend else { throw YabCoreError.disconnected }
        let epoch = operationEpoch
        let task = Task { @MainActor () throws -> (YabCoreClient, String) in
            let core = try await ChromiumProcess.shared.connection()
            try await core.openProfile(profile, privateMode: privateMode)
            // CEF's empty URL creates an initial, unnavigated document. An
            // explicit about:blank would become a spurious first Back entry.
            let id = try await core.createTab(profile: profile, url: "")
            guard !Task.isCancelled, !retired, operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core) else {
                try? await core.closeTab(id); throw CancellationError()
            }
            remoteID = id
            ChromiumProcess.shared.attach(self, id: id)
            self.syncRemoteFocus()
            do { try await scripts.install(core: core, tab: id) }
            catch {
                if operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core), remoteID == id {
                    ChromiumProcess.shared.detach(id); remoteID = nil
                }
                throw error
            }
            // createTab replies only once the native endpoint accepts LoadURL. The
            // unnavigated document has no renderer yet, so the helper brings up
            // the agent that scripts need with a blank document of its own
            // (scripts.inc ScriptWithAgent): nothing here waits on a document.
            if desiredAudioMuted { _ = try await core.request("media.mute", params: ["tab": .string(id), "muted": .bool(true)]) }
            try await self.sendGeometry(core, id, self.currentGeometry)
            guard !Task.isCancelled, !retired, operationEpoch == epoch,
                  ChromiumProcess.shared.isCurrent(core), remoteID == id else { throw CancellationError() }
            // Runtime binding may await the first document. It must not hold
            // LoadURL or the native auth/certificate continuation behind it.
            navigationBinding = Task { @MainActor [weak self] in
                guard let self, self.remoteID == id else { return }
                do {
                    _ = try await core.request("script.bind", params: ["tab": .string(id), "world": .string("yab-world-yab"), "name": .string("yabFindChanged")])
                } catch {
                    if !Task.isCancelled { DebugLog.note("chromium-binding", ["error": String(describing: error)]) }
                }
            }
            return (core, id)
        }
        creating = task
        do { let result = try await task.value; if operationEpoch == epoch { creating = nil }; return result }
        catch { if operationEpoch == epoch { creating = nil }; throw error }
    }
    /// Serialize accepted user operations, especially down/text/up and resize.
    private func enqueue(_ operation: @escaping @MainActor (YabCoreClient, String) async throws -> Void) {
        let previous = tail
        let epoch = operationEpoch
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !self.retired, !Task.isCancelled, self.operationEpoch == epoch else { return }
            do {
                let (core, id) = try await self.endpoint()
                guard !Task.isCancelled, self.operationEpoch == epoch, ChromiumProcess.shared.isCurrent(core) else { return }
                try await operation(core, id)
            }
            catch { if !self.retired, self.operationEpoch == epoch { self.failed(error) } }
        }
    }
    func command(_ method: String, _ params: [String: JSONValue] = [:]) {
        enqueue { core, id in
            var p = params; p["tab"] = .string(id)
            _ = try await core.request(method, params: p)
        }
    }
    /// A live site setting changed. Replace document-start registrations
    /// before a subsequent reload, in the same queue as navigation and input.
    func refreshFeatureScripts() {
        enqueue { [weak self] core, id in
            guard let self else { return }
            try await self.scripts.prepare(core: core, tab: id, url: self.url)
        }
    }
    /// Complete native selection before a page feature reads that selection.
    func afterAcceptedInput(_ done: @escaping @MainActor () -> Void) {
        let accepted = tail
        Task { @MainActor [weak self] in
            await accepted?.value
            guard let self, !self.retired else { return }
            done()
        }
    }
    /// Navigation capabilities use the same endpoint and accepted-operation order.
    func navigationRequest(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        var p = params; p["tab"] = .string(id)
        return try await core.request(method, params: p)
    }
    func captureOriginalPDFEndpoint() async throws -> OriginalPDFEndpoint {
        guard !Task.isCancelled, !retired, !helperWasLost, !isLoading,
              let remote = remoteID, let core = originalPDFPeer,
              let scope = originalPDFPresence.owner, let presence = originalPDFPresence.ready,
              originalPDFPresenceOwnerIsCurrent(scope, core: core),
              let tab = navigationTab, tab.builtPage === self else {
            throw CancellationError()
        }
        let endpoint = OriginalPDFEndpoint(core: core,
            binding: OriginalPDFBinding(tab: remote, profile: profile, call: UUID().uuidString),
            epoch: operationEpoch, turn: documentTurn, printEpoch: nativePrintEpoch,
            generation: scope.process, observation: scope.observation, owner: ObjectIdentifier(tab), presence: presence)
        let accepted = tail
        let hooks = await core.nativeHooks
        guard ChromiumOriginalPDFPresenceState.supported(hooks) else {
            throw YabCoreError.remote("Original native PDF bytes are unavailable on this endpoint")
        }
        await accepted?.value
        guard !Task.isCancelled, originalPDFEndpointIsCurrent(endpoint) else { throw CancellationError() }
        return endpoint
    }
    func originalPDFEndpointIsCurrent(_ endpoint: OriginalPDFEndpoint) -> Bool {
        !retired && !helperWasLost && !isLoading && remoteID == endpoint.binding.tab &&
            profile == endpoint.binding.profile && operationEpoch == endpoint.epoch &&
            documentTurn == endpoint.turn && nativePrintEpoch == endpoint.printEpoch &&
            originalPDFPeer === endpoint.core && originalPDFPresence.owner?.observation == endpoint.observation &&
            originalPDFPresence.ready == endpoint.presence && originalPDFPresence.admission != nil &&
            originalPDFPresence.owner.map { originalPDFPresenceOwnerIsCurrent($0, core: endpoint.core) } == true &&
            ChromiumProcess.shared.isCurrent(endpoint.core, generation: endpoint.generation) &&
            navigationTab.map { ObjectIdentifier($0) == endpoint.owner && $0.builtPage === self } == true
    }
    func captureOriginalPDFPresenceOwner(core: YabCoreClient) -> ChromiumOriginalPDFPresenceState.Owner? {
        guard !retired, !helperWasLost, originalPDFAdmissionAllowed, let remoteID, let tab = navigationTab,
              tab.builtPage === self, originalPDFPeer === core, ChromiumProcess.shared.isCurrent(core),
              originalPDFProfileIsCurrent(tab) else { return nil }
        return .init(peer: ObjectIdentifier(core), process: ChromiumProcess.shared.connectionGeneration,
                     tab: remoteID, profile: profile, pageOwner: ObjectIdentifier(tab), store: ObjectIdentifier(tab.pageStore),
                     epoch: operationEpoch, turn: documentTurn, observation: UUID())
    }
    func originalPDFPresenceOwnerIsCurrent(_ owner: ChromiumOriginalPDFPresenceState.Owner, core: YabCoreClient) -> Bool {
        !retired && !helperWasLost && originalPDFPeer === core && owner.peer == ObjectIdentifier(core) &&
            originalPDFPresence.owner == owner && remoteID == owner.tab && profile == owner.profile &&
            operationEpoch == owner.epoch && documentTurn == owner.turn &&
            ChromiumProcess.shared.isCurrent(core, generation: owner.process) &&
            navigationTab.map { ObjectIdentifier($0) == owner.pageOwner && $0.builtPage === self &&
                ObjectIdentifier($0.pageStore) == owner.store && originalPDFProfileIsCurrent($0) } == true
    }
    private func originalPDFProfileIsCurrent(_ tab: Tab) -> Bool {
        guard tab.chromiumProfile == profile else { return false }
        do {
            try ChromiumPrivateProfiles.authorize(profile, store: tab.pageStore, privateMode: privateMode)
            return true
        } catch { return false }
    }
    func originalPDFPresenceBecameUnavailable() {
        guard let tab = navigationTab, tab.builtPage === self else { return }
        tab.paper.nativePresenceUnavailable()
    }
    func presentOriginalPDFPresence() {
        guard !isLoading, let core = originalPDFPeer, let scope = originalPDFPresence.owner,
              originalPDFPresenceOwnerIsCurrent(scope, core: core), let identity = originalPDFPresence.ready,
              let tab = navigationTab else { return }
        tab.paper.nativePresenceReady(identity, tab: tab, page: self,
                                      visible: window != nil && !isHiddenOrHasHiddenAncestor)
    }
    /// A native continuation must not wait behind the script that requested it.
    /// In particular, window.print() can be suspended in the operation queue.
    func finishNativePrint(_ request: String, remote: String) async throws -> Bool {
        guard !retired, remoteID == remote else { throw CancellationError() }
        let core = try await ChromiumProcess.shared.connection()
        guard !retired, remoteID == remote, ChromiumProcess.shared.isCurrent(core) else { throw CancellationError() }
        let reply = try await core.request("print.finish", params: ["tab": .string(remote), "request": .string(request)])
        return reply["finished"] == .bool(true)
    }
    func navigate(to request: URLRequest) {
        guard let target = request.url else { return }
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        scriptTarget = target
        drmTurn &+= 1
        if let tab, tab.builtPage === self, tab.wantsWebKit(for: target) {
            // A page that never showed a document (a new tab opened straight
            // to Netflix) has nothing to ask before it goes: the switch's
            // native approval waited on a document that never came, and
            // the tab stayed blank on Chromium.
            if url == nil || url?.absoluteString == "about:blank" {
                DispatchQueue.main.async { [weak self, weak tab] in
                    guard let self, let tab, tab.builtPage === self, !self.retired else { return }
                    tab.replaceEngine(with: .webKit, at: request)
                }
                return
            }
            switchToWebKit(request)
            return
        }
        let navigation: ChromiumDRMNavigation
        do { navigation = try ChromiumDRMNavigation(request) }
        catch { failed(error); return }
        helperWasLost = false
        awaitingInitialDocument = remoteID == nil && target.absoluteString != "about:blank"
        markLoading()
        enqueue { [weak self] core, id in
            if let self, let tab = self.tab {
                guard tab.chromiumProfile == self.profile else { throw SiteEngineError.profileChanged }
                try await ChromiumDRMCookies.of(tab).synchronizeForSwitching()
                guard !self.retired, tab.builtPage === self else { throw CancellationError() }
            }
            try await self?.scripts.prepare(core: core, tab: id, url: target)
            try await core.navigate(tab: id, parameters: navigation.parameters)
        }
    }
    private func switchToWebKit(_ request: URLRequest, emeFailure: Bool = false) {
        let turn = drmTurn
        Task { @MainActor [weak self] in
            guard let self, let tab = self.tab, let target = request.url else { return }
            guard tab.chromiumProfile == profile else {
                failed(YabCoreError.remote("DRM fallback requires migration of the moved tab's Chromium profile"))
                return
            }
            do {
                guard !retired, drmTurn == turn, tab.builtPage === self,
                      tab.chromiumProfile == profile, tab.address == target,
                      tab.wantsWebKit(for: target, emeFailure: emeFailure) else { return }
                // Service routing and an EME failure identify a destination;
                // neither supplies native approval to retire this document.
                try await EngineSwitchTransaction.execute([
                    .init(tab: tab, engine: .webKit, request: request, isCurrent: { [weak self, weak tab] in
                        guard let self, let tab else { return false }
                        return !self.retired && self.drmTurn == turn && tab.builtPage === self &&
                            tab.chromiumProfile == self.profile && tab.address == target &&
                            tab.wantsWebKit(for: target, emeFailure: emeFailure)
                    })
                ])
            } catch {
                // Stay, or a switch that failed: the document shown is still
                // here, so the tab says it again rather than where it was going.
                guard !retired, drmTurn == turn else { return }
                scriptTarget = url
                tab.keepShowing(self)
                tab.engineSwitchFailed(error, to: .webKit)
            }
        }
    }
    func navigate(html: String, base: URL?) {
        swipe.invalidate()
        drmTurn &+= 1
        if let base, ["http", "https"].contains(base.scheme?.lowercased() ?? "") {
            // The page keeps the base URL and origin: the helper serves this body to the one navigation to it.
            documentTurn &+= 1
            invalidateOriginalPDFPresence()
            helperWasLost = false
            scriptTarget = base
            awaitingInitialDocument = remoteID == nil
            markLoading()
            enqueue { [weak self] core, id in
                try await self?.scripts.prepare(core: core, tab: id, url: base)
                _ = try await core.request("tab.loadHTML", params: ["tab": .string(id), "url": .string(base.absoluteString), "html": .string(html)])
            }
            return
        }
        let value = Data(html.utf8).base64EncodedString()
        navigate(to: URLRequest(url: URL(string: "data:text/html;base64," + value)!))
    }
    func reload(fromOrigin: Bool) {
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        if remoteID == nil, let url { navigate(to: URLRequest(url: url)) }
        else { command("tab.reload", ["fromOrigin": .bool(fromOrigin)]) }
    }
    func refreshEngineSwitchScripts() {
        enqueue { [weak self] core, id in
            guard let self else { return }
            try await self.scripts.prepare(core: core, tab: id, url: self.url)
        }
    }
    func stopLoading() {
        awaitingInitialDocument = false
        command("tab.stop")
    }
    func navigateBack() { swipe.invalidate(); documentTurn &+= 1; invalidateOriginalPDFPresence(); scriptTarget = nil; command("tab.back") }
    func navigateForward() { swipe.invalidate(); documentTurn &+= 1; invalidateOriginalPDFPresence(); scriptTarget = nil; command("tab.forward") }
    func childFrames(_ done: @escaping @MainActor ([PageFrame]) -> Void) {
        Task { @MainActor in
            do {
                await tail?.value
                let (core, id) = try await endpoint()
                let result = try await core.request("scripts.frames", params: ["tab": .string(id)])
                done(scripts.frames(result, tab: id))
            } catch { done([]) }
        }
    }
    func retire(call: Bool, pictureInPicture: Bool) {
        invalidateOriginalPDFPresence(releasePeer: true)
        questionRequests.cancel()
        resetNativeTextInput()
        swipe.invalidate()
        fileRequests.cancel()
        cancelNativePrint()
        ChromiumPopupHost.shared.retire(self)
        extensionPopup?.close(); extensionPopup = nil
        nativeFindEpoch += 1; nativeFindTask?.cancel()
        retired = true; tail?.cancel(); creating?.cancel(); hoverAdmitted = false
        scripts.clearFrames()
        navigationBinding?.cancel(); navigationBinding = nil
        events = nil; stateEvents = nil
        if let remoteID { ChromiumProcess.shared.detach(remoteID) }
        remoteID = nil; contentProcess = nil; contextID = 0
        resetGeometry()
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        mediaEnded()
    }
    func helperExited() {
        guard !retired else { return }
        invalidateOriginalPDFPresence(releasePeer: true)
        questionRequests.cancel()
        resetNativeTextInput()
        swipe.invalidate()
        helperWasLost = true
        operationEpoch &+= 1
        tail?.cancel(); tail = nil
        creating?.cancel()
        remoteFocused = nil
        fileRequests.cancel()
        if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
        scripts.clearFrames()
        cancelNativePrint()
        ChromiumPopupHost.shared.retire(self)
        extensionPopup = nil
        nativeFindEpoch += 1; nativeFindTask?.cancel()
        navigationBinding?.cancel(); navigationBinding = nil
        remoteID = nil; creating = nil; contextID = 0
        resetGeometry()
        contentProcess = nil
        mediaEnded()
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        isLoading = false; stateEvents?.page(self, changed: .loading(false))
        Leaving.chromiumClosed(self)
        // Keep the crash visible until the next explicit navigation/reload.
        failed(YabCoreError.disconnected)
    }
    func clearDiscardedRenderer() {
        questionRequests.cancel()
        resetNativeTextInput()
        swipe.invalidate()
        documentTurn &+= 1
        invalidateOriginalPDFPresence()
        contentProcess = nil
        contextID = 0
        remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
        isLoading = false
        stateEvents?.page(self, changed: .loading(false))
    }
    private func markLoading() {
        initialNativeLoading = nil
        initialRequestedURL = awaitingInitialDocument ? scriptTarget : nil
        isLoading = true
        stateEvents?.page(self, changed: .loading(true))
    }
    private func failed(_ error: Error) {
        diagnosticFailure = String(describing: error)
        awaitingInitialDocument = false
        isLoading = false
        stateEvents?.page(self, changed: .loading(false))
        events?.page(self, navigation: .failed(navigation, error, provisional: false))
    }
    func receive(_ event: YabCoreEvent) {
        guard !retired, event.tab == remoteID else { return }
        let p = event.params
        switch event.name {
        case "tab.closePreflight": _ = receiveLifecycle(event)
        case "script.relay": scripts.receive(event)
        case "page.hover": hoverStatus(p["url"]?.string ?? "")
        case "script.error": failed(YabCoreError.remote(p["message"]?.string ?? "Page scripts failed"))
        case "tab.closed":
            // Drop the native identity first so retirement cannot close a new
            // helper's tab that happens to reuse the same wire identifier.
            remoteID = nil
            if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
            // The native page is terminal even while a Leaving batch keeps
            // its row. Late scripts/input must not create a replacement tab.
            retire(call: false, pictureInPicture: false)
            // An asked batch owns row removal after the remaining pages
            // answer. Removing it here can select/retire the next page.
            if receiveLifecycle(event) { return }
            guard let tab = navigationTab, !tab.gone, let browser = tab.delegate as? Browser else { return }
            if browser.tabs.contains(where: { $0 === tab }) { browser.close(tab) }
            else { browser.closeElsewhere(tab) }
        case "drm.unavailable":
            // Use the helper's native main-frame URL, never a page-supplied target.
            guard p["keySystem"]?.string == "com.widevine.alpha",
                  let target = p["url"]?.string.flatMap(URL.init(string:)),
                  ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
                  target == url, let tab, tab.builtPage === self else { return }
            if tab.wantsWebKit(for: target, emeFailure: true) { switchToWebKit(URLRequest(url: target), emeFailure: true) }
        case "page.state":
            var settledBlankLoading: Bool?
            if awaitingInitialDocument, case .bool(let loading) = p["loading"] {
                initialNativeLoading = loading
            }
            // A fragment navigation in CEF's bootstrap blank document has no
            // new OnLoadStart/commit. Accept only the requested native URL,
            // and retain the real loading receipt if it preceded that URL.
            if awaitingInitialDocument, let target = initialRequestedURL,
               target.absoluteString.hasPrefix("about:blank#"),
               p["url"]?.string == target.absoluteString {
                awaitingInitialDocument = false
                if p["loading"] == nil { settledBlankLoading = initialNativeLoading }
            }
            receiveSleep(p)
            if let value = p["rendererPID"]?.number { contentProcess = !sleepState.discarded && value > 0 && value <= Double(Int32.max) ? pid_t(value) : nil }
            if case .bool(let value) = p["audioMuted"] { audioMuted = value }
            if let value = p["url"]?.string {
                if !value.isEmpty, value != "about:blank" || scriptTarget == nil { scriptTarget = URL(string: value) }
                url = URL(string: value); stateEvents?.page(self, changed: .url(url))
                if let url, let tab, tab.wantsWebKit(for: url) { switchToWebKit(URLRequest(url: url)) }
            }
            if let value = p["title"]?.string { title = value; stateEvents?.page(self, changed: .title(value)) }
            if case .bool(let v) = p["loading"], v || !awaitingInitialDocument {
                isLoading = v; stateEvents?.page(self, changed: .loading(v))
            } else if let loading = settledBlankLoading {
                isLoading = loading; stateEvents?.page(self, changed: .loading(loading))
            }
            if case .bool(let v) = p["canGoBack"] { canGoBack = v; stateEvents?.page(self, changed: .back(v)) }
            if case .bool(let v) = p["canGoForward"] { canGoForward = v; stateEvents?.page(self, changed: .forward(v)) }
            if let value = p["backgroundColor"] {
                // Own CEF reports the page's CSS background. Fill area the page
                // has not drawn yet while resizing with it, as Chromium does.
                let hex = value.string?.replacingOccurrences(of: "#", with: "") ?? ""
                CATransaction.begin(); CATransaction.setDisableActions(true)
                if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
                    layer?.backgroundColor = CGColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                                                     blue: CGFloat(rgb & 255) / 255, alpha: 1)
                } else { layer?.backgroundColor = nil }
                CATransaction.commit()
            }
            if let value = p["themeColor"] {
                let hex = value.string?.replacingOccurrences(of: "#", with: "") ?? ""
                if hex.count == 6, let rgb = UInt32(hex, radix: 16) {
                    let c = PageColor(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
                    themeColor = NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
                    stateEvents?.page(self, changed: .theme(c))
                } else { themeColor = nil; stateEvents?.page(self, changed: .theme(nil)) }
            }
            if p["loading"] == .bool(false) { presentOriginalPDFPresence() }
        case "page.started":
            invalidateOriginalPDFPresence()
            resetNativeTextInput()
            questionRequests.cancel()
            swipe.invalidate()
            fileRequests.cancel()
            scripts.clearFrames()
            cancelNativePrint()
            navigation = PageNavigation(); events?.page(self, navigation: .started(navigation))
        case "page.committed":
            // The helper's startup about:blank is not the accepted request.
            let committed = p["url"]?.string.flatMap(URL.init(string:)) ?? url
            if awaitingInitialDocument {
                guard let committed, !committed.absoluteString.isEmpty,
                      committed.absoluteString != "about:blank" else { return }
                awaitingInitialDocument = false
            }
            invalidateOriginalPDFPresence()
            originalPDFAdmissionAllowed = true
            restartOriginalPDFPresence()
            resetNativeTextInput()
            endNativeVideoPiP()
            if let committed, url != committed {
                url = committed; stateEvents?.page(self, changed: .url(committed))
            }
            committedURL = committed; events?.page(self, navigation: .committed(navigation))
        case "page.finished":
            guard !awaitingInitialDocument else { return }
            originalPDFAdmissionAllowed = true
            restartOriginalPDFPresence(force: originalPDFPresence.ready == nil)
            committedURL = url; events?.page(self, navigation: .finished(navigation))
            configureNativeStore()
        case "script.message":
            if p["world"]?.string == ChromiumStoreBridge.world, p["name"]?.string == ChromiumStoreBridge.binding,
               let tab = extensionTab, let browser = tab.delegate as? Browser,
               ChromiumStoreBridge.accepts(url), ChromiumStoreBridge.accepts(tab.address) {
                let value = p["value"] ?? .null
                if value["add"] == .bool(true) { browser.addFromStore(tab) }
                if let placed = value["placed"].string { tab.storePlaced = placed }
            } else {
                // The find bar's live count (yabFindChanged) shares this event.
                receiveNavigation(event)
            }
        case "page.loadError":
            lastLoadError = ["code": p["code"]?.number ?? 0, "message": p["message"]?.string ?? "", "url": p["url"]?.string ?? ""]
            // CEF ERR_ABORTED is a stopped/superseded load.
            if p["code"]?.number != -3 { failed(YabCoreError.remote(p["message"]?.string ?? "Chromium load failed")) }
        case "page.responsive":
            if let report = ChromiumResponsiveness(p, rendererPID: contentProcess) {
                events?.page(self, responsive: report.responsive)
            }
        case "page.crash":
            questionRequests.cancel()
            resetNativeTextInput()
            swipe.invalidate()
            fileRequests.cancel()
            if let ended = onDocumentClosed { onDocumentClosed = nil; ended(); return }
            cancelNativePrint()
            nativeFindEpoch += 1; nativeFindTask?.cancel()
            contentProcess = nil
            mediaEnded()
            contextID = 0; remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
            resetGeometry()
            isLoading = false; stateEvents?.page(self, changed: .loading(false))
            events?.page(self, ended: p["status"]?.number == 3 ? .memory : .crash)
        case "layer.changed":
            resizeState.surface(p)
            extensionPageOffset = CGPoint(x: -(p["pageX"]?.number ?? 0), y: -(p["pageY"]?.number ?? 0))
            CATransaction.begin(); CATransaction.setDisableActions(true)
            remoteParent.frame = resizeState.frame(in: bounds)
            remoteLayer?.position = extensionPageOffset
            CATransaction.commit()
            let id = UInt32(p["contextId"]?.number ?? 0)
            guard id != contextID else { return }
            contextID = id
            CATransaction.begin(); CATransaction.setDisableActions(true)
            remoteLayer?.removeFromSuperlayer(); remoteLayer = nil
            if id != 0, let type = NSClassFromString("CALayerHost") as? CALayer.Type {
                let hosted = type.init()
                hosted.setValue(NSNumber(value: id), forKey: "contextId")
                hosted.anchorPoint = .zero; hosted.position = extensionPageOffset; hosted.bounds = .zero
                remoteParent.addSublayer(hosted); remoteLayer = hosted
            }
            CATransaction.commit()
        case "tab.resized":
            if resizeState.receive(p) {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                remoteParent.frame = resizeState.frame(in: bounds)
                CATransaction.commit()
            }
        case "media.pip.changed": receiveNativeVideoPiP(p)
        case "page.textInput":
            receiveNativeTextInput(p)
        case "select.open":
            receiveSelect(p)
        case "select.closed":
            closeSelect(p)
        case "popup.layer":
            receivePopup(p)
        case "tab.extensionCreated":
            receiveExtensionTab(p)
        case "tab.extensionActivate":
            if let tab, let browser = tab.delegate as? Browser { browser.select(tab) }
        case "download.open":
            receiveDownload(p)
        case "question.open":
            receiveQuestion(event.params)
        case "question.closed":
            receiveQuestionClosed(event.params)
        case "menu.open":
            receiveMenu(p)
        case "print.request":
            receiveNativePrint(p)
        case "print.withdrawn":
            if p["request"]?.string == nativePrintRequestID { cancelNativePrint() }
        case "dialog.open", "file.open", "file.closed":
            receiveNavigation(event)
        default: receiveMedia(event)
        }
    }
    private func updateSurface() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // AppKit may replace a backing layer when the view changes windows.
        if remoteParent.superlayer !== layer { layer?.addSublayer(remoteParent) }
        remoteParent.frame = resizeState.frame(in: bounds)
        CATransaction.commit()
        syncGeometry()
        if originalPDFPresence.owner == nil { restartOriginalPDFPresence() }
        presentOriginalPDFPresence()
    }
    func extensionHostState() async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        return try await core.request("tab.state", params: ["tab": .string(id)])
    }
    /// Isolate a blocked store bridge from a blocked renderer in farm probes.
    func extensionDocumentProbe(_ expression: String) async throws -> JSONValue {
        guard Store.testing else { throw YabCoreError.remote("Extension diagnostics require a test world") }
        let (core, id) = try await endpoint()
        return try await core.request("script.document", params: ["tab": .string(id), "expression": .string(expression)])
    }
    /// The extension's button pressed on this page, through Chrome's
    /// original action runner (patches 0018/0030): false when this helper
    /// has no such hook or Chrome refused, so the caller can fall back.
    func openExtensionAction(_ extensionID: String) async -> Bool {
        guard let (core, id) = try? await endpoint() else { return false }
        let anchor: JSONValue = .object(["x": .number(max(0, Double(bounds.width) - 40)), "y": .number(0),
                                         "width": .number(32), "height": .number(32)])
        do {
            let reply = try await core.request("extension.action.open",
                                               params: ["tab": .string(id), "extension": .string(extensionID), "anchor": anchor])
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.action.open \(extensionID) -> \(reply)\n".utf8)) }
            return reply["opened"] == .bool(true)
        } catch {
            if Store.testing { FileHandle.standardError.write(Data("yab: extension.action.open \(extensionID) failed: \(error)\n".utf8)) }
            extensions.failure = "action: \(error.localizedDescription)"
            return false
        }
    }
    func extensionActionState(press name: String? = nil) async throws -> JSONValue {
        await tail?.value
        let (core, id) = try await endpoint()
        var params: [String: JSONValue] = ["tab": .string(id)]
        if let name { params["name"] = .string(name) }
        return try await core.request(name == nil ? "extension.actions" : "extension.pressAction", params: params)
    }
    private func configureNativeStore() {
        guard ChromiumStoreBridge.accepts(url), !privateMode else { return }
        if Store.testing, ProcessInfo.processInfo.environment["YAB_TEST_NO_STORE_BRIDGE"] == "1" { return }
        enqueue { core, id in
            _ = try await core.request("script.bind", params: ["tab": .string(id), "world": .string(ChromiumStoreBridge.world), "name": .string(ChromiumStoreBridge.binding)])
            _ = try await core.evaluate(tab: id, world: ChromiumStoreBridge.world,
                                       function: "function(){\(ChromiumStoreBridge.script)}", arguments: .null)
        }
        extensions.perform { [weak self] in
            guard let self else { return }
            _ = try await self.extensions.list()
            self.tellNativeStore()
        }
    }
    private func tellNativeStore() {
        guard ChromiumStoreBridge.accepts(url) else { return }
        let state: JSONValue = .object(["installed": .array(extensions.items.map { .string($0.id) }),
                                        "busy": extensions.busy ? Crx.id(in: url?.absoluteString ?? "").map(JSONValue.string) ?? .null : .null])
        enqueue { core, id in
            _ = try await core.evaluate(tab: id, world: ChromiumStoreBridge.world,
                                       function: "function(state){window.__yabStore?.state(state)}", arguments: state)
        }
    }
    override func layout() { super.layout(); updateSurface() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); updateSurface() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { hoverLeft() }
        updateSurface()
        watchKeyWindow()
        scripts.appearanceChanged()
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { DispatchQueue.main.async { [weak self] in self?.focusChanged() } }
        return accepted
    }
    override func viewDidHide() { super.viewDidHide(); hoverLeft(); syncGeometry(); focusChanged() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); scripts.appearanceChanged() }
    override func viewDidUnhide() { super.viewDidUnhide(); syncGeometry(); focusChanged() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateSurface() }
    var surfaceState: [String: Any] {
        ["rootFlipped": layer?.isGeometryFlipped ?? false,
         "rootClass": layer.map { String(describing: type(of: $0)) } ?? "",
         "parentAttached": remoteParent.superlayer === layer,
         "parentBounds": [remoteParent.bounds.minX, remoteParent.bounds.minY, remoteParent.bounds.width, remoteParent.bounds.height],
         "parentFlipped": remoteParent.isGeometryFlipped,
         "resizeNative": resizeState.native,
         "resizePending": resizeState.serial ?? "",
         "resizeAcknowledged": resizeState.acknowledged ?? "",
         "resizeCommitted": resizeState.committed.map { [$0.width, $0.height] } ?? [],
         "hostClass": remoteLayer.map { String(describing: type(of: $0)) } ?? "",
         "hostBounds": remoteLayer.map { [$0.bounds.minX, $0.bounds.minY, $0.bounds.width, $0.bounds.height] } ?? [],
         "opacity": layer?.opacity ?? 0, "hidden": isHiddenOrHasHiddenAncestor,
         "lastReadiness": lastReadiness, "lastLoadError": lastLoadError,
         "diagnosticFailure": diagnosticFailure ?? ""]
    }
    private var currentGeometry: ChromiumResize.Geometry {
        ChromiumResize.Geometry(size: bounds.size, scale: Double(window?.backingScaleFactor ?? 1),
                                visible: window != nil && !isHiddenOrHasHiddenAncestor)
    }
    private func resetGeometry() {
        resizeState = ChromiumResize()
        desiredGeometry = nil; sentGeometry = nil
        geometryQueued = false
        layer?.backgroundColor = nil
    }
    private func sendGeometry(_ core: YabCoreClient, _ id: String, _ geometry: ChromiumResize.Geometry) async throws {
        let token = resizeState.request(geometry)
        let result = try await core.request("tab.resize", params: ["tab": .string(id), "serial": .string(token),
            "width": .number(geometry.size.width), "height": .number(geometry.size.height), "scale": .number(geometry.scale)])
        if result["resizeAck"] != .bool(true) { resizeState.unsupported(token) }
        _ = try await core.request("tab.visible", params: ["tab": .string(id), "visible": .bool(geometry.visible)])
        sentGeometry = geometry
    }
    private func syncGeometry() {
        guard remoteID != nil, !retired else { return }
        desiredGeometry = currentGeometry
        guard !geometryQueued, desiredGeometry != sentGeometry else { return }
        geometryQueued = true
        enqueue { [weak self] core, id in
            guard let self else { return }
            defer { self.geometryQueued = false }
            while self.remoteID == id, let geometry = self.desiredGeometry, geometry != self.sentGeometry {
                try await self.sendGeometry(core, id, geometry)
            }
        }
    }
    private func applyZoom() {
        command("page.zoom", ["factor": .number(Double(pageZoom * magnification))])
    }

    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool,
                  done: (@MainActor (Result<Any?, Error>) -> Void)?) {
        Task { @MainActor in
            do { let value = try await evaluate(script, in: world, frame: frame, gesture: gesture); done?(.success(value)) }
            catch { done?(.failure(error)) }
        }
    }
    func evaluate(_ script: PageCode, in world: PageWorld, frame: PageFrame?, gesture: Bool) async throws -> Any? {
        let frameToken = try scripts.token(frame, tab: remoteID)
        await tail?.value
        let (core, id) = try await endpoint()
        let turn = documentTurn
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var proof: JSONValue
        while true {
            try Task.checkCancellation()
            guard !retired, remoteID == id, documentTurn == turn, tab?.chromiumProfile == profile else { throw CancellationError() }
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else {
                throw YabCoreError.remote("Document is at \(lastReadiness["url"] as? String ?? "?"), script target is \(scriptTarget?.absoluteString ?? "none")")
            }
            proof = try await core.waitForDocument(tab: id, profile: profile, timeout: seconds)
            lastReadiness = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))) as? [String: Any] ?? [:]
            guard !retired, remoteID == id, documentTurn == turn, tab?.chromiumProfile == profile else { throw CancellationError() }
            if scriptTarget == nil || proof["url"].string == scriptTarget?.absoluteString { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        lastReadiness = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(proof))) as? [String: Any] ?? [:]
        let body: String, args: JSONValue
        switch script {
        case .expression(let source):
            let data = try JSONSerialization.data(withJSONObject: source, options: [.fragmentsAllowed])
            body = "return (0,eval)(\(String(decoding: data, as: UTF8.self)));"; args = .object([:])
        case .function(let source, let arguments):
            guard arguments.keys.allSatisfy({ $0.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil }) else {
                throw YabCoreError.remote("Invalid JavaScript argument name")
            }
            body = "const {\(arguments.keys.sorted().joined(separator: ","))}=args;\n" + source
            args = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: arguments))
        }
        // Preserve undefined versus JSON null across wire v1.
        let function = "async function(args){const value=await(async()=>{\(body)})();return value===undefined?{absent:true}:{value};}"
        let result: JSONValue
        if let frameToken {
            result = try await core.request("scripts.evaluate", params: ["tab": .string(id), "frame": .string(frameToken),
                "world": .string(ChromiumScripts.world(world)), "function": .string(function), "arguments": args, "userGesture": .bool(gesture)])
        } else { switch world {
        case .page:
            let data = try JSONEncoder().encode(args)
            result = try await core.request("script.document", params: ["tab": .string(id), "userGesture": .bool(gesture),
                "document": proof,
                "expression": .string("(\(function))(\(String(decoding: data, as: UTF8.self)))")])
        case .client, .named:
            let name: String
            if case .named(let value) = world { name = "yab-world-" + value } else { name = "yab-client" }
            result = try await core.request("script.evaluate", params: ["tab": .string(id), "world": .string(name),
                "function": .string(function), "arguments": args, "userGesture": .bool(gesture), "document": proof])
        }
        }
        guard !retired, remoteID == id, documentTurn == turn else { throw CancellationError() }
        if result["absent"] == .bool(true) { return nil }
        return try JSONSerialization.jsonObject(with: JSONEncoder().encode(result["value"]), options: [.fragmentsAllowed])
    }
    func snapshot(_ shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) {
        Task { @MainActor in
            do {
                await tail?.value
                let (core, id) = try await endpoint()
                let turn = documentTurn, size = bounds.size, zoom = pageZoom, magnify = magnification
                let location = url, scroll = tab?.lastY
                let rect = shot.rect ?? CGRect(origin: .zero, size: size)
                guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { throw PageShotFailed() }
                let proof = try await core.waitForDocument(tab: id, profile: profile, timeout: 10)
                let value = try await core.request("page.snapshot", params: ["tab": .string(id), "document": proof])
                guard !retired, remoteID == id, documentTurn == turn, bounds.size == size,
                      pageZoom == zoom, magnification == magnify, url == location, tab?.lastY == scroll else { throw PageShotFailed() }
                guard let encoded = value["data"].string, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else { throw PageShotFailed() }
                image.size = size
                let width = shot.width ?? rect.width
                guard width > 0, width.isFinite else { throw PageShotFailed() }
                let output = NSImage(size: NSSize(width: width, height: width * rect.height / rect.width))
                output.lockFocus()
                // PageShot uses the page's top-left coordinates. NSImage's
                // source rectangle starts at the bottom of the bitmap.
                let source = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
                image.draw(in: NSRect(origin: .zero, size: output.size), from: source, operation: .copy, fraction: 1)
                output.unlockFocus()
                done(output, nil)
            } catch { done(nil, error) }
        }
    }
    func pdf(rect: CGRect?, done: @escaping @MainActor (Result<Data, Error>) -> Void) {
        WebKitOnly.note("PDF export", engine: .chromium)
        done(.failure(YabCoreError.remote("PDF is not supported in Chromium dev tabs")))
    }
    // TODO(chromium): process/media control, permissions, downloads, find,
    // print, PiP and authenticated child-frame/message relays.
    func setCameraCapture(_ state: PageMediaState) { WebKitOnly.note("Camera capture control", engine: .chromium) }
    func setMicrophoneCapture(_ state: PageMediaState) { WebKitOnly.note("Microphone capture control", engine: .chromium) }
    func stopDisplayCapture() {
        guard media.nativeCaptureKnown else { WebKitOnly.note("Display capture control", engine: .chromium); return }
        stopNativeCapture(kind: "screen")
    }
    func setAudioMuted(_ muted: Bool) {
        desiredAudioMuted = muted
        command("media.mute", ["muted": .bool(muted)])
    }
    func killContent() {
        guard let remoteID, let pid = contentProcess else { return }
        ChromiumProcess.shared.endRenderer(tab: remoteID, pid: pid)
    }

    private func input(_ kind: String, _ fields: [String: JSONValue] = [:]) {
        lastInput = ProcessInfo.processInfo.systemUptime
        if let tab = navigationTab, tab.builtPage === self, tab.deaf != nil,
           let browser = tab.delegate as? Browser { browser.reachedDeaf(tab) }
        if ["mouseDown", "rightDown", "mouseDrag", "wheel", "keyDown", "text"].contains(kind) { pageCopyTurn &+= 1 }
        if ["mouseDown", "rightDown", "keyDown", "text"].contains(kind) {
            RelayGuard.felt(self)
            AgentFeed.shared.person(self)
        }
        var p = fields; p["kind"] = .string(kind)
        if ["text", "compose", "unmark"].contains(kind) {
            // A queued IME operation cannot cross a known local document,
            // focus or helper transition. This is not the native focused-
            // document lease, which the current helper does not expose.
            let ticket = ChromiumInputMethodTicket()
            inputMethodTicket = ticket
            guard inputMethodLive, let remote = remoteID,
                  let core = ChromiumProcess.shared.connectedClient,
                  let focus = ChromiumNativeTextInput.focusToken(nativeText),
                  inputMethodFocused else { ticket.result = .refused; return }
            let generation = inputMethodGeneration, turn = documentTurn, epoch = operationEpoch
            let previous = tail
            // Unlike ordinary navigation, IME must never construct an endpoint.
            tail = Task { @MainActor [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.inputMethodLive,
                      ChromiumProcess.shared.isCurrent(core), self.remoteID == remote,
                      self.operationEpoch == epoch, self.inputMethodGeneration == generation,
                      self.documentTurn == turn, self.inputMethodFocused,
                      ChromiumNativeTextInput.focusToken(self.nativeText) == focus else { ticket.result = .refused; return }
                var params = p; params["tab"] = .string(remote)
                do {
                    _ = try await core.request("input.send", params: params)
                    self.inputMethodDispatched &+= 1
                    ticket.result = .dispatched
                } catch {
                    ticket.result = .unknown
                    if self.inputMethodLive, self.operationEpoch == epoch { self.failed(error) }
                }
            }
        } else { command("input.send", p) }
    }
    private func pagePoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: bounds.height - p.y)
    }
    private func pointer(_ kind: String, _ event: NSEvent) {
        let p = pagePoint(event)
        input(kind, ["x": .number(p.x), "y": .number(p.y), "clickCount": .number(Double(event.clickCount)), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); pointer("mouseDown", event) }
    override func mouseUp(with event: NSEvent) { pointer("mouseUp", event) }
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        receivePressure(stage: event.stage, amount: CGFloat(event.pressure),
                        point: CGPoint(x: point.x, y: bounds.height - point.y))
    }
    override func mouseMoved(with event: NSEvent) { hoverMoved(); pointer("mouseMove", event) }
    override func mouseDragged(with event: NSEvent) { hoverMoved(); pointer("mouseDrag", event) }
    override func mouseExited(with event: NSEvent) { hoverLeft() }
    override func rightMouseDown(with event: NSEvent) { pointer("rightDown", event) }
    override func rightMouseUp(with event: NSEvent) { pointer("rightUp", event) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 3 {
            stepButton = 3
            if canGoBack || navigationTab?.backSourceAvailable == true { swipe.step(forward: false, swipe: false, at: event.timestamp) }
        } else if event.buttonNumber == 4, canGoForward {
            stepButton = 4
            swipe.step(forward: true, swipe: false, at: event.timestamp)
        } else { super.otherMouseDown(with: event) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if stepButton == event.buttonNumber { stepButton = nil }
        else { super.otherMouseUp(with: event) }
    }
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 {
            if canGoBack || navigationTab?.backSourceAvailable == true { swipe.step(forward: false, swipe: true, at: event.timestamp) }
            else if let tab = navigationTab, tab.fromTitle?(tab) != nil { tab.onFrom?(tab) }
            else { super.swipe(with: event) }
        } else if event.deltaX < 0, canGoForward { swipe.step(forward: true, swipe: true, at: event.timestamp) }
        else { super.swipe(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        hoverScrolled()
        if event.phase == .began || event.phase == .mayBegin { ScrollLatch.hold(self) }
        WheelLatch.hold(self, event)
        navigationTab?.uncover()
        if let tab = navigationTab { tab.onSelectionTouch?(tab) }
        swipe.receive(event)
    }
    func sendWheel(_ event: NSEvent) {
        let p = pagePoint(event)
        input("wheel", ["x": .number(p.x), "y": .number(p.y), "deltaX": .number(event.scrollingDeltaX),
            "deltaY": .number(event.scrollingDeltaY), "phase": .number(Double(ChromiumWheelPhase.gesture(event.phase))),
            "momentumPhase": .number(Double(ChromiumWheelPhase.momentum(event.momentumPhase))), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
    override func keyDown(with event: NSEvent) {
        // Escape gives a page's full screen back, as in Chromium and Safari.
        if event.keyCode == 53, media.fullscreen { exitPageFullscreen(); return }
        if !composeKey(event) && !takeEditingKey(event) { key("keyDown", event) }
    }
    override func keyUp(with event: NSEvent) {
        let composed = imeKeys.remove(event.keyCode) != nil
        let edited = editingKeyCodes.remove(event.keyCode) != nil
        if !composed && !edited { key("keyUp", event) }
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            editingKeyCodes.removeAll()
            discardNativeComposition()
            syncRemoteFocus(resigning: true)
            DispatchQueue.main.async { [weak self] in self?.scripts.appearanceChanged() }
        }
        return resigned
    }
    private func key(_ kind: String, _ event: NSEvent) {
        input(kind, ["keyCode": .number(Double(event.keyCode)), "characters": .string(event.characters ?? ""), "unmodified": .string(event.charactersIgnoringModifiers ?? ""), "repeat": .bool(event.isARepeat), "modifiers": .number(Double(event.modifierFlags.rawValue))])
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        imeHandled = true
        marked = NSAttributedString(string: "")
        textEdit(.insert(text, replacing: replacementRange))
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let starting = marked.length == 0
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        imeHandled = true
        // A replaced range is where the words go (a held letter marked in
        // place); a new composition starts at the selection.
        if replacementRange.location != NSNotFound { markedStart = replacementRange.location }
        else if starting { markedStart = nativeRange("selection")?.location ?? NSNotFound }
        let selected = selectedRange.location == NSNotFound ? NSRange(location: marked.length, length: 0) : selectedRange
        textEdit(.mark(marked.string, selected: selected, replacing: replacementRange))
    }
    func unmarkText() {
        guard marked.length > 0 else { return }
        marked = NSAttributedString(string: ""); textEdit(.unmark)
    }
    /// While a key is being read the edit waits for the key's route; any
    /// other time (a candidate clicked, the accent menu's pick, the
    /// Character Viewer, dictation) it goes to the page at once.
    private func textEdit(_ edit: ChromiumKeyInterpretation.Edit) {
        if keyInterpretation != nil { keyInterpretation?.edits.append(edit) } else { sendTextEdit(edit) }
    }
    /// An edit reaches the page's own text input client as AppKit gave it,
    /// with the range it replaces: a held letter's accent replaces the
    /// letter already typed.
    func sendTextEdit(_ edit: ChromiumKeyInterpretation.Edit) {
        switch edit {
        case .insert(let text, let range):
            var fields: [String: JSONValue] = ["text": .string(text)]
            fields.merge(ChromiumNativeTextInput.replacementFields(range)) { $1 }
            input("text", fields)
        case .mark(let text, let selected, let range):
            var fields: [String: JSONValue] = ["text": .string(text), "selectionStart": .number(Double(selected.location)),
                                               "selectionLength": .number(Double(selected.length))]
            fields.merge(ChromiumNativeTextInput.replacementFields(range)) { $1 }
            input("compose", fields)
        case .unmark:
            input("unmark")
        }
    }
    func selectedRange() -> NSRange { nativeRange("selection") ?? NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        guard marked.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return nativeRange("composition") ?? NSRange(location: markedStart == NSNotFound ? 0 : markedStart, length: marked.length)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nativeSubstring(range, actualRange: actualRange) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { nativeFirstRect(range) }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) { keyInterpretation?.commands += 1 }
    private func agentInput(_ kind: String, _ fields: [String: JSONValue] = [:]) {
        var fields = fields; fields["kind"] = .string(kind)
        command("scripts.input", fields)
    }
    private func cdpModifiers(_ flags: NSEvent.ModifierFlags) -> Double {
        Double((flags.contains(.option) ? 1 : 0) | (flags.contains(.control) ? 2 : 0) |
               (flags.contains(.command) ? 4 : 0) | (flags.contains(.shift) ? 8 : 0))
    }
    func agentClick(x: Double, y: Double, flags: NSEvent.ModifierFlags) -> Bool {
        guard !retired, x.isFinite, y.isFinite else { return false }
        let fields: [String: JSONValue] = ["x": .number(x), "y": .number(y), "modifiers": .number(cdpModifiers(flags)), "clickCount": .number(1), "button": .string("left")]
        window?.makeFirstResponder(self)
        agentInput("mouseMoved", ["x": .number(x), "y": .number(y)])
        agentInput("mousePressed", fields); agentInput("mouseReleased", fields); return true
    }
    func agentHover(x: Double, y: Double) -> Bool {
        guard !retired, x.isFinite, y.isFinite else { return false }
        agentInput("mouseMoved", ["x": .number(x), "y": .number(y)]); return true
    }
    func agentDrag(from: CGPoint, to: CGPoint, done: @escaping @MainActor (Bool) -> Void) {
        guard !retired, [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite) else { done(false); return }
        agentInput("mouseMoved", ["x": .number(from.x), "y": .number(from.y)])
        agentInput("mousePressed", ["x": .number(from.x), "y": .number(from.y), "button": .string("left"), "clickCount": .number(1)])
        agentInput("mouseMoved", ["x": .number(to.x), "y": .number(to.y), "button": .string("left"), "buttons": .number(1)])
        agentInput("mouseReleased", ["x": .number(to.x), "y": .number(to.y), "button": .string("left"), "clickCount": .number(1)])
        Task { @MainActor in await tail?.value; done(true) }
    }
    func insertAgentText(_ text: String) { agentInput("text", ["text": .string(text)]) }
    func sendAgentKeys(_ strokes: [PageKey]) {
        for stroke in strokes {
            agentInput("key", ["keyCode": .number(Double(stroke.keyCode)), "nativeCode": .number(Double(stroke.code)),
                               "key": .string(stroke.key), "code": .string(stroke.domCode), "text": .string(stroke.text),
                               "modifiers": .number(cdpModifiers(stroke.flags))])
        }
    }
}
