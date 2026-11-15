import Foundation
import Testing
@testable import Fast

/// The actual collector called by PageSave.joined, with deterministic
/// readers only. No Tab, Browser, Store, app, profile or files are created.
@MainActor
struct PageJoinedExportTests {
    private final class ReadFailure: Error {
        let page: Int
        init(page: Int) { self.page = page }
    }

    @Test func allPagesRemainInOrderAndAreTrimmed() throws {
        let words = ["  first page\n", "\nsecond page  ", " third page "]
        var reads: [Int] = [], completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: words.count, read: { index, reply in
            reads.append(index)
            reply(.success(words[index]))
        }) { completed.append($0) }
        #expect(reads == [0, 1, 2])
        #expect(completed.count == 1)
        #expect(try completed.first?.get() == ["first page", "second page", "third page"])
    }

    @Test(arguments: [0, 1, 2])
    func firstFailureIsPropagatedWithoutReadingLaterPages(failedIndex: Int) {
        let failure = ReadFailure(page: failedIndex)
        var reads: [Int] = [], completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: 3, read: { index, reply in
            reads.append(index)
            reply(index == failedIndex ? .failure(failure) : .success("page \(index)"))
        }) { completed.append($0) }
        #expect(reads == Array(0...failedIndex))
        #expect(completed.count == 1)
        if case .failure(let error)? = completed.first {
            #expect((error as? ReadFailure) === failure)
        } else { Issue.record("A failed page must not become a partial success") }
    }

    @Test func invalidOrEmptyMiddlePageDoesNotDeliverEarlierPieces() {
        let invalid: [Any?] = [nil, 17, "", " \t\n"]
        for value in invalid {
            var reads: [Int] = [], completed: [Result<[String], Error>] = []
            PageSave.collectJoined(count: 3, read: { index, reply in
                reads.append(index)
                reply(.success(index == 1 ? value : "page \(index)"))
            }) { completed.append($0) }
            #expect(reads == [0, 1])
            #expect(completed.count == 1)
            if case .failure(let error)? = completed.first {
                #expect(error.localizedDescription == "The page gave nothing to save")
            } else { Issue.record("An invalid page must stop, without a partial success") }
        }
    }

    @Test func delayedSuccessWaitsForEveryPageAndIgnoresRepeatedReplies() throws {
        var pending: [Int: @MainActor (Result<Any?, Error>) -> Void] = [:]
        var reads: [Int] = [], completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: 2, read: { index, reply in
            reads.append(index)
            pending[index] = reply
        }) { completed.append($0) }
        #expect(reads == [0] && completed.isEmpty)
        let first = try #require(pending[0])
        first(.success(" first "))
        #expect(reads == [0, 1] && completed.isEmpty)
        first(.success("duplicate must not count as page two"))
        #expect(completed.isEmpty)
        let second = try #require(pending[1])
        second(.success(" second "))
        #expect(completed.count == 1)
        #expect(try completed.first?.get() == ["first", "second"])
        second(.success("late duplicate"))
        first(.failure(ReadFailure(page: 0)))
        #expect(completed.count == 1 && reads == [0, 1])
    }

    @Test func delayedFailureIsTerminalEvenIfAReaderLaterSaysSuccess() throws {
        var pending: [Int: @MainActor (Result<Any?, Error>) -> Void] = [:]
        var reads: [Int] = [], completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: 3, read: { index, reply in
            reads.append(index)
            pending[index] = reply
        }) { completed.append($0) }
        let first = try #require(pending[0])
        first(.success("page one"))
        let second = try #require(pending[1]), failure = ReadFailure(page: 1)
        second(.failure(failure))
        #expect(completed.count == 1 && reads == [0, 1] && pending[2] == nil)
        second(.success("late success after error"))
        first(.success("old reply after error"))
        #expect(completed.count == 1 && reads == [0, 1])
        if case .failure(let error)? = completed.first {
            #expect((error as? ReadFailure) === failure)
        } else { Issue.record("The original reader error must stay terminal") }
    }

    @Test func noPagesFailsWithoutCallingTheReader() {
        var read = false, completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: 0, read: { _, _ in read = true }) { completed.append($0) }
        #expect(!read && completed.count == 1)
        if case .failure(let error)? = completed.first {
            #expect(error.localizedDescription == "No tabs to save")
        } else { Issue.record("Zero pages is not a successful empty export") }
    }

    @Test func onePageStillSucceeds() throws {
        var reads: [Int] = [], completed: [Result<[String], Error>] = []
        PageSave.collectJoined(count: 1, read: { index, reply in
            reads.append(index)
            reply(.success(" one page "))
        }) { completed.append($0) }
        #expect(reads == [0] && completed.count == 1)
        #expect(try completed.first?.get() == ["one page"])
    }
}
