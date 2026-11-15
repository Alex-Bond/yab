import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast

@Suite(.serialized)
@MainActor
struct ImageCopyOwnershipTests {
    /// Each test controls actual asynchronous read completion, without a
    /// timer, network request, profile or Task.yield scheduling assumption.
    @MainActor
    private final class HeldImage {
        private var pending: CheckedContinuation<Data?, Never>?
        private var waiting: CheckedContinuation<Void, Never>?

        func read() async -> Data? {
            await withCheckedContinuation { continuation in
                pending = continuation
                waiting?.resume()
                waiting = nil
            }
        }

        func started() async {
            if pending != nil { return }
            await withCheckedContinuation { waiting = $0 }
        }

        func resolve(_ data: Data?) {
            let continuation = pending
            pending = nil
            continuation?.resume(returning: data)
        }
    }

    private func board(_ text: String = "original") -> NSPasteboard {
        let board = NSPasteboard(name: .init("image-copy-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    private func png(red: Bool) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try #require(CGColor(colorSpace: space, components: red ? [1, 0, 0, 1] : [0, 0, 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func checkImage(_ board: NSPasteboard, red: Bool) throws {
        let data = try #require(board.data(forType: .tiff))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2 && image.height == 2)
        // Decode tagged PNG/TIFF into the same explicit color space and
        // assert every channel, including alpha, as exact RGBA bytes.
        let original = try png(red: red)
        let inputSource = try #require(CGImageSourceCreateWithData(original as CFData, nil))
        let input = try #require(CGImageSourceCreateImageAtIndex(inputSource, 0, nil))
        let expected: [UInt8] = red ? [255, 0, 0, 255] : [0, 0, 255, 255]
        #expect(try rgba(input) == expected)
        #expect(try rgba(image) == expected)
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return bytes
    }

    @Test func currentImageWritesActualPixelsAndReportsInTheWriteTurn() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), data = try png(red: true)
        let request = copier.begin(on: board), before = board.changeCount
        var reports: [Bool] = []
        var reportedCount: Int?
        let outcome = await copier.copy(request, read: { data }) { wrote in
            reports.append(wrote)
            reportedCount = board.changeCount
        }
        #expect(outcome == .copied && reports == [true])
        #expect(board.changeCount != before && reportedCount == board.changeCount)
        try checkImage(board, red: true)
    }

