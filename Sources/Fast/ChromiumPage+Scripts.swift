import AppKit
import YabCoreClient

/// Scripts and frame handles stay scoped to one helper tab and document.
@MainActor
final class ChromiumScripts {
    weak var page: ChromiumPage?
    weak var tab: Tab?
    private var arming: PageScripts.Arming?
    private var installed: [PageScriptRegistration]?
    private struct YouTubePolicy: Equatable {
        let enabled: Bool
        let paused: [String]

        @MainActor init() {
            enabled = Shield.shared.enabled
            paused = Shield.shared.paused.filter { YouTube.runs(on: $0) }.sorted()
        }

        @MainActor var source: String {
            // These are normalized site names, as PageScripts.host names them.
            let sites = String(decoding: try! JSONEncoder().encode(paused), as: UTF8.self)
            return "if (/^https?:$/.test(location.protocol) && (location.hostname === 'youtube.com' || location.hostname.endsWith('.youtube.com')) && !\(sites).includes(location.hostname.replace(/^www\\./, ''))) {\n" + YouTube.user.source + "\n}"
        }
    }
    private var installedYouTubePolicy: YouTubePolicy?
    /// Dark pages' ground for the renderer, and what each helper tab was
    /// last told (ChromiumPage+Dark.swift).
    var ground: NSColor?
    var applied: [String: JSONValue] = [:]
    static let featureRelays = [ScrollRelay.name, VeilRelay.name, ImageRelay.name, JSONRelay.name, MeasureRelay.name, ItemRelay.name, IconRelay.name, FormRelay.name, WalletRelay.name, StoreRelay.name, CallRelay.name, ShareRelay.name, DevRelay.name, RecordRelay.name, BadgeRelay.name, WatchRelay.name, FindRelay.name]

    private var probeRevision = 0
    private var probeHeld: [(tab: String, context: String, request: String)] = []
    private var replayProbe: Bool {
        Store.testing && ProcessInfo.processInfo.environment["YAB_CHROMIUM_SCRIPT_REPLAY_PROBE"] == "1"
    }

    func arm(css: String, host: String?) {
        arming = PageScripts.Arming(host: host, css: css)
        tab?.skipsAds = Shield.shared.skips(on: host)
        if installed != nil, installedYouTubePolicy != YouTubePolicy() {
            page?.refreshFeatureScripts()
        }
    }

    private final class FrameToken: NSObject {
        let owner: ObjectIdentifier
        let tab: String
        let context: String
        init(owner: ObjectIdentifier, tab: String, context: String) {
            self.owner = owner; self.tab = tab; self.context = context
        }
    }

    static func world(_ world: PageWorld) -> String {
        switch world {
        case .page: return ""
        case .client: return "yab-client"
        case .named(let name): return "yab-world-" + name
        }
    }

    func install(core: YabCoreClient, tab: String) async throws {
        installed = nil
        installedYouTubePolicy = nil
        applied = [:]
        // A tab with no URL has no DevTools agent until its first navigation:
        // the helper brings it up with a blank document and holds this
        // request until the agent is there (scripts.inc, ScriptWithAgent).
        try await prepare(core: core, tab: tab, url: self.tab?.address)
    }

