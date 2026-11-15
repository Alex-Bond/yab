import AppKit
import YabCoreClient

/// A capability for the original native video player and its own compositor.
/// A page snapshot or a second media element cannot satisfy this contract.
struct ChromiumVideoPiPState: Equatable {
    let token: String
    let browserID: Int32
    let surfaceIdentity: String
    let document: String
    let frame: String
    let context: UInt32
    let canvas: CGSize
    let crop: CGRect
    let natural: CGSize
    let controlsKnown: Bool
    let paused: Bool
    let muted: Bool
    let position: Double
    let duration: Double?
    let rate: Double
    let canSeek: Bool
    let canRate: Bool
    let captionsAvailable: Bool
    let captionsEnabled: Bool

    init?(_ p: [String: JSONValue], profile: String) {
        func number(_ key: String, minimum: Double, maximum: Double) -> Double? {
            guard let n = p[key]?.number, n.isFinite, n >= minimum, n <= maximum else { return nil }
            return n
        }
        guard p["version"] == .number(1), p["kind"] == .string("video"), p["active"] == .bool(true),
              p["profile"] == .string(profile), p["surfaceReady"] == .bool(true),
              let browser = number("browserId", minimum: 1, maximum: Double(Int32.max)), browser.rounded() == browser,
              let token = p["token"]?.string, !token.isEmpty, token.utf8.count <= 256,
              let document = p["document"]?.string, !document.isEmpty, document.utf8.count <= 256,
              let frame = p["frameId"]?.string, !frame.isEmpty, frame.utf8.count <= 256,
              let surface = p["nativeSurface"]?.string, !surface.isEmpty, surface.utf8.count <= 256,
              let context = number("contextId", minimum: 1, maximum: Double(UInt32.max)), context.rounded() == context,
              let scale = number("scale", minimum: 0.25, maximum: 8),
              let width = number("pixelWidth", minimum: 1, maximum: 32768),
              let height = number("pixelHeight", minimum: 1, maximum: 32768),
              let x = number("videoX", minimum: 0, maximum: 32768),
              let y = number("videoY", minimum: 0, maximum: 32768),
              let w = number("videoWidth", minimum: 1, maximum: 32768),
              let h = number("videoHeight", minimum: 1, maximum: 32768),
              x + w <= width / scale + 1, y + h <= height / scale + 1,
              let nw = number("naturalWidth", minimum: 1, maximum: 32768),
              let nh = number("naturalHeight", minimum: 1, maximum: 32768),
              case .bool(let known)? = p["controlsKnown"] else { return nil }
        self.token = token; browserID = Int32(browser); surfaceIdentity = surface
        self.document = document; self.frame = frame
        self.context = UInt32(context)
        canvas = CGSize(width: width / scale, height: height / scale)
        crop = CGRect(x: x, y: y, width: w, height: h)
        natural = CGSize(width: nw, height: nh)
        controlsKnown = known
        if known {
            guard case .bool(let paused)? = p["paused"], case .bool(let muted)? = p["muted"],
                  let position = number("position", minimum: 0, maximum: Double(Int32.max)),
                  let rate = number("rate", minimum: 0, maximum: 64),
                  case .bool(let canSeek)? = p["canSeek"], case .bool(let canRate)? = p["canRate"],
                  case .bool(let captionsAvailable)? = p["captionsAvailable"],
                  case .bool(let captionsEnabled)? = p["captionsEnabled"] else { return nil }
            self.paused = paused; self.muted = muted; self.position = position; self.rate = rate
            self.canSeek = canSeek; self.canRate = canRate
            self.captionsAvailable = captionsAvailable; self.captionsEnabled = captionsEnabled
        } else {
            paused = true; muted = false; position = 0; rate = 1
            canSeek = false; canRate = false; captionsAvailable = false; captionsEnabled = false
        }
        duration = number("duration", minimum: position, maximum: Double(Int32.max))
    }

    var playhead: Floater.Playhead? {
        guard controlsKnown else { return nil }
        return Floater.Playhead([duration.map { $0 > 0 ? position / $0 : 0 } ?? 0, !paused,
            position, duration ?? 0, rate, Double(natural.width), Double(natural.height), !paused, muted] as [Any])
    }
}

@MainActor
final class ChromiumVideoPiPSurface: NSView {
    private var host: CALayer?
    private let canvas = CALayer()
    private var state: ChromiumVideoPiPState?
    var resized: ((CGSize) -> Void)?
    private var notifiedSize: CGSize?
    init() {
        super.init(frame: .zero); wantsLayer = true; layer?.masksToBounds = true
        canvas.isGeometryFlipped = true; canvas.anchorPoint = .zero
        layer?.addSublayer(canvas)
    }
    required init?(coder: NSCoder) { return nil }

