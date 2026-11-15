import Testing
@testable import Fast

@MainActor
struct FieldUnderTests {
    /// Search stays on and in the list; Ask and Task turn off and keep their
    /// place; only what was added can go.
    @Test func searchStaysAndAddedRowsGo() {
        let under = FieldUnder.shared
        let rows = under.rows, off = under.off
        defer {
            under.rows = rows
            for row in FieldUnder.standard { under.set(row, on: !off.contains(row)) }
        }
        under.rows = FieldUnder.standard
        under.set(FieldUnder.ask, on: true)

        under.remove(FieldUnder.search)
        under.remove(FieldUnder.ask)
        #expect(under.rows == FieldUnder.standard)

        under.set(FieldUnder.search, on: false)
        #expect(!under.off.contains(FieldUnder.search))

        under.set(FieldUnder.ask, on: false)
        #expect(under.off.contains(FieldUnder.ask))
        #expect(under.rows == FieldUnder.standard)

        under.add("place:history")
        under.remove("place:history")
        #expect(under.rows == FieldUnder.standard)
    }
}
