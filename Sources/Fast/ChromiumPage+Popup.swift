import AppKit
import YabCoreClient

/// An extension action popup (Dark Reader's, for one) that Chromium opened for
/// this page. Chromium names its identity when the action fires: the owner
/// page, the extension and a token. The popup's own compositor is hosted by
/// the client beside its extension button; input goes back to that exact popup.
@MainActor
final class ChromiumExtensionPopup {
    let token: String
    let extensionID: String
    private(set) var contextID: UInt32 = 0
    private(set) var pointSize: CGSize = .zero
    private(set) var scale: CGFloat = 1
    private weak var page: ChromiumPage?
    private let client: YabCoreClient?
    private let owner: String?
    let layer = CALayer()
    private var host: CALayer?
    private var inputTail: Task<Void, Never>?
    private(set) var closed = false

    init(token: String, extensionID: String, page: ChromiumPage) {
        self.token = token; self.extensionID = extensionID; self.page = page
        client = ChromiumProcess.shared.connectedClient
        owner = page.remoteID
        layer.anchorPoint = .zero
        layer.isGeometryFlipped = true
    }

    /// Frame event: the popup compositor's context, pixel size and scale.
    func update(_ frame: ChromiumPopupPacket.Frame) {
        guard !closed else { return }
        let id = frame.context
        scale = CGFloat(frame.scale)
        pointSize = CGSize(width: frame.width, height: frame.height)
        layer.bounds = CGRect(origin: .zero, size: pointSize)
        guard id != contextID else { return }
        contextID = id
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host?.removeFromSuperlayer(); host = nil
        if id != 0, let type = NSClassFromString("CALayerHost") as? CALayer.Type {
            let hosted = type.init()
            hosted.setValue(NSNumber(value: id), forKey: "contextId")
            hosted.anchorPoint = .zero; hosted.position = .zero; hosted.bounds = .zero
            layer.addSublayer(hosted); host = hosted
        }
        CATransaction.commit()
    }

    /// A real AppKit event for the popup, in its own point space (top-left).
    func send(_ fields: [String: JSONValue]) {
        guard !closed, let client, ChromiumProcess.shared.isCurrent(client),
              let owner, let page, page.remoteID == owner, page.extensionPopup === self,
              let tab = page.navigationTab, !tab.gone,
              (tab.delegate as? Browser)?.activeID == tab.id else { return }
        var params = fields; params["token"] = .string(token)
        params["tab"] = .string(owner)
        let previous = inputTail
        inputTail = Task { @MainActor [weak self, weak page] in
            await previous?.value
            guard let self, !self.closed, ChromiumProcess.shared.isCurrent(client),
                  let page, page.remoteID == owner, page.extensionPopup === self,
                  let tab = page.navigationTab, !tab.gone,
                  (tab.delegate as? Browser)?.activeID == tab.id else { return }
            _ = try? await client.request("popup.input", params: params)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        inputTail?.cancel(); inputTail = nil
        host?.removeFromSuperlayer(); host = nil
        guard let client, let owner else { return }
        Task { @MainActor in
            guard ChromiumProcess.shared.isCurrent(client) else { return }
            _ = try? await client.request("popup.close", params: ["tab": .string(owner), "token": .string(token)])
        }
    }
}

extension ChromiumPage {
    /// popup.layer: shown, frame or closed. `onExtensionPopup` hears every change
    /// (nil when the popup closed) so the button's UI can host or drop its layer.
    func receivePopup(_ p: [String: JSONValue]) {
        guard let packet = ChromiumPopupPacket(p, profile: profile) else {
            if Store.testing { FileHandle.standardError.write(Data("yab: popup.layer refused \(p["state"]?.string ?? "") event profile \(p["profile"]?.string ?? "-") page profile \(profile) token \(String(describing: p["token"])) extension \(String(describing: p["extensionId"])) same-profile \(p["profile"]?.string == profile) state-ok \(p["state"]?.string.flatMap(ChromiumPopupPacket.State.init(rawValue:)) != nil) bytes \(Array((p["profile"]?.string ?? "").utf8).count)/\(Array(profile.utf8).count)\n".utf8)) }
            return
        }
        if Store.testing { FileHandle.standardError.write(Data("yab: popup.layer \(packet.state) \(packet.extensionID)\n".utf8)) }
        let token = packet.token, id = packet.extensionID
        if let current = extensionPopup, current.token == token {
            guard current.extensionID == id else { return }
            // A native close or rejected host retired this original object.
            // Later frames cannot reattach its compositor or input queue.
            if packet.state != .closed && current.closed { return }
        }
        switch packet.state {
        case .closed:
            guard let current = extensionPopup, current.token == token, current.extensionID == id else { return }
            current.close()
            extensionPopup = nil
            onExtensionPopup?(nil)
            ChromiumPopupHost.shared.nativeClosed(token)
        case .shown, .frame:
            let popup: ChromiumExtensionPopup
            if let current = extensionPopup, current.token == token { popup = current }
            else { popup = ChromiumExtensionPopup(token: token, extensionID: id, page: self); extensionPopup = popup }
            if let frame = packet.frame { popup.update(frame) }
            onExtensionPopup?(popup)
            ChromiumPopupHost.shared.receive(popup, page: self)
        }
    }

    /// chrome.tabs.create from an extension: its requested foreground state,
    /// index and opener, with the new page's identity (event tab).
    func receiveExtensionTab(_ p: [String: JSONValue]) {
        // The event is already scoped to this endpoint by receive(_:).
        // Recheck it here as well: an inert/retired page has no runtime owner.
        guard let remoteID, let value = ExtensionTabRequest(p, remoteID: remoteID, profile: profile) else { return }
        onExtensionTabCreated?(value)
    }
}

struct ExtensionTabRequest: Sendable {
    let active: Bool
    /// -1 for the default position.
    let index: Int
    let opener: String?
    let extensionID: String?

    init?(_ p: [String: JSONValue], remoteID: String, profile: String) {
        guard !remoteID.isEmpty, !profile.isEmpty, p["tab"]?.string == remoteID,
              let id = p["extensionId"]?.string, id.utf8.count == 32,
              id.utf8.allSatisfy({ $0 >= 97 && $0 <= 112 }),
              case .bool(let active)? = p["active"] else { return nil }
        // Older native creation notifications omit profile. Their exact
        // authenticated endpoint remains mandatory; an explicit foreign or
        // malformed profile can never override it.
        if let supplied = p["profile"], supplied != .string(profile) { return nil }
        let index: Int
        switch p["index"] {
        case nil, .null?: index = -1
        case .number(let number)?:
            // CEF's native creation index is a signed32-bit integer. -1
            // means default placement; large valid indexes are clamped to
            // the actual tab count by ChromiumTabAdoption, not converted
            // blindly here or used to create another browser.
            guard number.isFinite, number >= -1, number <= Double(Int32.max),
                  let exact = Int(exactly: number) else { return nil }
            index = exact
        default: return nil
        }
        let opener: String?
        switch p["openerTab"] {
        case nil, .null?: opener = nil
        case .string(let value)?:
            guard !value.isEmpty, value.utf8.count <= 256, value != remoteID,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            opener = value
        default: return nil
        }
        self.active = active; self.index = index; self.opener = opener; extensionID = id
    }
}