    func update(_ state: ChromiumVideoPiPState) -> Bool {
        if self.state?.context != state.context {
            guard let type = NSClassFromString("CALayerHost") as? CALayer.Type else { return false }
            let replacement = type.init()
            replacement.setValue(NSNumber(value: state.context), forKey: "contextId")
            host?.removeFromSuperlayer(); host = replacement
            replacement.anchorPoint = .zero; replacement.bounds = .zero
            canvas.addSublayer(replacement)
        }
        self.state = state
        needsLayout = true
        return true
    }
    override func layout() {
        super.layout()
        guard let state, let host, bounds.width > 0, bounds.height > 0 else { return }
        if notifiedSize != bounds.size {
            notifiedSize = bounds.size
            resized?(bounds.size)
        }
        let scale = min(bounds.width / state.crop.width, bounds.height / state.crop.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Match ChromiumPage: the host's bounds stay zero; its flipped
        // parent scales the original context, cropped in top-left widget DIP.
        host.bounds = .zero; host.position = .zero
        canvas.bounds = CGRect(origin: .zero, size: state.canvas)
        canvas.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        canvas.position = CGPoint(x: (bounds.width - state.crop.width * scale) / 2 - state.crop.minX * scale,
                                  y: (bounds.height - state.crop.height * scale) / 2 - (state.canvas.height - state.crop.maxY) * scale)
        CATransaction.commit()
    }
}

/// The existing floating window holds only this original native video layer.
/// Commands never resolve a different DOM video when its token goes stale.
@MainActor
final class ChromiumVideoPiP {
    weak var page: ChromiumPage?
    weak var picture: SitePiP.Picture?
    let remote: String
    let core: YabCoreClient
    let surface = ChromiumVideoPiPSurface()
    private(set) var state: ChromiumVideoPiPState
    private var requestedReturn = false
    private var querySerial: UInt64 = 0
    private var resizing: Task<Void, Never>?
    private var lastRequestedSize: CGSize?
    var tab: Tab? { page?.navigationTab }
    var current: Bool {
        guard let page, let tab else { return false }
        return !tab.gone && tab.builtPage === page && page.remoteID == remote &&
            page.videoPiP === self && tab.chromiumProfile == page.profile && ChromiumProcess.shared.isCurrent(core)
    }
    init(page: ChromiumPage, remote: String, core: YabCoreClient, state: ChromiumVideoPiPState) {
        self.page = page; self.remote = remote; self.core = core; self.state = state
        surface.resized = { [weak self] size in self?.resize(to: size) }
    }
    func update(_ state: ChromiumVideoPiPState) -> Bool {
        guard self.state.token == state.token, self.state.browserID == state.browserID,
              self.state.surfaceIdentity == state.surfaceIdentity, self.state.document == state.document,
              self.state.frame == state.frame, surface.update(state) else { return false }
        self.state = state
        return true
    }
    /// Coalesce live window resizing, then resize the original native widget.
    /// The local layer follows immediately; only subsequent native geometry
    /// events/queries can confirm the compositor actually changed its canvas.
    private func resize(to size: CGSize) {
        guard current, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let wanted = CGSize(width: min(3840, max(120, size.width.rounded())),
                            height: min(2160, max(80, size.height.rounded())))
        guard wanted != lastRequestedSize else { return }
        resizing?.cancel()
        resizing = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
            guard let self, self.current, let page = self.page, !Task.isCancelled else { return }
            let token = self.state.token
            self.lastRequestedSize = wanted
            let reply = try? await self.core.request("media.pip.control", params: [
                "tab": .string(self.remote), "profile": .string(page.profile), "token": .string(token),
                "action": .string("resize"), "width": .number(wanted.width), "height": .number(wanted.height)], timeout: 2)
            guard self.current, self.state.token == token, !Task.isCancelled else { return }
            if reply?["dispatched"] != .bool(true) { self.lastRequestedSize = nil; return }
            _ = await self.refresh()
        }
    }
    func refresh() async -> ChromiumVideoPiPState? {
        guard current, let page else { return nil }
        let token = state.token, revision = page.nativeVideoPiPRevision
        querySerial &+= 1
        let serial = querySerial
        guard let value = try? await core.request("media.pip.state", params: ["tab": .string(remote), "profile": .string(page.profile)], timeout: 2),
              current, state.token == token else { return nil }
        // A newer native event or query owns the state, even for this same player.
        guard page.nativeVideoPiPRevision == revision, querySerial == serial else { return state }
        guard let object = value.object,
              let found = ChromiumVideoPiPState(object, profile: page.profile),
              found.token == token, update(found) else { return nil }
        return found
    }
    /// A dispatch receipt is not an applied control. Read the original native
    /// player state before answering the existing floating-window controls.
    func perform(_ action: String, values: [String: JSONValue] = [:]) async -> ChromiumVideoPiPState? {
        guard current, let page else { return nil }
        guard state.controlsKnown else { return nil }
        let token = state.token, originalPosition = state.position
        var params = values
        params["tab"] = .string(remote); params["profile"] = .string(page.profile)
        params["token"] = .string(token); params["action"] = .string(action)
        guard let reply = try? await core.request("media.pip.control", params: params, timeout: 2), reply["dispatched"] == .bool(true),
              current, state.token == token else { return nil }
        func applied(_ observed: ChromiumVideoPiPState) -> Bool {
            guard observed.controlsKnown else { return false }
            switch action {
            case "play": return !observed.paused
            case "pause": return observed.paused
            case "mute": return values["enabled"] == .bool(observed.muted)
            case "captions": return values["enabled"] == .bool(observed.captionsEnabled)
            case "rate": return values["rate"]?.number.map { abs(observed.rate - $0) < 0.001 } ?? false
            case "seek", "seekForward", "seekBackward":
                guard let seconds = values["seconds"]?.number else { return false }
                let target = action == "seek" ? seconds : originalPosition + (action == "seekForward" ? seconds : -seconds)
                let bounded = min(max(0, target), observed.duration ?? Double.greatestFiniteMagnitude)
                return abs(observed.position - bounded) <= 1
            default: return false
            }
        }
        for attempt in 0..<5 {
            guard current, state.token == token else { return nil }
            if let observed = await refresh(), applied(observed) { return observed }
            if attempt < 4 { try? await Task.sleep(for: .milliseconds(40 * (attempt + 1))) }
        }
        return nil
    }
    func close(returning: Bool = false) {
        guard current, let page else { return }
        requestedReturn = returning
        let token = state.token
        Task { @MainActor in
            guard self.current, self.state.token == token else { return }
            _ = try? await self.core.request("media.pip.control", params: ["tab": .string(self.remote),
                "profile": .string(page.profile), "token": .string(token), "action": .string(returning ? "return" : "close")])
        }
    }
    func ended(reason: String) {
        resizing?.cancel(); resizing = nil
        let source = tab
        source?.pictureInPicture = false
        picture?.gone?()
        if requestedReturn, reason == "return-requested", let source, !source.gone,
           source.builtPage === page { _ = BrowserWindows.shared.reveal(source.id); NSApp.activate(ignoringOtherApps: true) }
    }
}