    func prepare(core: YabCoreClient, tab: String, url: URL?) async throws {
        guard let owner = self.tab else { return }
        let host = PageScripts.host(of: url)
        let plan = arming.flatMap { $0.host == host ? $0 : nil }
            ?? PageScripts.Arming(host: host, css: (owner.delegate as? Browser)?.curtain.css(on: host) ?? "")
        // Client navigations install document-start scripts before Chrome's
        // navigation callbacks. Decide Shield for the destination now, as
        // WebKit's policy delegate does before its document starts.
        owner.skipsAds = Shield.shared.skips(on: host)
        // Dark pages decide before the request leaves, as Tab.arm does for
        // WebKit, and the renderer is told its scheme and ground first.
        if !LinkGap.cut("scripts") {
            await readExtensions()
            guard owner.builtPage === page else { throw CancellationError() }
            owner.darkArm(url: url, host: host)
        }
        try await applyAppearance(core: core, tab: tab)
        var registrations = LinkGap.cut("scripts") ? [] : PageScripts.chromium(for: owner, plan)
        let youtube = YouTubePolicy()
        // CDP registrations survive renderer-initiated navigation, including
        // an ordinary page's link to YouTube. Install the guarded policy on
        // every page while Shield is enabled, deciding the site synchronously
        // in the destination document before any player JSON is parsed.
        registrations.removeAll { $0.source == YouTube.user.source }
        if youtube.enabled, !LinkGap.cut("scripts") {
            registrations.append(PageScriptRegistration(source: youtube.source, world: .page, atEnd: false, mainOnly: true))
        }
        if LinkGap.cut("docstart") { registrations.removeAll { !$0.atEnd } }
        if LinkGap.cut("docend") { registrations.removeAll { $0.atEnd } }
        guard registrations != installed else { installedYouTubePolicy = youtube; return }
        let agent = Self.world(.agent)
        var definitions = registrations.map { registration in
            JSONValue.object(["world": .string(Self.world(registration.world)), "source": .string(registration.source),
                              "end": .bool(registration.atEnd), "mainOnly": .bool(registration.mainOnly)])
        }
        if Store.testing, ProcessInfo.processInfo.environment["YAB_CHROMIUM_SCRIPT_ORDER_PROBE"] == "1" {
            let first = Self.world(.named("script-order-a")), second = Self.world(.named("script-order-b"))
            for (world, source) in [
                (first, "globalThis.__yabOrderWorld=1;sessionStorage.setItem('__yabScriptOrder','a')"),
                (second, "sessionStorage.setItem('__yabScriptOrder',sessionStorage.getItem('__yabScriptOrder')+(typeof globalThis.__yabOrderWorld==='undefined'?'b':'X'))"),
                (first, "sessionStorage.setItem('__yabScriptOrder',sessionStorage.getItem('__yabScriptOrder')+(globalThis.__yabOrderWorld===1?'c':'X'))")
            ] {
                definitions.append(.object(["world": .string(world), "source": .string(source), "end": .bool(false), "mainOnly": .bool(true)]))
            }
        }
        let probeWorld = Self.world(.named("script-replay"))
        if replayProbe {
            definitions.append(.object(["world": .string(probeWorld), "source": .string("""
                if(!/^https?:$/.test(location.protocol))return;
                globalThis.__yabReplayCount=(globalThis.__yabReplayCount||0)+1;
                globalThis.__yabReplayAsk=()=>{
                    const calls=globalThis.__yabReplayCalls||(globalThis.__yabReplayCalls=[]);
                    const call={answer:'pending'};calls.push(call);
                    webkit.messageHandlers.yabReplayProbe.postMessage({})
                        .then(v=>call.answer=v,e=>call.answer=String(e));
                    return true;
                };
                if(window!==top)globalThis.__yabReplayAsk();
                """), "end": .bool(false), "mainOnly": .bool(false)]))
        }
        // The dark world is bound even while no engine is installed: a site
        // turned dark again gets its scripts without a reload (darkRefresh).
        var relays: [String: JSONValue] = [
            agent: .array([.string(FrameRelay.name)]),
            Self.world(.yab): .array(Self.featureRelays.map(JSONValue.string)),
            Self.world(DarkPages.pageWorld): .array([.string(DarkRelay.name)])]
        if replayProbe { relays[probeWorld] = .array([.string("yabReplayProbe")]) }
        _ = try await core.request("scripts.install", params: ["tab": .string(tab), "scripts": .array(definitions),
            "relays": .object(LinkGap.cut("relays") ? [:] : relays)])
        installed = registrations
        installedYouTubePolicy = youtube
    }

    func token(_ frame: PageFrame?, tab: String?) throws -> String? {
        guard let frame else { return nil }
        guard let token = frame.token as? FrameToken, token.owner == ObjectIdentifier(self), token.tab == tab else {
            throw PageEngineError.foreignFrame
        }
        return token.context
    }

    private func frame(_ value: JSONValue, tab: String) -> PageFrame? {
        guard let context = value["token"].string else { return nil }
        return PageFrame(isMain: value["main"] == .bool(true), url: value["url"].string.flatMap(URL.init(string:)),
                         token: FrameToken(owner: ObjectIdentifier(self), tab: tab, context: context),
                         origin: PageOrigin(scheme: value["scheme"].string ?? "", host: value["host"].string ?? "", port: Int(value["port"].number ?? 0)))
    }

