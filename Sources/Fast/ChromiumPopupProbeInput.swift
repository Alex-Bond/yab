import Foundation
import CoreFoundation
import CoreGraphics

/// A test-only point into one original native popup. No DOM/source/grant authority.
struct ChromiumPopupProbeInput {
    let token: String
    let extensionID: String
    let context: UInt32
    let window: Int
    let x: Double
    let y: Double
    let contentWidth: Double
    let contentHeight: Double

    init?(_ request: [String: Any]) {
        func number(_ key: String) -> Double? {
            guard let value = request[key] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
            return value.doubleValue
        }
        guard let token = request["token"] as? String, !token.isEmpty, token.utf8.count <= 256,
              let id = request["extension"] as? String, id.utf8.count == 32,
              id.utf8.allSatisfy({ (97...112).contains($0) }),
              let rawContext = number("context"), let context = UInt32(exactly: rawContext), context != 0,
              let rawWindow = number("window"), let window = Int32(exactly: rawWindow), window > 0,
              let x = number("x"), let y = number("y"),
              x >= 0, y >= 0, x < 32768, y < 32768,
              let width = number("contentWidth"), let height = number("contentHeight"),
              width > 0, height > 0, width <= 32768, height <= 32768 else { return nil }
        self.token = token; extensionID = id; self.context = context
        self.window = Int(window); self.x = x; self.y = y
        contentWidth = width; contentHeight = height
    }

    func matches(token: String, extensionID: String, context: UInt32, window: Int, size: CGSize) -> Bool {
        self.token == token && self.extensionID == extensionID && self.context == context && self.window == window &&
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
        Double(size.width) == contentWidth && Double(size.height) == contentHeight &&
        x < size.width && y < size.height
    }
}
