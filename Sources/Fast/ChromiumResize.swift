import Foundation
import YabCoreClient

/// Native compositor receipt, not a presentation fence. Keep the hosted
/// coordinate space at its last committed size until the current request lands.
struct ChromiumResize {
    struct Geometry: Equatable {
        let size: CGSize
        let scale: Double
        let visible: Bool

        init(size: CGSize, scale: Double, visible: Bool) {
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
    private var context: Double = 0

    mutating func request(_ geometry: Geometry) -> String {
        let token = UUID().uuidString
        requested = geometry
        serial = token
        return token
    }

    mutating func surface(_ params: [String: JSONValue]) {
        context = params["contextId"]?.number ?? 0
        native = params["source"]?.string == "cefCallback" && context > 0
        guard native else { committed = nil; serial = nil; acknowledged = nil; return }
        // Once armed, only the matching acknowledgement can change the host.
        if serial == nil { committed = size(params) }
    }

    @discardableResult
    mutating func receive(_ params: [String: JSONValue]) -> Bool {
        guard native, let serial, params["serial"]?.string == serial,
              params["contextId"]?.number == context,
              let size = size(params), size == requested?.size else { return false }
        committed = size
        acknowledged = serial
        self.serial = nil
        return true
    }

    mutating func unsupported(_ token: String) {
        if serial == token { serial = nil; committed = nil; native = false }
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
