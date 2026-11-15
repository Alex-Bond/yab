import AppKit
import YabCoreClient

/// Keep the keyboard event's native text payload across the process boundary.
/// Reconstructing an NSEvent from characters loses the CGEvent Unicode payload
/// that AppKit's input context uses for supplementary characters (emoji).
@MainActor
enum ChromiumKeyboardInput {
    static func fields(_ event: NSEvent) -> [String: JSONValue] {
        var fields: [String: JSONValue] = ["keyCode": .number(Double(event.keyCode)),
            "modifiers": .number(Double(event.modifierFlags.rawValue))]
        if event.type != .flagsChanged {
            fields["characters"] = .string(event.characters ?? "")
            fields["unmodified"] = .string(event.charactersIgnoringModifiers ?? "")
            fields["repeat"] = .bool(event.isARepeat)
        }
        if let data = event.cgEvent?.data as Data?, !data.isEmpty {
            fields["event"] = .string(data.base64EncodedString())
        }
        return fields
    }
}
