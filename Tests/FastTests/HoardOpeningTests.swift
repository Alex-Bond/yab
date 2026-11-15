import Foundation
import Testing
@testable import Fast

@MainActor
struct HoardOpeningTests {
    @Test func firstHoverWaitsForRowsInsteadOfConsumingTheFileOnTheNextTurn() {
        var opening = HoardStack.Opening()
        opening.begin()
        // First presentation still has EmptyView's intrinsic size. Neither
        // the next turn nor pointer polling may authorize the handoff.
        let mounted1 = opening.mount(visible: true, hasRows: false)
        #expect(!mounted1)
        #expect(opening.pending)
        let mounted2 = opening.mount(visible: true, hasRows: false)
        #expect(!mounted2)
        // The mounted rows acknowledge this same hover, without reentry.
        let mounted3 = opening.mount(visible: true, hasRows: true)
        #expect(mounted3)
        #expect(!opening.pending)
        let mounted4 = opening.mount(visible: true, hasRows: true)
        #expect(!mounted4)
    }

    @Test func closingBeforeMountCannotConsumeTheWaitingFile() {
        var opening = HoardStack.Opening()
        opening.begin()
        opening.cancel()
        let mounted5 = opening.mount(visible: true, hasRows: true)
        #expect(!mounted5)
        opening.begin()
        let mounted6 = opening.mount(visible: false, hasRows: true)
        #expect(!mounted6)
        let mounted7 = opening.mount(visible: true, hasRows: true)
        #expect(mounted7)
    }

    @Test func pictureKeyTracksTheFileRevisionInsteadOfTheDownloadDate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let first = HoardPictures.Key(url)
        #expect(first == HoardPictures.Key(url))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: url.path)
        #expect(first != HoardPictures.Key(url))
    }
}
