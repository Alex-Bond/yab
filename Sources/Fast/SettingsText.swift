import AppKit
import SwiftUI

/// Inline key plates stay in Text's line layout, so descriptions wrap as
/// prose and each shortcut stays together, centered on the letters.
@MainActor
struct SettingsText: View {
    let words: String
    let size: CGFloat

    init(_ words: String, size: CGFloat = 12) {
        self.words = words
        self.size = size
    }

    var body: some View {
        Self.line(words, size: size)
            .accessibilityLabel(Self.plain(words))
    }

    static func plain(_ words: String) -> String {
        words.replacingOccurrences(of: "\u{E000}", with: "")
            .replacingOccurrences(of: "\u{E001}", with: "")
    }

    // Explicit spans also cover reassigned shortcuts with no modifiers.
    // Unmarked symbols cover the fixed hints in Settings' existing copy.
    private static let pattern = try! NSRegularExpression(pattern:
        "\u{E000}[^\u{E001}]+\u{E001}|[⌃⌥⇧⌘]+(?=-click)|[⌃⌥⇧⌘]+(?:Page Up|Page Down|Space|Home|End|esc|F[0-9]{1,2}|Key [0-9]+|[A-Z0-9↩⏎⇥⌫⌦⎋←→↑↓\\[\\]{}=+;,./`'\\\\-])?|[↩⏎⇥⌫⌦⎋]")

    private static func line(_ words: String, size: CGFloat) -> Text {
        let source = words as NSString
        var line = Text("")
        var end = 0
        for match in pattern.matches(in: words, range: NSRange(location: 0, length: source.length)) {
            line = line + Text(verbatim: source.substring(with: NSRange(location: end, length: match.range.location - end)))
            let keys = plain(source.substring(with: match.range))
            let image = plate(keys, size: size)
            // Images sit on the baseline by default. Put the plate's middle
            // at the font's cap-height middle, just as KeyGlyphs does.
            let lift = (NSFont.systemFont(ofSize: size).capHeight - image.size.height) / 2
            line = line + Text(Image(nsImage: image).renderingMode(.template)).baselineOffset(lift)
            end = NSMaxRange(match.range)
        }
        return line + Text(verbatim: source.substring(from: end))
    }

    private static var plates: [String: NSImage] = [:]

    private static func plate(_ keys: String, size: CGFloat) -> NSImage {
        let id = "\(size)|\(keys)"
        if let image = plates[id] { return image }
        let renderer = ImageRenderer(content:
            KeyGlyphs(keys: keys, size: size * 11 / 12, tint: .black)
                .environment(\.colorScheme, .light)
                .environment(\.keyPlate, nil))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: .zero)
        plates[id] = image
        return image
    }
}

extension Hotkey {
    /// Kept inside Settings prose until SettingsText draws it as plates.
    var settingsHint: String { "\u{E000}" + text + "\u{E001}" }
}