    @Test(arguments: [false, true])
    func currentMissingOrInvalidDataKeepsClipboardAndReportsFailure(invalid: Bool) async {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), request = copier.begin(on: board), before = board.changeCount
        var reports: [Bool] = []
        let outcome = await copier.copy(request, read: { invalid ? Data([0, 1, 2]) : nil }) { reports.append($0) }
        #expect(outcome == .failed && reports == [false])
        #expect(board.changeCount == before && board.string(forType: .string) == "original")
    }

    @Test func interveningTextCopyKeepsOwnershipAfterTheImageReadFinishes() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), held = HeldImage(), data = try png(red: true)
        let request = copier.begin(on: board)
        var reports: [Bool] = []
        let task = Task { await copier.copy(request, read: { await held.read() }) { reports.append($0) } }
        await held.started()
        board.clearContents()
        board.setString("newer text", forType: .string)
        let newer = board.changeCount
        held.resolve(data)
        let outcome = await task.value
        #expect(outcome == .superseded && reports.isEmpty)
        #expect(board.changeCount == newer && board.string(forType: .string) == "newer text")
    }

    @Test func laterImageWinsWhenItFinishesBeforeTheFirst() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), a = HeldImage(), b = HeldImage()
        let red = try png(red: true), blue = try png(red: false)
        let first = copier.begin(on: board)
        var reportsA: [Bool] = [], reportsB: [Bool] = []
        let taskA = Task { await copier.copy(first, read: { await a.read() }) { reportsA.append($0) } }
        await a.started()
        let second = copier.begin(on: board)
        let taskB = Task { await copier.copy(second, read: { await b.read() }) { reportsB.append($0) } }
        await b.started()
        b.resolve(blue)
        let outcomeB = await taskB.value
        let afterB = board.changeCount
        a.resolve(red)
        let outcomeA = await taskA.value
        #expect(outcomeB == .copied && reportsB == [true])
        #expect(outcomeA == .superseded && reportsA.isEmpty && board.changeCount == afterB)
        try checkImage(board, red: false)
    }

    @Test func laterIntentSuppressesTheFirstBeforeTheNewReadFinishes() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), a = HeldImage(), b = HeldImage()
        let red = try png(red: true), blue = try png(red: false)
        let first = copier.begin(on: board)
        var reportsA: [Bool] = [], reportsB: [Bool] = []
        let taskA = Task { await copier.copy(first, read: { await a.read() }) { reportsA.append($0) } }
        await a.started()
        let second = copier.begin(on: board), before = board.changeCount
        let taskB = Task { await copier.copy(second, read: { await b.read() }) { reportsB.append($0) } }
        await b.started()
        a.resolve(red)
        let outcomeA = await taskA.value
        let stillOriginal = board.changeCount == before && board.string(forType: .string) == "original"
        b.resolve(blue)
        let outcomeB = await taskB.value
        #expect(outcomeA == .superseded && reportsA.isEmpty && stillOriginal)
        #expect(outcomeB == .copied && reportsB == [true])
        try checkImage(board, red: false)
    }

    @Test func entryOrderIsBoundBeforeEitherTaskStartsReading() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), data = try png(red: false)
        let first = copier.begin(on: board), second = copier.begin(on: board)
        var firstReads = 0, reports: [Bool] = []
        let old = await copier.copy(first, read: { firstReads += 1; return data }) { reports.append($0) }
        let current = await copier.copy(second, read: { data }) { reports.append($0) }
        #expect(old == .superseded && firstReads == 0)
        #expect(current == .copied && reports == [true])
        try checkImage(board, red: false)
    }

    @Test(arguments: [false, true])
    func supersededMissingOrInvalidDataDoesNotReportAnOldFailure(invalid: Bool) async {
        let board = board()
        defer { board.releaseGlobally() }
        let copier = ImageCopy(), held = HeldImage(), request = copier.begin(on: board)
        var reports: [Bool] = []
        let task = Task { await copier.copy(request, read: { await held.read() }) { reports.append($0) } }
        await held.started()
        board.clearContents()
        board.setString("new owner", forType: .string)
        let newer = board.changeCount
        held.resolve(invalid ? Data([0, 1, 2]) : nil)
        let outcome = await task.value
        #expect(outcome == .superseded && reports.isEmpty)
        #expect(board.changeCount == newer && board.string(forType: .string) == "new owner")
    }

    @Test func ticketsCannotBeConsumedByAnotherHelper() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        let first = ImageCopy(), second = ImageCopy(), data = try png(red: true)
        let a = first.begin(on: board), b = second.begin(on: board), before = board.changeCount
        var reads = 0, reports: [Bool] = []
        let outcomeA = await first.copy(b, read: { reads += 1; return data }) { reports.append($0) }
        let outcomeB = await second.copy(a, read: { reads += 1; return data }) { reports.append($0) }
        #expect(outcomeA == .superseded && outcomeB == .superseded && reads == 0 && reports.isEmpty)
        #expect(board.changeCount == before && board.string(forType: .string) == "original")
    }

    @Test func requestKeepsItsExactPasteboard() async throws {
        let target = board(), unrelated = board("other")
        defer { target.releaseGlobally(); unrelated.releaseGlobally() }
        let copier = ImageCopy(), held = HeldImage(), data = try png(red: true)
        let request = copier.begin(on: target)
        var reports: [Bool] = []
        let task = Task { await copier.copy(request, read: { await held.read() }) { reports.append($0) } }
        await held.started()
        unrelated.clearContents()
        unrelated.setString("new unrelated", forType: .string)
        let untouched = unrelated.changeCount
        held.resolve(data)
        let outcome = await task.value
        #expect(outcome == .copied && reports == [true])
        try checkImage(target, red: true)
        #expect(unrelated.changeCount == untouched && unrelated.string(forType: .string) == "new unrelated")
    }
}
