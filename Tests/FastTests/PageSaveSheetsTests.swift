import Foundation
import Testing
@testable import Fast

// save_page's tables (PageSaveSheets): CSV as Excel reads it, a workbook
// that unzips and holds a sheet a table, numbers as numbers, and which
// tables a `table` choice means.
struct PageSaveSheetsTests {
    let prices = PageSave.Table(name: "Prices by plan", rows: [["Plan", "Seats", "Price"], ["Team", "10", "1,200"], ["Business", "50", "$4,800"]])
    let features = PageSave.Table(name: "Feature comparison", rows: [["Feature", "Free"], ["Sync, \"fast\"", "No"], ["Zip", "02139"]])

    @Test func csvQuotesWhereItMust() {
        let data = PageSave.csv(features.rows)
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(String(decoding: data.dropFirst(3), as: UTF8.self) == "Feature,Free\r\n\"Sync, \"\"fast\"\"\",No\r\nZip,02139\r\n")
    }

    @Test func numbersOnlyWhenPlain() {
        #expect(PageSave.number("10") == "10")
        #expect(PageSave.number("1,200") == "1200")
        #expect(PageSave.number("-3.5") == "-3.5")
        #expect(PageSave.number("$4,800") == nil)
        #expect(PageSave.number("02139") == nil)
        #expect(PageSave.number("12%") == nil)
        #expect(PageSave.number("1,20") == nil)
    }

    @Test func columnsAndSheetNames() {
        #expect(PageSave.column(0) == "A")
        #expect(PageSave.column(25) == "Z")
        #expect(PageSave.column(26) == "AA")
        #expect(PageSave.column(701) == "ZZ")
        #expect(PageSave.sheetNames(["Q1: [draft]", "", "Same", "same", String(repeating: "x", count: 40)])
                == ["Q1 draft", "Table 2", "Same", "same 2", String(repeating: "x", count: 31)])
    }

    @Test func pickWhichTables() throws {
        let both = [prices, features]
        #expect(PageSave.pick(nil, from: both, format: "xlsx") == nil)
        #expect(try PageSave.pick(nil, from: [prices], format: "csv")?.get() == [prices])
        #expect(try PageSave.pick("all", from: both, format: "xlsx")?.get() == both)
        #expect(try PageSave.pick("2", from: both, format: "csv")?.get() == [features])
        if case .failure = PageSave.pick("all", from: both, format: "csv") {} else { Issue.record("a CSV can't hold all") }
        if case .failure = PageSave.pick("3", from: both, format: "xlsx") {} else { Issue.record("3 of 2") }
        #expect(PageSave.listing(both) == "1. Prices by plan · 3 rows × 3\n2. Feature comparison · 3 rows × 2")
    }

    /// The workbook unzips (unzip -t) and holds what Excel needs.
    @Test func workbookUnzips() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString.prefix(6)).xlsx")
        try PageSave.xlsx([prices, features]).write(to: file)
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tq", file.path]
        let pipe = Pipe()
        test.standardOutput = pipe
        try test.run()
        test.waitUntilExit()
        #expect(test.terminationStatus == 0, "\(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))")
        let list = Process()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        list.arguments = ["-Z1", file.path]
        let names = Pipe()
        list.standardOutput = names
        try list.run()
        list.waitUntilExit()
        let parts = String(decoding: names.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(parts == ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels", "xl/styles.xml",
                          "xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml"])
        let sheet = PageSave.sheet(prices.rows)
        #expect(sheet.contains("<c r=\"B2\"><v>10</v></c>"))
        #expect(sheet.contains("<c r=\"C2\"><v>1200</v></c>"))
        #expect(sheet.contains("<c r=\"C3\" t=\"inlineStr\"><is><t xml:space=\"preserve\">$4,800</t></is></c>"))
        #expect(sheet.contains("<c r=\"A1\" s=\"1\" t=\"inlineStr\">"))
        #expect(PageSave.escape("a < b & \"c\"\u{1}") == "a &lt; b &amp; &quot;c&quot;")
    }

    @Test func crcMatchesZlib() {
        #expect(Zip.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)) == 0x414FA339)
    }

    /// Pages cut between lines: never through one, at the limit when one
    /// thing is taller than half a page.
    @Test func breaksFallBetweenLines() {
        var lines: [(CGFloat, CGFloat)] = []
        for n in 0..<40 {
            let top = CGFloat(n * 25 + 5)
            lines.append((top, top + 20))
        }
        let cuts = PageSave.breaks(spans: lines, height: 1000, room: 310)
        #expect(cuts == [305, 605, 905])
        for cut in cuts { #expect(!lines.contains { $0.0 < cut && $0.1 > cut }) }
        #expect(PageSave.breaks(spans: [(10, 900)], height: 1000, room: 300) == [300, 600, 900])
        #expect(PageSave.breaks(spans: [], height: 200, room: 300) == [])
    }

    @MainActor @Test func formatsSaid() {
        #expect(PageSave.format("Excel") == "xlsx")
        #expect(PageSave.format("CSV") == "csv")
        #expect(PageSave.formats.contains("xlsx"))
    }
}