    func frames(_ value: JSONValue, tab: String) -> [PageFrame] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { frame($0, tab: tab) }
    }

    func clearFrames() {
        guard let page else { return }
        AgentPage.frames.removeValue(forKey: ObjectIdentifier(page))
        if let tab { AgentPage.framed.removeValue(forKey: ObjectIdentifier(tab)) }
    }

    func status(_ done: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            do {
                guard let page else { return done(["error": "Page retired"]) }
                let (core, id) = try await page.endpoint()
                let value = try await core.request("scripts.status", params: ["tab": .string(id)])
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                done(["value": object, "features": ["count": self.tab?.count as Any? ?? NSNull(),
                     "draft": self.tab?.draft ?? false,
                     "image": self.tab?.pointedImage?.url.absoluteString ?? "",
                     "link": self.tab?.pointedLink?.url.absoluteString ?? "",
                     "linkShown": LinkStatus.shared.pointed?.url.absoluteString ?? "", "linkTold": LinkStatus.shared.told,
                     "hover": ["moved": self.page?.hoverCounts.moved ?? 0, "status": self.page?.hoverCounts.status ?? 0,
                               "last": self.page?.hoverCounts.last ?? "", "heard": self.page?.hoverCounts.heard ?? [], "admitted": self.page?.hoverAdmitted ?? false]]])
            } catch { done(["error": String(describing: error)]) }
        }
    }

    /// A fixed-purpose timing oracle, available only in an isolated farm world.
    func probeReplay(_ operation: String, done: @escaping ([String: Any]) -> Void) {
        guard replayProbe else { done(["error": "Replay probe is disabled"]); return }
        Task { @MainActor in
            do {
                guard let page else { throw PageEngineError.foreignFrame }
                let (core, id) = try await page.endpoint()
                switch operation {
                case "rearm":
                    probeRevision += 1
                    let host = PageScripts.host(of: self.tab?.address)
                    let css = arming?.host == host ? arming?.css ?? "" : ""
                    arm(css: css + "\n/* replay probe \(probeRevision) */", host: host)
                    try await prepare(core: core, tab: id, url: self.tab?.address)
                    done(["ok": true])
                case "release":
                    let held = probeHeld
                    probeHeld = []
                    for call in held where call.tab == id {
                        _ = try await core.request("scripts.reply", params: ["tab": .string(id), "frame": .string(call.context),
                            "request": .string(call.request), "value": .string("settled")])
                    }
                    done(["released": held.count])
                case "inspect", "ask":
                    let state = try await core.request("scripts.status", params: ["tab": .string(id)])
                    guard case .array(let contexts) = state["contexts"] else { throw PageEngineError.foreignFrame }
                    var values: [Any] = []
                    for context in contexts where context["world"].string == Self.world(.named("script-replay")) {
                        let source = operation == "ask" && context["main"] == .bool(false)
                            ? "function(){return globalThis.__yabReplayAsk()}"
                            : "function(){return {count:globalThis.__yabReplayCount,answer:globalThis.__yabReplayCalls?.[0]?.answer||null,lastAnswer:globalThis.__yabReplayCalls?.at(-1)?.answer||null,url:location.href,origin:location.origin,main:window===top}}"
                        let value = try await core.request("scripts.evaluate", params: ["tab": .string(id),
                            "frame": context["token"], "world": context["world"], "function": .string(source)])
                        var checked = value
                        if var object = value.object {
                            for (field, native) in [("nativeScheme", "scheme"), ("nativeHost", "host"), ("nativePort", "port"), ("nativeURL", "url"), ("nativeMain", "main")] {
                                object[field] = context[native]
                            }
                            checked = .object(object)
                        }
                        values.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(checked), options: [.fragmentsAllowed]))
                    }
                    done(["frames": values, "held": probeHeld.count])
                default: done(["error": "Unknown replay probe operation"])
                }
            } catch { done(["error": String(describing: error)]) }
        }
    }

    func receive(_ event: YabCoreEvent) {
        guard let page, let tab = event.tab, let frame = frame(event.params["frame"] ?? .null, tab: tab),
              let world = event.params["world"]?.string, let name = event.params["name"]?.string else { return }
        let body = event.params["value"] ?? .null
        if replayProbe, world == Self.world(.named("script-replay")), name == "yabReplayProbe",
           let request = event.params["request"]?.string, let context = event.params["frame"]?["token"].string {
            if probeHeld.count < 8 { probeHeld.append((tab, context, request)) }
            return
        }
        if world == Self.world(.agent), name == FrameRelay.name {
            if !frame.isMain {
                AgentPage.heard(page, AgentPage.Frame(info: frame, href: body["href"].string ?? "",
                                                    w: body["w"].number ?? 0, h: body["h"].number ?? 0))
            }
        } else if world == Self.world(DarkPages.pageWorld), name == DarkRelay.name, let owner = self.tab,
                  let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(body), options: [.fragmentsAllowed]) {
            owner.darkState.relay.tab = owner
            guard let request = event.params["request"]?.string, let context = event.params["frame"]?["token"].string else { return }
            owner.darkState.relay.receive(PageScriptMessage(body: object, frame: frame, sourceView: page)) { [weak self] value, error in
                self?.reply(tab: tab, context: context, request: request, value: value, error: error)
            }
            return
        } else if world == Self.world(.yab), let receiver = self.tab?.chromiumScriptReceiver(name),
                  let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(body), options: [.fragmentsAllowed]) {
            receiver.receive(PageScriptMessage(body: object, frame: frame, sourceView: page))
        } else { return }
        guard let request = event.params["request"]?.string, let context = event.params["frame"]?["token"].string else { return }
        Task {
            guard let (core, current) = try? await page.endpoint(), current == tab else { return }
            _ = try? await core.request("scripts.reply", params: ["tab": .string(tab), "frame": .string(context),
                "request": .string(request), "value": .null])
        }
    }

    /// A replying relay's answer, to the same live frame and request only.
    private func reply(tab: String, context: String, request: String, value: Any?, error: String?) {
        guard let page else { return }
        var params: [String: JSONValue] = ["tab": .string(tab), "frame": .string(context), "request": .string(request)]
        if let error { params["error"] = .string(error); params["value"] = .null }
        else {
            let data = value.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed]) }
            params["value"] = data.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) } ?? .null
        }
        Task {
            guard let (core, current) = try? await page.endpoint(), current == tab else { return }
            _ = try? await core.request("scripts.reply", params: params)
        }
    }
}
