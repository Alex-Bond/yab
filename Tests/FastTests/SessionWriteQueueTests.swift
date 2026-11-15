import Foundation
import Testing
@testable import Fast

/// Session writes leave the main thread (docs/main-thread-budget.md): they
/// land in the order asked for, a read sees the last one, the way out waits
/// for the disk, and a file on disk is always a whole row.
@MainActor
@Suite(.serialized)
struct SessionWriteQueueTests {
    private func shape(_ n: Int, tabs: Int = 3) -> Session.Shape {
        Session.Shape(tabs: (0..<tabs).map { Session.Entry(url: "https://queue.test/\(n)/\($0)", title: "Row \(n) tab \($0)") }, active: 0)
    }

    private func space(_ body: (UUID, URL) throws -> Void) rethrows {
        let id = UUID()
        let file = Store.file("session-\(id.uuidString).json")
        defer {
            Session.settle()
            try? FileManager.default.removeItem(at: file)
        }
        try body(id, file)
    }

    @Test func waitsOnlyOnTheWayOutOrOffTheMainThread() {
        #expect(!Session.waits(now: true, main: true, landing: 0))
        #expect(Session.waits(now: true, main: true, landing: 1))
        #expect(Session.waits(now: true, main: false, landing: 0))
        #expect(!Session.waits(now: false, main: false, landing: 0))
        #expect(!Session.waits(now: false, main: true, landing: 2))
    }

    @Test func aReadSeesTheLastOfManyWritesInOrder() {
        space { id, _ in
            for n in 0..<200 { Session.write(now: n % 2 == 0, space: id, shape(n)) }
            #expect(Session.read(space: id).tabs.first?.url == "https://queue.test/199/0")
        }
    }

    @Test func aRowReadsBackAtOnceAndFromTheDiskOnceLanded() throws {
        try space { id, file in
            Session.write(now: true, space: id, shape(3, tabs: 2000))
            // Straight back, whether or not the write has landed yet.
            #expect(Session.read(space: id).tabs.first?.url == "https://queue.test/3/0")
            Session.settle()
            // Landed, the disk is what is read: a file taken away reads as none.
            try FileManager.default.removeItem(at: file)
            #expect(Session.read(space: id).tabs.isEmpty)
        }
    }

    @Test func theWayOutIsOnDiskWhenLandReturns() throws {
        try space { id, file in
            Session.write(space: id, shape(1, tabs: 400))
            Session.land { Session.write(now: true, space: id, shape(2)) }
            // Straight from the disk, not through read, which would wait.
            let data = try Data(contentsOf: file)
            let saved = try JSONDecoder().decode(Session.Shape.self, from: data)
            #expect(saved.tabs.first?.url == "https://queue.test/2/0")
        }
    }

    @Test func aSpaceErasedAfterAQueuedWriteStaysGone() {
        space { id, file in
            for n in 0..<20 { Session.write(space: id, shape(n, tabs: 200)) }
            Session.erase(space: id)
            Session.settle()
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func aFileOnDiskIsAlwaysAWholeRow() async throws {
        let id = UUID()
        let file = Store.file("session-\(id.uuidString).json")
        defer {
            Session.settle()
            try? FileManager.default.removeItem(at: file)
        }
        Session.land { Session.write(now: true, space: id, shape(0, tabs: 300)) }
        let reader = Task.detached { () -> Int in
            var broken = 0
            for _ in 0..<300 {
                if let data = try? Data(contentsOf: file), (try? JSONDecoder().decode(Session.Shape.self, from: data)) == nil { broken += 1 }
            }
            return broken
        }
        for n in 1..<150 { Session.write(space: id, shape(n, tabs: 300)) }
        #expect(await reader.value == 0)
        #expect(Session.read(space: id).tabs.count == 300)
    }

    @Test func aWriteFromTheMainThreadReturnsBeforeTheDisk() {
        space { id, _ in
            // A row long enough that encoding and writing it takes a while.
            let big = shape(7, tabs: 5000)
            let start = ProcessInfo.processInfo.systemUptime
            Session.write(now: true, space: id, big)
            let asked = ProcessInfo.processInfo.systemUptime - start
            Session.settle()
            let landed = ProcessInfo.processInfo.systemUptime - start
            #expect(asked < landed)
            #expect(Session.read(space: id).tabs.count == 5000)
        }
    }
}
