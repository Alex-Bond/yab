import AppKit
import YabCoreClient

/// An extension action popup (Dark Reader's, for one) that Chromium opened for
/// this page. Chromium names its identity when the action fires: the owner
/// page, the extension and a token. The popup's own compositor is hosted by
/// the client beside its extension button; input goes back to that exact popup.
/// One line in a test world's log for each step of a popup's life.
func popupTrace(_ line: @autoclosure () -> String) {
    guard Store.testing else { return }
    let time = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    FileHandle.standardError.write(Data("yab popup \(time): \(line())\n".utf8))
}

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
    private var placement: (anchor: CGRect, size: CGSize, scale: CGFloat)?
    private(set) var closed = false
    /// The popup's focused field as YabCore last saw it (popup.textInput):
    /// whether it takes text and its caret, in the popup's points from its
    /// top left. Nil until the helper says, and from helpers that never do.
    private(set) var textInput: ChromiumPopupTextInput?

    init(token: String, extensionID: String, page: ChromiumPage) {
        self.token = token; self.extensionID = extensionID; self.page = page
        client = ChromiumProcess.shared.connectedClient
        owner = page.remoteID
        layer.anchorPoint = .zero
        layer.isGeometryFlipped = true
        // Its frame follows the popover's view (ChromiumPopupInput.fit) at
        // once, never in an animation of its own.
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
    }

    /// Frame event: the popup compositor's context, pixel size and scale.
    /// The size is the host's to apply (ChromiumPopupHost.receive): `layer`
    /// always fills the popover's view (ChromiumPopupInput.fit), never takes
    /// a size of its own ahead of it.
    func update(_ frame: ChromiumPopupPacket.Frame) {
        popupTrace("frame \(extensionID.prefix(6)) \(token.prefix(8)) context \(frame.context) pixels \(Int(frame.pixelWidth))x\(Int(frame.pixelHeight)) scale \(frame.scale) closed \(closed)")
        guard !closed else { return }
        let id = frame.context
        scale = CGFloat(frame.scale)
        pointSize = CGSize(width: frame.width, height: frame.height)
        guard id != contextID else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        contextID = id
        host?.removeFromSuperlayer(); host = nil
        if id != 0, let type = NSClassFromString("CALayerHost") as? CALayer.Type {
            let hosted = type.init()
            hosted.setValue(NSNumber(value: id), forKey: "contextId")
            hosted.anchorPoint = .zero; hosted.position = .zero; hosted.bounds = .zero
            layer.addSublayer(hosted); host = hosted
        }
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
            do { _ = try await client.request("popup.input", params: params) }
            catch { popupTrace("popup.input \(fields["kind"]?.string ?? "?") refused: \(error)") }
        }
    }

    func receiveTextInput(_ p: [String: JSONValue]) {
        guard !closed, let state = ChromiumPopupTextInput(p, token: token) else { return }
        textInput = state
        onTextInput?()
    }
    /// The popover's input view hears a new caret for the candidate window.
    var onTextInput: (() -> Void)?
    private(set) var cursor = NSCursor.arrow
    private(set) var cursorShape = "arrow"
    var onCursor: (() -> Void)?

    func receiveCursor(_ fields: [String: JSONValue]) {
        guard !closed, fields["token"]?.string == token,
              let data = fields["picture"]?.string.flatMap({ Data(base64Encoded: $0) }),
              let image = NSImage(data: data) else { return }
        if let w = fields["width"]?.number, let h = fields["height"]?.number,
           w.isFinite, h.isFinite, w > 0, h > 0, w <= 256, h <= 256 {
            image.size = NSSize(width: w, height: h)
        }
        cursor = NSCursor(image: image, hotSpot: NSPoint(x: fields["hotX"]?.number ?? 0, y: fields["hotY"]?.number ?? 0))
        cursorShape = fields["shape"]?.string ?? "custom"
        onCursor?()
    }

    /// Chromium's concealed widget goes to the screen the popover is on: its
    /// compositor draws at that window's scale, and a widget left on another
    /// display is enlarged, soft, in the popover. A resize puts the widget
    /// back at its bubble anchor, so this follows each new size.
    func place(under rect: CGRect, on screen: NSScreen?) {
        guard !closed, let client, let owner, ChromiumProcess.shared.isCurrent(client),
              let top = NSScreen.screens.first?.frame.maxY else { return }
        let x = screen.map { min(rect.minX, $0.frame.maxX - pointSize.width) } ?? rect.minX
        let target = CGRect(x: x, y: top - rect.maxY, width: rect.width, height: rect.height)
        if let placement, placement.anchor == target, placement.size == pointSize, placement.scale == scale { return }
        placement = (target, pointSize, scale)
        let anchor: JSONValue = .object(["x": .number(x), "y": .number(top - rect.maxY),
                                         "width": .number(rect.width), "height": .number(rect.height)])
        Task { @MainActor in
            do { _ = try await client.request("popup.anchor", params: ["tab": .string(owner), "token": .string(token), "anchor": anchor]) }
            catch { popupTrace("popup.anchor refused: \(error)") }
        }
    }

    func close(from caller: String = #function, line: Int = #line) {
        popupTrace("popup close asked by \(caller):\(line) token \(token.prefix(8)) already \(closed)")
        guard !closed else { return }
        closed = true
        inputTail?.cancel(); inputTail = nil
        host?.removeFromSuperlayer(); host = nil
        guard let client, let owner else { return }
        Task { @MainActor in
            guard ChromiumProcess.shared.isCurrent(client) else { return }
            do { _ = try await client.request("popup.close", params: ["tab": .string(owner), "token": .string(token)]) }
            catch { popupTrace("popup.close refused: \(error)") }
        }
    }
}

