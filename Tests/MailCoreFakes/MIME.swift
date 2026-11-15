import Foundation
import MailCore

// Raw mail read back, as the tests check what the engine writes.

/// A message read back as a mail reader takes it apart: its head, and each
/// part of a multipart one, its head and its bytes, base64 undone; its
/// kinds and names read by the reading half's own parser (MailMime), as it
/// reads the parts Gmail gives.
public struct MIMEReading {
    public struct Part {
        public var head: [String: String]
        public var headLines: [String]
        /// Its body's lines as they stand, base64.
        public var lines: [String]
        public var data: Data
        public var type: String { MailMime.parameters(head["content-type"] ?? "").value.lowercased() }
        /// Content-Type's name, and Content-Disposition's filename, each alone.
        public var name: String? { MIMEReading.name(MailMime.filename("", disposition: [:], type: MailMime.parameters(head["content-type"] ?? "").params)) }
        public var filename: String? {
            MIMEReading.name(MailMime.filename("", disposition: MailMime.parameters(head["content-disposition"] ?? "").params, type: [:]))
        }
    }

    public static func name(_ said: String) -> String? { said.isEmpty ? nil : said }

    public var head: [String: String]
    public var parts: [Part]

    public init?(_ raw: String) {
        guard let split = raw.range(of: "\r\n\r\n") else { return nil }
        head = MIMEReading.head(String(raw[..<split.lowerBound])).fields
        let body = String(raw[split.upperBound...])
        let type = MailMime.parameters(head["content-type"] ?? "")
        guard type.value == "multipart/mixed", let boundary = type.params["boundary"] else {
            parts = [MIMEReading.part(String(raw[..<split.lowerBound]), body)]
            return
        }
        var chunks = body.components(separatedBy: "--" + boundary)
        guard chunks.count >= 3, chunks.last?.hasPrefix("--") == true else { return nil }
        chunks.removeFirst()
        chunks.removeLast()
        parts = chunks.compactMap { chunk in
            // CR LF is one Character to Swift.
            let bare = chunk.hasPrefix("\r\n") ? String(chunk.dropFirst()) : chunk
            guard let at = bare.range(of: "\r\n\r\n") else { return nil }
            return MIMEReading.part(String(bare[..<at.lowerBound]), String(bare[at.upperBound...]))
        }
    }

    public static func part(_ head: String, _ body: String) -> Part {
        let lines = body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let read = MIMEReading.head(head)
        return Part(head: read.fields, headLines: read.lines, lines: lines, data: Data(base64Encoded: lines.joined()) ?? Data())
    }

    /// A head's fields by lowercased name, folded lines unfolded.
    public static func head(_ text: String) -> (fields: [String: String], lines: [String]) {
        let lines = text.components(separatedBy: "\r\n")
        var fields: [String: String] = [:]
        var last = ""
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                fields[last, default: ""] += line
            } else if let colon = line.firstIndex(of: ":") {
                last = line[..<colon].lowercased()
                fields[last] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return (fields, lines)
    }

}

/// A message read back part by part, however its multiparts nest: each
/// part's head, its type, its parts or its bytes, base64 undone.
public struct MIMETree {
    public var head: [String: String]
    public var type: String
    public var parts: [MIMETree] = []
    public var data = Data()
    public var text: String { String(decoding: data, as: UTF8.self) }

    public init?(_ raw: String) {
        guard let split = raw.range(of: "\r\n\r\n") else { return nil }
        head = MIMEReading.head(String(raw[..<split.lowerBound])).fields
        let content = MailMime.parameters(head["content-type"] ?? "text/plain")
        type = content.value.lowercased()
        let body = String(raw[split.upperBound...])
        if type.hasPrefix("multipart/") {
            guard let boundary = content.params["boundary"] else { return nil }
            var chunks = body.components(separatedBy: "--" + boundary)
            guard chunks.count >= 3 else { return nil }
            chunks.removeFirst()
            chunks.removeLast()
            parts = chunks.compactMap { chunk in MIMETree(chunk.hasPrefix("\r\n") ? String(chunk.dropFirst()) : chunk) }
        } else {
            let lines = body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            data = head["content-transfer-encoding"] == "base64" ? Data(base64Encoded: lines.joined()) ?? Data() : Data(body.utf8)
        }
    }
}