extension ChromiumPage {
    func refreshNativeVideoPiP(core: YabCoreClient, remote: String, supported: Bool) {
        nativeVideoPiPKnown = supported
        guard supported else { return }
        let revision = nativeVideoPiPRevision
        Task { @MainActor [weak self] in
            guard let self, let response = try? await core.request("media.pip.state", params: ["tab": .string(remote), "profile": .string(self.profile)]),
                  self.remoteID == remote, ChromiumProcess.shared.isCurrent(core), self.nativeVideoPiPRevision == revision,
                  let object = response.object else { return }
            self.receiveNativeVideoPiP(object)
        }
    }
    func receiveNativeVideoPiP(_ p: [String: JSONValue]) {
        guard p["version"] == .number(1), p["kind"] == .string("video"), p["profile"] == .string(profile) else { return }
        nativeVideoPiPRevision &+= 1
        nativeVideoPiPKnown = true
        if p["active"] == .bool(false) {
            guard let existing = videoPiP, p["retiredToken"] == .string(existing.state.token),
                  p["retiredDocument"] == .string(existing.state.document) else { return }
            videoPiP = nil
            existing.ended(reason: p["reason"]?.string ?? "")
            return
        }
        guard let remote = remoteID, let core = ChromiumProcess.shared.connectedClient,
              let state = ChromiumVideoPiPState(p, profile: profile), let tab = navigationTab,
              !tab.gone, tab.builtPage === self, let browser = tab.delegate as? Browser else { return }
        if let existing = videoPiP, existing.update(state) { return }
        if let old = videoPiP { videoPiP = nil; old.ended(reason: "source-replaced") }
        let native = ChromiumVideoPiP(page: self, remote: remote, core: core, state: state)
        videoPiP = native
        guard native.update(state) else { native.close(); return }
        let picture = SitePiP.nativePicture(native, in: window, rect: convert(bounds, to: nil))
        native.picture = picture
        guard browser.take(picture) else { native.close(); return }
        tab.pictureInPicture = true
    }
    func endNativeVideoPiP() {
        nativeVideoPiPRevision &+= 1
        if let old = videoPiP { videoPiP = nil; old.ended(reason: "page-ended") }
    }
}
