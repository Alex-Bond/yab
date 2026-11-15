import Foundation
import Testing
@testable import Fast

/// Exercise the persistence entry points with an in-memory adapter only.
/// Detached work can arrive late: the persisted day must never move later.
struct FirstDayPersistenceTests {
    private final class Memory {
        var data: Data?
        var writes: [Data] = []
        var lockCount = 0
        private var lockDepth = 0

        init(_ data: Data? = nil) { self.data = data }

        var storage: FirstDay.Storage {
            FirstDay.Storage(
                readData: {
                    #expect(self.lockDepth == 1, "persistent reads must occur inside the injected lock")
                    return self.data
                },
                writeData: { data in
                    #expect(self.lockDepth == 1, "persistent writes must occur inside the injected lock")
                    self.data = data
                    self.writes.append(data)
                },
                withLock: { work in
                    #expect(self.lockDepth == 0, "persistence must use one outer lock without re-entering it")
                    self.lockDepth += 1
                    self.lockCount += 1
                    defer { self.lockDepth -= 1 }
                    work()
                })
        }
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private static func data(_ day: Date) -> Data {
        Data(String(day.timeIntervalSince1970).utf8)
    }

    @Test func aDelayedLaterKeepCannotReplaceThePersistedFirstDay() {
        let memory = Memory(), early = Self.day(2026, 10, 1), later = Self.day(2026, 10, 15)
        let storage = memory.storage
        FirstDay.keep(early, using: storage)
        // This is the later task's actual write arriving after the earlier
        // task has already persisted the correct first day.
        FirstDay.keep(later, using: storage)
        let kept = FirstDay.read(using: storage)
        #expect(kept == early,
                "a delayed later keep must preserve the persisted earlier first day")
        #expect(memory.writes == [Self.data(early)],
                "a delayed later keep must not perform a redundant second write")
        #expect(memory.lockCount == 3)
    }

    @Test func anEarlierKeepReplacesALaterStoredDay() {
        let memory = Memory(), early = Self.day(2026, 10, 1), later = Self.day(2026, 10, 15)
        let storage = memory.storage
        FirstDay.keep(later, using: storage)
        FirstDay.keep(early, using: storage)
        #expect(FirstDay.read(using: storage) == early)
        #expect(memory.writes == [Self.data(later), Self.data(early)])
    }

    @Test func anEqualKeepPreservesTheStoredDay() {
        let early = Self.day(2026, 10, 1)
        let memory = Memory(Self.data(early))
        let storage = memory.storage
        FirstDay.keep(early, using: storage)
        #expect(FirstDay.read(using: storage) == early)
        #expect(memory.data == Self.data(early))
    }

    @Test func invalidStoredDataCanBeReplacedByARealDay() {
        let early = Self.day(2026, 10, 1)
        let cases: [(String, Data?)] = [
            ("missing", nil),
            ("malformed", Data("not-a-timestamp".utf8)),
            ("zero", Data("0".utf8)),
            ("negative", Data("-1".utf8)),
            ("before 2025", Self.data(Self.day(2024, 10, 1))),
            ("future", Self.data(Date().addingTimeInterval(30 * 86_400)))
        ]
        for (name, raw) in cases {
            let memory = Memory(raw)
            let storage = memory.storage
            FirstDay.keep(early, using: storage)
            #expect(FirstDay.read(using: storage) == early, "stored \(name) must not block a valid first day")
            #expect(memory.writes == [Self.data(early)], "stored \(name) must be replaced by the valid date")
        }
    }

    @Test func missingAndMalformedReadsRemainNil() {
        let cases: [(String, Data?)] = [("missing", nil), ("malformed", Data("not-a-timestamp".utf8))]
        for (name, raw) in cases {
            let memory = Memory(raw)
            let storage = memory.storage
            #expect(FirstDay.read(using: storage) == nil, "a \(name) value must not invent a first day")
            #expect(memory.writes.isEmpty)
        }
    }
}
