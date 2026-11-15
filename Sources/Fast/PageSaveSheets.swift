import Foundation
import WebKit

// "Export this table to Excel": save_page's csv and xlsx (docs/agent-asks.md).
// The page's tables, an HTML table or an ARIA grid as a person sees it,
// read as rows of cell text; one table as a CSV, or any of them as an Excel
// workbook, a sheet each. With more than one and none chosen, save_page
// answers with the list and the agent asks which.
//
// The workbook is written here: a zip of a few XML parts, stored, not
// deflated, with no dependency. Cells that are plain numbers are numbers;
// everything else, "$1,200" included, stays text as the page wrote it.

extension PageSave {
    /// One table of a page: what it is called and its rows of cell text.
    struct Table: Equatable {
        var name: String
        var rows: [[String]]
        /// "12 rows × 4"
        var size: String { "\(rows.count) rows × \(rows.map(\.count).max() ?? 0)" }
    }

    /// The page's tables, the ones a person can see, at most 20.
    static func tables(_ tab: Tab, done: @escaping @MainActor (Result<[Table], Error>) -> Void) {
        AgentPage.run(tab, readTables) { result in
            switch result {
            case .success(let value):
                let found = (value as? [[String: Any]] ?? []).compactMap { one -> Table? in
                    guard let rows = one["rows"] as? [[String]], !rows.isEmpty else { return nil }
                    return Table(name: one["name"] as? String ?? "", rows: rows)
                }
                done(.success(found))
            case .failure(let error):
                done(.failure(error))
            }
        }
    }

