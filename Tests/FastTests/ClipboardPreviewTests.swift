import AppKit
import Testing
@testable import Fast

@MainActor
struct ClipboardPreviewTests {
    private func clip(_ text: String, kind: Clips.Clip.Kind = .text, times: Int = 1, types: [String] = []) -> Clips.Clip {
        Clips.Clip(id: UUID(), kind: kind, text: text, app: "Synthetic", bundle: nil,
                   page: nil, pageTitle: nil, first: .distantPast, last: Date(timeIntervalSince1970: 1_793_300_100),
                   times: times, pinned: false, types: types, bytes: text.utf8.count, digest: "fixture")
    }

    @Test func fileRowsAndSuggestionsUseTheNameWithoutItsExtension() {
        let file = clip("/Users/synthetic/Documents/Screenshot 2026-10-29 at 12.55.02.png", kind: .file)
        #expect(file.line == "Screenshot 2026-10-29 at 12.55.02")
        #expect(file.title == file.line)
        #expect(clip("\n    func paste() {\n}").title == "func paste() {")
        #expect(clip(" \t\n    func paste() {\n}").title == "func paste() {")
    }

    @Test func lastCopiedMergesTheRepeatCountAndOmitsOneTime() {
        let once = clip("once")
        let repeated = clip("twice", times: 2)
        let today = once.lastCopied(now: once.last)
        #expect(today.hasPrefix("Today at "))
        #expect(!today.contains("times"))
        #expect(repeated.lastCopied(now: once.last) == today + ", 2 times")
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: once.last)!
        #expect(once.lastCopied(now: tomorrow).hasPrefix("Yesterday at "))
    }

    @Test(arguments: [
        ("one line", nil), ("a\nb", "2"), ("\na\nb", "3, blank at start"),
        ("a\nb\n", "3, blank at end"), ("\na\nb\n", "4, blank at start and end"),
        ("\r\na\r\nb\r\n", "4, blank at start and end"),
        (" \t\na\n \t", "3, blank at start and end")
    ] as [(String, String?)])
    func linesDescribeRetainedOuterBlankLines(sample: (String, String?)) {
        let (text, expected) = sample
        #expect(ClipText(clip: clip(text), data: []).lines == expected)
    }

    @Test func retainedRTFShowsBoldAndWhitespaceWithoutChangingEitherFlavor() throws {
        let code = "\nfunc paste(_ clip: Clip) {\n    let board = NSPasteboard.general\n    board.clearContents()\n    Clips.shared.put(clip)\n}\n"
        let value = NSMutableAttributedString(string: code)
        let range = (code as NSString).range(of: "Clips.shared.put(clip)")
        value.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: range)
        let rtf = try value.data(from: NSRange(location: 0, length: value.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let data = [(NSPasteboard.PasteboardType.string.rawValue, Data(code.utf8)), (NSPasteboard.PasteboardType.rtf.rawValue, rtf)]
        // An older index can predate a rich copy of the same words.
        let item = clip(code.trimmingCharacters(in: .whitespacesAndNewlines), types: [NSPasteboard.PasteboardType.string.rawValue])
        let history = Clips(readClipData: { _ in data })
        let preview = history.preview(item)
        #expect(preview.kind == "Formatted Text, bold")
        #expect(preview.text == code)
        #expect(preview.lines == "7, blank at start and end")
        let drawing = preview.drawing()
        #expect(drawing.string.hasPrefix("¶\nfunc"))
        #expect(drawing.string.contains("····Clips.shared.put(clip)"))
        #expect(drawing.string.hasSuffix("\n¶"))
        let drawnBold = (drawing.string as NSString).range(of: "Clips.shared.put(clip)")
        let font = try #require(drawing.attribute(.font, at: drawnBold.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        let board = NSPasteboard(name: .init("clipboard-preview-\(UUID())"))
        defer { board.releaseGlobally() }
        history.put(item, plain: true, on: board)
        #expect(board.string(forType: .string) == code)
        #expect(board.data(forType: .rtf) == nil)
        history.put(item, on: board)
        #expect(board.string(forType: .string) == code)
        #expect(board.data(forType: .rtf) == rtf)
    }

    @Test func htmlOnlyFormattingAndTabsAreDrawnInThePreview() {
        let code = "\n\t  bold\n"
        let data = [(NSPasteboard.PasteboardType.html.rawValue, Data("<pre>\n\t  <b>bold</b>\n</pre>".utf8)),
                    (NSPasteboard.PasteboardType.string.rawValue, Data(code.utf8))]
        let preview = ClipText(clip: clip("bold", types: data.map(\.0)), data: data)
        #expect(preview.bold)
        #expect(preview.text == code)
        #expect(preview.drawing().string == "¶\n······bold\n¶")
    }

    @Test func previewReadsTheKeptFlavorsOnce() {
        var reads = 0
        let history = Clips(readClipData: { _ in reads += 1; return [] })
        let item = clip("words")
        _ = history.preview(item)
        _ = history.preview(item)
        #expect(reads == 1)
    }

    @Test func htmlParagraphSpacingKeepsBothBoldAndThePlainBlankLines() {
        let code = "\nFirst paragraph\n\nbold words\n"
        let data = [(NSPasteboard.PasteboardType.html.rawValue, Data("<p>First paragraph</p><p><b>bold words</b></p>".utf8)),
                    (NSPasteboard.PasteboardType.string.rawValue, Data(code.utf8))]
        let preview = ClipText(clip: clip("First paragraph", types: data.map(\.0)), data: data)
        #expect(preview.bold)
        #expect(preview.text == code)
        #expect(preview.lines == "5, blank at start and end")
        #expect(preview.drawing().string == "¶\nFirst paragraph\n\nbold words\n¶")
    }

    @Test func richAndPlainUnicodeNormalizationCanHaveDifferentUTF16Lengths() throws {
        let composed = "café"
        let decomposed = "cafe\u{301}"
        let rich = NSAttributedString(string: decomposed, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let data = [(NSPasteboard.PasteboardType.rtf.rawValue, rtf), (NSPasteboard.PasteboardType.string.rawValue, Data(composed.utf8))]
        let preview = ClipText(clip: clip(composed, types: data.map(\.0)), data: data)
        #expect(preview.text.utf16.count == composed.utf16.count)
        #expect(preview.bold)
        #expect(preview.drawing().string.utf16.count == composed.utf16.count)
    }

    @Test func sourceIconsUseTheBundleAndAnUnknownAppHasNoIcon() {
        #expect(ClipApps.shared.icon("com.apple.finder") != nil)
        #expect(ClipApps.shared.icon("dev.yab.no-such-preview-app") == nil)
        #expect(ClipApps.shared.icon(nil) == nil)
    }

    @Test func fileInformationUsesTheActualFileAndAbbreviatesHome() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clip-preview-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 16,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(pixels.representation(using: .png, properties: [:]))
        try bytes.write(to: file)
        let item = clip(file.path, kind: .file)
        #expect(item.fileKind.contains("24 × 16"))
        #expect(item.fileKind.contains(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)))
        #expect(item.folder == (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        #expect(clip(NSHomeDirectory() + "/Documents/example.png", kind: .file).folder == "~/Documents")
    }
}
