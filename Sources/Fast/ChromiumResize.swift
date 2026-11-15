import Foundation
import YabCoreClient

/// Native compositor receipt, not a presentation fence. Keep the hosted
/// coordinate space at its last committed size until the current request lands.
struct ChromiumResize {
    struct Geometry: Equatable {
        let size: CGSize
        let scale: Double
        let visible: Bool
        /// In its place in a window nobody can see: hidden from the page,
        /// though the stage still counts it as shown (ChromiumPage.windowCovered).
        var covered = false

        /// Resizing a visible page does not show it again. In particular,
        /// sidebar animation must not run the helper's show/restore path
        /// between successive compositor sizes.
        func changesVisibility(from previous: Geometry?) -> Bool {
            visible != previous?.visible || covered != previous?.covered
        }

        init(size: CGSize, scale: Double, visible: Bool, covered: Bool = false) {
            self.covered = covered
            self.size = CGSize(width: min(16384, max(1, ceil(size.width))),
                               height: min(16384, max(1, ceil(size.height))))
            self.scale = scale
            self.visible = visible
        }
    }

    private(set) var committed: CGSize?
    private(set) var serial: String?
    private(set) var acknowledged: String?
    private(set) var requested: Geometry?
    private(set) var native = false
    private var pendingAcknowledgement: [String: JSONValue]?
    private var context: Double = 0
    private var acknowledgedContext: Double?
    private var unacknowledgedSurfaceAllowed = false
    private var initialGeometryAcknowledged = false

    /// The first native surface can still be the helper's bootstrap viewport.
    /// Keep the page ground visible until a frame acknowledges our geometry.
    /// Later resizes retain the already presented frame as before.
    var canPresent: Bool { !native || unacknowledgedSurfaceAllowed || initialGeometryAcknowledged }
    var needsContextAcknowledgement: Bool {
        native && !unacknowledgedSurfaceAllowed && requested != nil && acknowledgedContext != context
    }

    mutating func request(_ geometry: Geometry) -> String {
        let token = UUID().uuidString
        pendingAcknowledgement = nil
        requested = geometry
        serial = token
        return token
    }

    @discardableResult
    mutating func surface(_ params: [String: JSONValue]) -> Bool {
        context = params["contextId"]?.number ?? 0
        native = params["source"]?.string == "cefCallback" && context > 0
        guard native else {
            committed = nil; acknowledged = nil
            // A zero CEF context can precede its replacement while a resize
            // is pending. Keep that token: the replacement frame acknowledges
            // it, and receive still checks the new context and requested size.
            if params["source"]?.string != "cefCallback" { serial = nil }
            return false
        }
        if let pending = pendingAcknowledgement, receive(pending) { return true }
        // Once armed, only the matching acknowledgement can change the host.
        if serial == nil { committed = size(params) }
        return false
    }

    @discardableResult
    mutating func receive(_ params: [String: JSONValue]) -> Bool {
        guard let serial, params["serial"]?.string == serial,
              let receiptContext = params["contextId"]?.number, receiptContext > 0,
              let size = size(params), size == requested?.size else { return false }
        // The resize reply and compositor context can cross at attachment or
        // renderer replacement. The helper retires the serial after one ACK;
        // retain it until that exact context is bound instead of losing it.
        guard native, receiptContext == context else {
            pendingAcknowledgement = params
            return false
        }
        pendingAcknowledgement = nil
        committed = size
        acknowledgedContext = context
        acknowledged = serial
        initialGeometryAcknowledged = true
        self.serial = nil
        return true
    }

    mutating func unsupported(_ token: String) {
        if serial == token {
            pendingAcknowledgement = nil
            serial = nil; committed = nil; native = false
            // A native surface can exist without serial resize receipts (for
            // example a separately owned PiP window). Later surface callbacks
            // must not hide it forever waiting for an unsupported receipt.
            unacknowledgedSurfaceAllowed = true
        }
    }

    func frame(in bounds: CGRect) -> CGRect {
        let size = native ? committed ?? bounds.size : bounds.size
        return CGRect(x: bounds.minX, y: bounds.maxY - size.height, width: size.width, height: size.height)
    }

    private func size(_ params: [String: JSONValue]) -> CGSize? {
        guard let width = params["width"]?.number, let height = params["height"]?.number,
              width.isFinite, height.isFinite, width >= 1, height >= 1 else { return nil }
        return CGSize(width: width, height: height)
    }
}