    /// Which tables a `table` choice means: "2", "all", or nil for the only one.
    nonisolated static func pick(_ said: String?, from tables: [Table], format: String) -> Result<[Table], Failure>? {
        guard !tables.isEmpty else { return .failure(Failure("This page has no tables to save")) }
        let words = (said ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if words.isEmpty { return tables.count == 1 ? .success(tables) : nil }
        if words == "all" {
            return format == "csv" && tables.count > 1 ? .failure(Failure("A CSV holds one table: pick one, or use xlsx for all of them")) : .success(tables)
        }
        let numbers = words.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ (1...tables.count).contains($0) }) else {
            return .failure(Failure("table is a number from 1 to \(tables.count), or all"))
        }
        if format == "csv", numbers.count > 1 { return .failure(Failure("A CSV holds one table: pick one, or use xlsx")) }
        return .success(numbers.map { tables[$0 - 1] })
    }

    /// The list save_page answers with when it has to ask which.
    nonisolated static func listing(_ tables: [Table]) -> String {
        tables.enumerated().map { "\($0.offset + 1). \($0.element.name.isEmpty ? "Table \($0.offset + 1)" : $0.element.name) · \($0.element.size)" }
            .joined(separator: "\n")
    }

    /// Saves the chosen tables of the tab's page as csv or xlsx.
    static func sheets(_ tab: Tab, as format: String, table said: String?, in folder: URL,
                       done: @escaping @MainActor (Result<URL, Error>) -> Void, ask: @escaping @MainActor ([Table]) -> Void) {
        tables(tab) { result in
            switch result {
            case .failure(let error):
                done(.failure(error))
            case .success(let found):
                guard let chosen = pick(said, from: found, format: format) else { return ask(found) }
                switch chosen {
                case .failure(let failure): done(.failure(failure))
                case .success(let tables):
                    let title = tables.count == 1 && found.count > 1 && !tables[0].name.isEmpty ? "\(tab.title) - \(tables[0].name)" : tab.title
                    let file = Self.file(title: title, host: tab.address?.host() ?? "", format: format, in: folder)
                    let data = format == "csv" ? csv(tables[0].rows) : xlsx(tables)
                    do { try data.write(to: file); done(.success(file)) } catch { done(.failure(error)) }
                }
            }
        }
    }

    // MARK: - CSV

    /// RFC 4180, with a byte-order mark so Excel reads it as UTF-8.
    nonisolated static func csv(_ rows: [[String]]) -> Data {
        let lines = rows.map { row in
            row.map { cell in
                cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    // MARK: - Excel

    /// A workbook, a sheet a table, the first row bold.
    nonisolated static func xlsx(_ tables: [Table]) -> Data {
        let names = sheetNames(tables.map(\.name))
        var parts: [(String, String)] = []
        parts.append(("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(names.indices.map { "<Override PartName=\"/xl/worksheets/sheet\($0 + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }.joined())\
        </Types>
        """))
        parts.append(("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """))
        parts.append(("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\
        \(names.enumerated().map { "<sheet name=\"\(escape($0.element))\" sheetId=\"\($0.offset + 1)\" r:id=\"rId\($0.offset + 1)\"/>" }.joined())\
        </sheets></workbook>
        """))
        parts.append(("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(names.indices.map { "<Relationship Id=\"rId\($0 + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\($0 + 1).xml\"/>" }.joined())\
        <Relationship Id="rId\(names.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        </Relationships>
        """))
        parts.append(("xl/styles.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        </styleSheet>
        """))
        for (index, table) in tables.enumerated() {
            parts.append(("xl/worksheets/sheet\(index + 1).xml", sheet(table.rows)))
        }
        return Zip.stored(parts.map { ($0.0, Data($0.1.utf8)) })
    }

    nonisolated static func sheet(_ rows: [[String]]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if rows.count > 1 { xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>" }
        xml += "<sheetData>"
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, cell) in row.enumerated() where !cell.isEmpty {
                let ref = column(c) + String(r + 1)
                let style = r == 0 ? " s=\"1\"" : ""
                if r > 0, let number = number(cell) {
                    xml += "<c r=\"\(ref)\"\(style)><v>\(number)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(escape(cell))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    /// A cell that is only a number, as Excel writes it; nil for anything
    /// else, a currency, a percent or a leading zero (a code) included.
    nonisolated static func number(_ cell: String) -> String? {
        let plain = cell.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard plain.range(of: #"^-?(0|[1-9]\d*)(\.\d+)?$"#, options: .regularExpression) != nil,
              cell.range(of: #"^-?\d{1,3}(,\d{3})*(\.\d+)?$|^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil,
              plain.count <= 15 else { return nil }
        return plain
    }

    /// A, B, … Z, AA, AB …
    nonisolated static func column(_ index: Int) -> String {
        var n = index + 1, out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(65 + r)!) + out
            n = (n - 1) / 26
        }
        return out
    }

    /// Sheet names Excel takes: 31 letters, none of []:*?/\, each once.
    nonisolated static func sheetNames(_ said: [String]) -> [String] {
        var used = Set<String>()
        return said.enumerated().map { index, name in
            let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "[]:*?/\\")).joined(separator: " ")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var base = String(cleaned.prefix(31)).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
            if base.isEmpty { base = "Table \(index + 1)" }
            var out = base, n = 2
            while used.contains(out.lowercased()) {
                let tail = " \(n)"
                out = String(base.prefix(31 - tail.count)) + tail
                n += 1
            }
            used.insert(out.lowercased())
            return out
        }
    }

    nonisolated static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                // XML 1.0 has no place for other control characters.
                if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Every visible table and grid: its name (caption, label, the heading
    /// before it, else its first row) and its rows of cell text, a cell
    /// spanning columns written once and then left empty.
    static let readTables = """
    const seen = (el) => !(el.checkVisibility && !el.checkVisibility());
    const words = (el) => (el.innerText || el.textContent || '').replace(/\\s+/g, ' ').trim();
    const cellsOf = (row, grid) => grid
      ? Array.from(row.querySelectorAll('[role=cell],[role=gridcell],[role=columnheader],[role=rowheader]')).filter((c) => c.closest('[role=row]') === row)
      : Array.from(row.cells);
    const heading = (t) => {
      for (let up = t, depth = 0; up && depth < 4; up = up.parentElement, depth++) {
        for (let back = up.previousElementSibling, n = 0; back && n < 4; back = back.previousElementSibling, n++) {
          if (/^H[1-6]$/.test(back.tagName)) return words(back);
          const inner = back.querySelector && back.querySelector('h1,h2,h3,h4,h5,h6');
          if (inner && back.textContent.length < 400) return words(inner);
        }
      }
      return '';
    };
    const out = [];
    for (const t of document.querySelectorAll('table, [role=table], [role=grid], [role=treegrid]')) {
      if (out.length >= 20 || !seen(t)) continue;
      const grid = t.tagName !== 'TABLE';
      if (!grid && t.querySelector('table')) continue;
      if (grid && t.closest('table')) continue;
      const rows = [];
      const list = grid ? Array.from(t.querySelectorAll('[role=row]')).filter((r) => r.closest('[role=table],[role=grid],[role=treegrid]') === t) : Array.from(t.rows);
      for (const row of list) {
        if (rows.length >= 5000) break;
        if (!seen(row)) continue;
        const cells = [];
        for (const cell of cellsOf(row, grid)) {
          cells.push(words(cell));
          const span = Math.min(+(cell.getAttribute('colspan') || 1) || 1, 50);
          for (let i = 1; i < span; i++) cells.push('');
        }
        if (cells.some((c) => c)) rows.push(cells);
      }
      const width = Math.max(0, ...rows.map((r) => r.length));
      if (rows.length < 2 || width < 2) continue;
      const caption = t.tagName === 'TABLE' && t.caption ? words(t.caption) : '';
      const labelled = t.getAttribute('aria-labelledby');
      const label = t.getAttribute('aria-label') || (labelled && document.getElementById(labelled) ? words(document.getElementById(labelled)) : '');
      const name = (caption || label || heading(t) || rows[0].filter((c) => c).slice(0, 3).join(', ')).slice(0, 80);
      out.push({ name, rows });
    }
    return out;
    """
}

/// A zip of files stored as they are, what an .xlsx is.
enum Zip {
    nonisolated static func stored(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        for (name, data) in files {
            let path = Data(name.utf8)
            let crc = crc32(data)
            let offset = UInt32(out.count)
            var local = Data()
            local.append(le32(0x04034b50)); local.append(le16(20)); local.append(le16(0x0800)); local.append(le16(0))
            local.append(le16(0)); local.append(le16(0x21))
            local.append(le32(crc)); local.append(le32(UInt32(data.count))); local.append(le32(UInt32(data.count)))
            local.append(le16(UInt16(path.count))); local.append(le16(0))
            out.append(local); out.append(path); out.append(data)
            var entry = Data()
            entry.append(le32(0x02014b50)); entry.append(le16(20)); entry.append(le16(20)); entry.append(le16(0x0800)); entry.append(le16(0))
            entry.append(le16(0)); entry.append(le16(0x21))
            entry.append(le32(crc)); entry.append(le32(UInt32(data.count))); entry.append(le32(UInt32(data.count)))
            entry.append(le16(UInt16(path.count))); entry.append(le16(0)); entry.append(le16(0)); entry.append(le16(0)); entry.append(le16(0))
            entry.append(le32(0)); entry.append(le32(offset))
            central.append(entry); central.append(path)
        }
        let start = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.append(le32(0x06054b50)); end.append(le16(0)); end.append(le16(0))
        end.append(le16(UInt16(files.count))); end.append(le16(UInt16(files.count)))
        end.append(le32(UInt32(central.count))); end.append(le32(start)); end.append(le16(0))
        out.append(end)
        return out
    }

    private nonisolated static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    nonisolated static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    private nonisolated static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private nonisolated static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
