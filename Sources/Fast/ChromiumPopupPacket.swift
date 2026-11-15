import Foundation
import YabCoreClient

/// Native popup messages are scoped by the event's original page endpoint;
/// this decoder validates their profile, popup owner and compositor geometry
/// before numeric conversion or any AppKit/CALayer mutation.
struct ChromiumPopupPacket {
    enum State: String { case shown, frame, closed }

    struct Frame: Equatable {
        let context: UInt32
        let pixelWidth: Double
        let pixelHeight: Double
        let scale: Double

        var width: Double { pixelWidth / scale }
        var height: Double { pixelHeight / scale }
    }

    let state: State
    let token: String
    let extensionID: String
    let frame: Frame?

    init?(_ p: [String: JSONValue], profile: String) {
        guard !profile.isEmpty, p["profile"]?.string == profile,
              let name = p["state"]?.string, let state = State(rawValue: name),
              let token = p["token"]?.string ?? p["token"]?.number.map({ String(format: "%.0f", $0) }), !token.isEmpty, token.utf8.count <= 256,
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let id = p["extensionId"]?.string, id.utf8.count == 32,
              id.utf8.allSatisfy({ $0 >= 97 && $0 <= 112 }) else { return nil }
        self.state = state; self.token = token; extensionID = id
        guard state == .frame else { frame = nil; return }
        guard let context = p["contextId"]?.number, context.isFinite,
              context >= 1, context <= Double(UInt32.max), context.rounded(.towardZero) == context,
              let width = p["pixelWidth"]?.number, width.isFinite, width >= 1, width <= 32768,
              width.rounded(.towardZero) == width,
              let height = p["pixelHeight"]?.number, height.isFinite, height >= 1, height <= 32768,
              height.rounded(.towardZero) == height,
              let scale = p["scale"]?.number, scale.isFinite, (1...8).contains(scale),
              width / scale <= 4096, height / scale <= 4096 else { return nil }
        frame = Frame(context: UInt32(context), pixelWidth: width, pixelHeight: height, scale: scale)
    }
}
