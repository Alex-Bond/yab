import AppKit
import CryptoKit
import Foundation

/// Small, editable changes over immutable source bytes. Saving typing or a
/// viewport never asks PDFKit to rewrite a possibly very large PDF.
struct PDFWorkingState: Codable {
    struct Field: Codable {
        var page: Int
        var annotation: Int
        var name: String
        var value: String
        var button: Int
    }
    struct Mark: Codable {
        var page: Int
        var bounds: CGRect
        var text: String
        var font: String?
        var size: CGFloat
        var signature: Data?
    }
    struct Viewport: Codable, Equatable {
        var page: Int
        var point: CGPoint
        var scale: CGFloat
    }
    var fields: [Field]
    var marks: [Mark]
    var mode: String
    var current: Int?
    var draft: String
    var writing: Int?
    var note: String
    var lastPage: Int
    var changed: Bool
    var viewport: Viewport?
    /// Finished copies can still be edited with Fill & Sign, but must not
    /// automatically reopen an unfinished mode on the next launch.
    var active = true
    var mail: PDFMailOrigin?
}

/// All disk IO is ordered on one queue. A discard follows every earlier
/// save, and stops this owner scheduling another one. Atomic state writes
/// leave the last good draft readable if a later write fails.
final class PDFWorkingCopy {
    static let root = Store.folder.appendingPathComponent("pdf-working", isDirectory: true)
    private static let io = DispatchQueue(label: "dev.yab.pdf-working", qos: .utility)
    private struct Record: Codable {
        var format = 1
        var digest: String
        var state: PDFWorkingState
    }
    let folder: URL
    let digest: String
    private let original: Data

    init(original: Data, source: URL?, owner: UUID, root: URL = PDFWorkingCopy.root) {
        self.original = original
        digest = Self.hash(original)
        var normalized = source.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        normalized?.fragment = nil
        let identity = owner.uuidString + "\n" + (normalized?.string ?? "")
        folder = root.appendingPathComponent(Self.hash(Data(identity.utf8)), isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func load() -> PDFWorkingState? {
        Self.io.sync {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
                  let record = try? JSONDecoder().decode(Record.self, from: data), record.format == 1,
                  record.digest == digest,
                  let bytes = try? Data(contentsOf: folder.appendingPathComponent("original.pdf")), bytes == original else { return nil }
            return record.state
        }
    }

    func save(_ state: PDFWorkingState, wait: Bool = false, completion: @escaping (String?) -> Void = { _ in }) {
        let operation = { [self] in
            do {
                let files = FileManager.default
                try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let source = folder.appendingPathComponent("original.pdf")
                if !files.fileExists(atPath: source.path) {
                    try original.write(to: source, options: .atomic)
                    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
                }
                let data = try JSONEncoder().encode(Record(digest: digest, state: state))
                let target = folder.appendingPathComponent("state.json")
                try data.write(to: target, options: .atomic)
                try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
        if wait { Self.io.sync(execute: operation) } else { Self.io.async(execute: operation) }
    }

    func discard(wait: Bool = false) {
        let operation = { [folder] in
            do {
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
            } catch { NSLog("PDF working copy discard: %@", error.localizedDescription) }
        }
        if wait { Self.io.sync(execute: operation) } else { Self.io.async(execute: operation) }
    }
}