/// popup.textInput from YabCore: what Yab's input method needs of the popup's
/// focused element, as `page.textInput` gives it for a page. Chrome composes
/// only in an editable element that is no password; so does Yab.
struct ChromiumPopupTextInput: Equatable {
    let editable: Bool
    /// The caret (or the composition's start), popup points from the top left.
    let caret: CGRect?

    init(editable: Bool, caret: CGRect?) { self.editable = editable; self.caret = caret }

    init?(_ p: [String: JSONValue], token: String) {
        guard p["token"]?.string == token, case .bool(let editable)? = p["editable"] else { return nil }
        self.editable = editable
        if case .object(let row)? = p["caret"], let x = row["x"]?.number, let y = row["y"]?.number,
           let w = row["width"]?.number, let h = row["height"]?.number,
           [x, y, w, h].allSatisfy(\.isFinite), w >= 0, h > 0, abs(x) < 100_000, abs(y) < 100_000, h < 10_000 {
            caret = CGRect(x: x, y: y, width: w, height: h)
        } else {
            caret = nil
        }
    }
}

extension ChromiumPage {
    func receivePopupTextInput(_ p: [String: JSONValue]) {
        guard let popup = extensionPopup, p["token"]?.string == popup.token else { return }
        popup.receiveTextInput(p)
    }

    /// popup.layer: shown, frame or closed. `onExtensionPopup` hears every change
    /// (nil when the popup closed) so the button's UI can host or drop its layer.
    func receivePopup(_ p: [String: JSONValue]) {
        guard let packet = ChromiumPopupPacket(p, profile: profile) else {
            popupTrace("refused keys \(p.keys.sorted()) token \(p["token"]?.string?.utf8.count ?? -1) id \(p["extensionId"]?.string?.utf8.count ?? -1) idOK \(p["extensionId"]?.string?.utf8.allSatisfy({ $0 >= 97 && $0 <= 112 }) ?? false) profile \(profile.isEmpty)")
            if Store.testing { FileHandle.standardError.write(Data("yab: popup.layer refused \(p["state"]?.string ?? "") event profile \(p["profile"]?.string ?? "-") page profile \(profile) token \(String(describing: p["token"])) extension \(String(describing: p["extensionId"])) same-profile \(p["profile"]?.string == profile) state-ok \(p["state"]?.string.flatMap(ChromiumPopupPacket.State.init(rawValue:)) != nil) bytes \(Array((p["profile"]?.string ?? "").utf8).count)/\(Array(profile.utf8).count)\n".utf8)) }
            return
        }
        popupTrace("popup.layer \(packet.state) \(packet.extensionID.prefix(6)) \(packet.token.prefix(8)) window \(p["windowNumber"]?.number ?? 0)")
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
            else {
                // A replacement may arrive before its first compositor frame.
                // Retire the old host now: its follow timer must not cancel the
                // replacement's pending first presentation later.
                if let previous = extensionPopup {
                    ChromiumPopupHost.shared.replace(previous, with: id, page: self)
                    previous.close()
                }
                popup = ChromiumExtensionPopup(token: token, extensionID: id, page: self)
                extensionPopup = popup
            }
            if packet.state == .shown { ChromiumPopupHost.shared.placeProducer(popup, page: self) }
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
