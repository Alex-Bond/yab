import Foundation
import Testing
import YabCoreClient
@testable import Fast

struct ChromiumExtensionStorageTests {
    private static let wire = 4 * 1024 * 1024

    /// The request one piece goes in, as the client writes it.
    private static func request(_ text: String) throws -> Int {
        struct Request: Encodable { let v = 1; let id = 1; let method = "scripts.evaluate"; let params: [String: JSONValue] }
        return try JSONEncoder().encode(Request(params: [
            "tab": .string("tab"), "frame": .string("frame"), "world": .string(""), "arguments": .string(text),
            "function": .string("function(text){globalThis.__yabCarry+=text;return true}")])).count
    }

    /// One value bigger than the wire (a filter list, a vault's cache): as
    /// one part it was refused after the parts before it were written. In
    /// pieces, each crosses, and together they are the part again.
    @Test func aValueOverTheWireCrossesInPieces() throws {
        let letters = "\"quoted\" /path/ кириллица 中文字 \u{1}\u{1F600} "
        let value = try String(data: JSONEncoder().encode(String(repeating: letters, count: 70_000)), encoding: .utf8)!
        let parts = ChromiumExtensionStorage.parts([(key: "big", value: value), (key: "small", value: "1")])
        #expect(parts.count == 2)
        #expect(try Self.request(parts[0]) > Self.wire)
        for part in parts {
            let pieces = ChromiumExtensionStorage.pieces(part)
            #expect(pieces.joined() == part)
            for piece in pieces { #expect(try Self.request(piece) < Self.wire) }
        }
    }

    /// Pieces never split a letter, and the worst letter for the wire
    /// (a control letter JSON writes as \u0001) still fits.
    @Test func piecesKeepLettersWhole() throws {
        let pieces = ChromiumExtensionStorage.pieces("a中😀b", bytes: 4)
        #expect(pieces == ["a中", "😀", "b"])
        #expect(ChromiumExtensionStorage.pieces("") == [""])
        let worst = String(repeating: "\u{1}", count: ChromiumExtensionStorage.piece)
        #expect(try Self.request(worst) < Self.wire)
    }
}
