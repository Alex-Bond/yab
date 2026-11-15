import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Fast

/// #251: Send Feedback lights up for a drag only when letting go attaches
/// something, and then it does.
@MainActor
@Suite(.serialized)
struct FeedbackDropTests {
    private func board(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("yab-feedback-drop-\(UUID().uuidString)"))
        board.clearContents()
        write(board)
        return board
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("feedback-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func withEmptyDraft(_ body: () throws -> Void) rethrows {
        let model = FeedbackModel.shared
        let kept = model.draft
        model.draft = FeedbackSheet.Draft()
        defer { model.draft = kept }
        try body()
    }

    @Test func aFileIsTakenAndAttached() throws {
        try withEmptyDraft {
            let file = try folder().appendingPathComponent("note.txt")
            try Data("251\n".utf8).write(to: file)
            let board = board { $0.writeObjects([file as NSURL]) }
            #expect(FeedbackSheet.takes(board))
            #expect(FeedbackSheet.take(board))
            #expect(FeedbackModel.shared.draft.files.map(\.name) == ["note.txt"])
        }
    }

    @Test func aFolderLightsNothing() throws {
        try withEmptyDraft {
            let inside = try folder()
            let board = board { $0.writeObjects([inside as NSURL]) }
            #expect(!FeedbackSheet.takes(board))
            #expect(!FeedbackSheet.take(board))
            #expect(FeedbackModel.shared.draft.files.isEmpty)
        }
    }

    @Test func aPictureWithNoFileIsAttached() throws {
        try withEmptyDraft {
            let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
                NSColor.systemTeal.setFill()
                rect.fill()
                return true
            }
            let tiff = try #require(image.tiffRepresentation)
            let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            let board = board { $0.setData(png, forType: .png) }
            #expect(FeedbackSheet.takes(board))
            #expect(FeedbackSheet.take(board))
            #expect(FeedbackModel.shared.draft.files.map(\.name) == ["Dropped image.png"])
        }
    }

    @Test func wordsAloneAreNotTaken() {
        withEmptyDraft {
            let board = board { $0.setString("https://example.com", forType: .string) }
            #expect(!FeedbackSheet.takes(board))
        }
    }

    @Test func aFullCardLightsNothing() throws {
        try withEmptyDraft {
            let folder = try folder()
            let files = try (0..<FeedbackFile.most).map { index in
                let file = folder.appendingPathComponent("\(index).txt")
                try Data("\(index)".utf8).write(to: file)
                return file
            }
            FeedbackSheet.attach(files)
            let more = folder.appendingPathComponent("more.txt")
            try Data("more".utf8).write(to: more)
            #expect(!FeedbackSheet.takes(board { $0.writeObjects([more as NSURL]) }))
        }
    }

    @Test func anUnreadableFileIsSaid() throws {
        try withEmptyDraft {
            let gone = try folder().appendingPathComponent("gone.txt")
            FeedbackSheet.attach([gone])
            #expect(FeedbackModel.shared.draft.files.isEmpty)
            #expect(FeedbackModel.shared.unreadNote == "Couldn't read gone.txt.")
        }
    }
}
