import AppKit
import Testing
@testable import Fast

@MainActor
struct ClipboardPlainTests {
    private let sample = "\n\t    if (ready) {\n\t        run(\"你好🙂\");\n\t    }\n\n"
    private let custom = NSPasteboard.PasteboardType("dev.yab.test.clipboard-rich")

    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("clipboard-plain-\(UUID())"))
        board.clearContents()
        return board
    }

    private func clip(text: String, types: [String], kind: Clips.Clip.Kind = .text) -> Clips.Clip {
        Clips.Clip(id: UUID(), kind: kind, text: text, app: "Synthetic", bundle: nil,
                   page: nil, pageTitle: nil, first: .distantPast, last: .distantPast,
                   times: 1, pinned: false, types: types, bytes: text.utf8.count, digest: "synthetic")
    }

    private func hasNoRichFlavors(_ board: NSPasteboard) -> Bool {
        let types = Set(board.types ?? [])
        return types.isDisjoint(with: [.html, .rtf, .URL, .fileURL, custom])
    }

    @Test func plainCopyUsesRetainedUTF8InsteadOfTrimmedPreview() {
        let board = board()
        defer { board.releaseGlobally() }
        let data: [(String, Data)] = [
            (NSPasteboard.PasteboardType.html.rawValue, Data("<pre style='color:red'>other</pre>".utf8)),
            (NSPasteboard.PasteboardType.string.rawValue, Data(sample.utf8)),
            (NSPasteboard.PasteboardType.rtf.rawValue, Data("{\\rtf1 other}".utf8)),
            (NSPasteboard.PasteboardType.URL.rawValue, Data("https://example.invalid/".utf8)),
            (custom.rawValue, Data([1, 2, 3]))
        ]
        let clip = clip(text: sample.trimmingCharacters(in: .whitespacesAndNewlines), types: data.map(\.0))
        var reads = 0
        let history = Clips(readClipData: { id in
            #expect(id == clip.id)
            reads += 1
            return data
        })

        history.put(clip, plain: true, on: board)

        #expect(board.string(forType: .string) == sample)
        #expect(hasNoRichFlavors(board))
        #expect(reads == 1)
        #expect(history.items.isEmpty)
        #expect(clip.text == sample.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(data.first { $0.0 == NSPasteboard.PasteboardType.string.rawValue }?.1 == Data(sample.utf8))
    }

    @Test(arguments: ["public.utf16-plain-text", "public.utf16-external-plain-text"])
    func plainCopyPreservesUTF16Content(flavor: String) throws {
        let board = board()
        defer { board.releaseGlobally() }
        let bytes = try #require(sample.data(using: .utf16))
        let data = [(flavor, bytes), (NSPasteboard.PasteboardType.html.rawValue, Data("<b>wrong</b>".utf8))]
        let history = Clips(readClipData: { _ in data })

        history.put(clip(text: "wrong preview", types: data.map(\.0)), plain: true, on: board)

        #expect(board.string(forType: .string) == sample)
        #expect(hasNoRichFlavors(board))
    }

    @Test func plainFlavorPrecedenceDoesNotDependOnRetainedOrder() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let other = try #require("other utf16".data(using: .utf16))
        let data = [("public.utf16-plain-text", other), ("public.utf8-plain-text", Data(sample.utf8))]
        let history = Clips(readClipData: { _ in data })

        history.put(clip(text: "preview", types: data.map(\.0)), plain: true, on: board)

        #expect(board.string(forType: .string) == sample)
    }

    @Test func invalidUTF8CanUseTheExistingUTF16Flavor() throws {
        let board = board()
        defer { board.releaseGlobally() }
        let bytes = try #require(sample.data(using: .utf16))
        let data = [("public.utf8-plain-text", Data([0xff])), ("public.utf16-plain-text", bytes)]
        let history = Clips(readClipData: { _ in data })

        history.put(clip(text: "preview", types: data.map(\.0)), plain: true, on: board)

        #expect(board.string(forType: .string) == sample)
        #expect(hasNoRichFlavors(board))
    }

    @Test func missingOrInvalidPlainDataKeepsTheHistoricalFallback() {
        let board = board()
        defer { board.releaseGlobally() }
        let html = (NSPasteboard.PasteboardType.html.rawValue, Data("<b>not converted</b>".utf8))
        let examples: [[(String, Data)]] = [[], [html], [("public.utf8-plain-text", Data([0xff])), html]]
        for data in examples {
            let history = Clips(readClipData: { _ in data })
            history.put(clip(text: "legacy fallback", types: data.map(\.0)), plain: true, on: board)
            #expect(board.string(forType: .string) == "legacy fallback")
            #expect(hasNoRichFlavors(board))
        }
    }

    @Test func anEmptyRetainedPlainStringIsNotReplacedWithThePreview() {
        let board = board()
        defer { board.releaseGlobally() }
        let data = [("public.utf8-plain-text", Data())]
        let history = Clips(readClipData: { _ in data })

        history.put(clip(text: "preview", types: data.map(\.0)), plain: true, on: board)

        #expect(board.string(forType: .string) == "")
    }

    @Test func defaultCopyRetainsOriginalRichFlavorsAndPlainWhitespace() {
        let board = board()
        defer { board.releaseGlobally() }
        let data: [(String, Data)] = [
            (NSPasteboard.PasteboardType.string.rawValue, Data(sample.utf8)),
            (NSPasteboard.PasteboardType.html.rawValue, Data("<pre style='color:red'>rich</pre>".utf8)),
            (NSPasteboard.PasteboardType.rtf.rawValue, Data("{\\rtf1 rich}".utf8)),
            (custom.rawValue, Data([0, 4, 2]))
        ]
        var reads = 0
        let history = Clips(readClipData: { _ in reads += 1; return data })

        history.put(clip(text: "trimmed preview", types: data.map(\.0)), on: board)

        #expect(reads == 1)
        #expect(board.string(forType: .string) == sample)
        for (type, bytes) in data {
            #expect(board.data(forType: .init(type)) == bytes)
        }
    }

    @Test func legacyDefaultCopyAndImagePlainCopyKeepTheirExistingPolicy() {
        let board = board()
        defer { board.releaseGlobally() }
        var reads = 0
        let history = Clips(readClipData: { _ in reads += 1; return [("public.utf8-plain-text", Data("unexpected".utf8))] })

        history.put(clip(text: "legacy indexed text", types: []), on: board)
        #expect(board.string(forType: .string) == "legacy indexed text")
        #expect(reads == 0)

        history.put(clip(text: "Image (20 × 20)", types: [NSPasteboard.PasteboardType.png.rawValue], kind: .image),
                    plain: true, on: board)
        #expect(board.string(forType: .string) == "")
        #expect(reads == 0)
    }

    @Test func nontextPlainCopyStillUsesItsIndexedRepresentation() {
        let board = board()
        defer { board.releaseGlobally() }
        let examples: [(Clips.Clip.Kind, String)] = [
            (.file, "/tmp/a b"), (.link, "https://example.invalid/path"), (.color, "#aabbcc")
        ]
        var reads = 0
        let data = [
            (NSPasteboard.PasteboardType.fileURL.rawValue, Data("file:///tmp/a%20b".utf8)),
            (NSPasteboard.PasteboardType.string.rawValue, Data("\n  divergent raw display text\n".utf8))
        ]
        let history = Clips(readClipData: { _ in reads += 1; return data })
        for (kind, indexed) in examples {
            history.put(clip(text: indexed, types: data.map(\.0), kind: kind), plain: true, on: board)

            #expect(board.string(forType: .string) == indexed)
            #expect(hasNoRichFlavors(board))
        }
        #expect(reads == 0)
    }
}
