import AppKit
import Foundation
import UniformTypeIdentifiers

// Files a mail carries out (docs/mail.md, Files, Going out): picked with the
// paperclip or ⇧⌘U, dropped on the mail being written, or a picture pasted
// into its words. Each is copied at once beside the account's store, in
// mail/<account>.noindex/drafts/<draft>/<file>/<its name>, and listed with the
// draft (`draft_files`), so a draft keeps its files across a quit and a
// send taken back (⌘Z) comes back with its chips; the copies go when the
// mail does, and Disconnect deletes them with the store. A forward carries
// the files of the mail it forwards, and a reply those of the mail it
// answers when asked (⌘K, Include Original Attachments): not copied, but
// fetched from Gmail as the mail goes (MailFiles). Gmail takes 25 MB of
// files in a mail; more is refused before it is sent, in words over Send.

/// A file a draft carries: one attached here, its copy kept beside the
/// account's store until the mail goes, or one of another mail's, by that
/// mail's id and part, fetched from Gmail as it goes.
public struct MailDraftFile: Equatable, Hashable, Sendable {
    /// Its own id in the draft: for one attached here, the folder its copy
    /// is kept in.
    public var id: String
    public var name: String
    public var mime: String
    /// Bytes, as Gmail counts them against its 25 MB.
    public var size: Int
    /// Another mail's file: that mail's Gmail id and its part; "" for one
    /// attached here.
    public var message = ""
    public var part = ""

    /// One of the mail forwarded or answered, not a copy of its own.
    public var original: Bool { !message.isEmpty }
    /// Its size as people read it: "340 KB", "1.2 MB".
    public var said: String { MailAttach.said(size) }
    /// Its kind, by its name first, else by what it says it is, as a mail's
    /// file's (MailFile.type).
    public var type: UTType {
        let ext = (name as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? UTType(mimeType: mime) ?? .data
    }

    /// Another mail's file, as a draft carries it: that mail's id and the
    /// file's part, fetched from Gmail as the draft goes.
    public init(original file: MailFile, of message: String) {
        self.init(id: "mail-" + MailFiles.safe(message) + "-" + MailFiles.safe(file.part), name: file.name, mime: file.mime,
                  size: file.size, message: message, part: file.part)
    }

    public init(id: String, name: String, mime: String, size: Int, message: String = "", part: String = "") {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = size
        self.message = message
        self.part = part
    }
}

public enum MailAttach {
    /// The most Gmail takes in one mail's files, as it counts them.
    public static let most = 25_000_000

    /// A draft's files together, in bytes, as Gmail counts them.
    public static func size(_ files: [MailDraftFile]) -> Int { files.reduce(0) { $0 + $1.size } }

    /// Why a draft's files can't go, in words over Send; nil when they can.
    public static func tooBig(_ files: [MailDraftFile]) -> String? {
        let total = size(files)
        return total > most ? "Too big to send: \(said(total)) of files, Gmail takes \(said(most))" : nil
    }

    /// A size as people read it, as the Finder counts: "26.9 MB".
    public static func said(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// What a file is, by its name, as a mail says it ("application/pdf");
    /// bytes of no kind the Mac knows, application/octet-stream.
    public static func mime(_ name: String, _ type: UTType? = nil) -> String {
        (type ?? UTType(filenameExtension: (name as NSString).pathExtension))?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: - where they are kept

    /// Where an account's drafts keep their files: beside its store, out of
    /// Spotlight, mail/<account>.noindex/drafts (MailStore.beside). None
    /// for a store kept in memory.
    public static func folder(for store: MailStore) -> URL? {
        store.file == MailStore.memory ? nil : MailStore.beside(store.file).appendingPathComponent("drafts", isDirectory: true)
    }

    /// One draft's: mail/<account>.noindex/drafts/<draft>.
    public static func folder(for store: MailStore, draft: String) -> URL? {
        folder(for: store)?.appendingPathComponent(MailFiles.safe(draft), isDirectory: true)
    }

    /// Where a file of a draft is kept: a folder of its own, under its own
    /// name (MailFiles.safe, as a mail's files are), so two files of one
    /// name never meet.
    public static func place(_ file: MailDraftFile, draft: String, store: MailStore) -> URL? {
        folder(for: store, draft: draft)?.appendingPathComponent(MailFiles.safe(file.id), isDirectory: true)
            .appendingPathComponent(MailFiles.safe(file.name))
    }

    // MARK: - taking them

    /// Files picked, dropped or pasted, copied into a draft's folder: a
    /// chip each, in order. A folder, or what can't be read, is left out.
    public static func take(_ urls: [URL], draft: String, store: MailStore) -> [MailDraftFile] {
        urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
                  values.isRegularFile == true else { return nil }
            let name = url.lastPathComponent
            return keep(draft: draft, store: store, name: name, mime: mime(name, values.contentType)) { into in
                try FileManager.default.copyItem(at: url, to: into)
            }
        }
    }

    /// A picture pasted into the words: kept as a PNG, "Pasted image.png",
    /// then "Pasted image 2.png" beside one of that name.
    public static func take(picture: Data, draft: String, beside files: [MailDraftFile], store: MailStore) -> MailDraftFile? {
        let png = NSBitmapImageRep(data: picture)?.representation(using: .png, properties: [:]) ?? picture
        let names = Set(files.map(\.name))
        var name = "Pasted image.png", n = 1
        while names.contains(name) {
            n += 1
            name = "Pasted image \(n).png"
        }
        return keep(draft: draft, store: store, name: name, mime: "image/png") { into in try png.write(to: into) }
    }

    /// A file written into a folder of its own in the draft's, as `write`
    /// puts it there; nil when it couldn't be.
    private static func keep(draft: String, store: MailStore, name: String, mime: String, write: (URL) throws -> Void) -> MailDraftFile? {
        var file = MailDraftFile(id: String(UUID().uuidString.prefix(8)).lowercased(), name: name, mime: mime, size: 0)
        guard let into = place(file, draft: draft, store: store) else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: into.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(into)
            file.size = (try into.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        } catch {
            try? fm.removeItem(at: into.deletingLastPathComponent())
            return nil
        }
        return file
    }

    /// A file taken off a draft (⌫ on its chip, or its ×): its copy gone.
    /// Another mail's has none.
    public static func remove(_ file: MailDraftFile, draft: String, store: MailStore) {
        guard !file.original, let place = place(file, draft: draft, store: store) else { return }
        try? FileManager.default.removeItem(at: place.deletingLastPathComponent())
    }

    /// A draft's copies under the id it is kept by now (MailStore.rename).
    public static func move(draft: String, to new: String, store: MailStore) {
        guard let from = folder(for: store, draft: draft), let to = folder(for: store, draft: new),
              FileManager.default.fileExists(atPath: from.path) else { return }
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    /// A draft's copies gone, once its mail went.
    public static func drop(draft: String, store: MailStore) {
        guard let folder = folder(for: store, draft: draft) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Disconnect: every draft's files of an account gone with its store
    /// (the store's file).
    public static func forget(store file: URL) {
        try? FileManager.default.removeItem(at: MailStore.beside(file).appendingPathComponent("drafts", isDirectory: true))
    }

    /// Copies of drafts the store no longer keeps (a mail that went as Yab
    /// quit before they were taken away): gone, when the account starts.
    public static func sweep(_ store: MailStore) {
        guard let root = folder(for: store), let kept = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        let live = Set(store.draftsWithFiles().map(MailFiles.safe))
        for name in kept where !live.contains(name) { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
    }

    /// The files a mail carries that a forward or a reply takes with it:
    /// its chips, not the pictures its words draw. None while its parts
    /// aren't read here (MailMessage.files nil).
    public static func originals(of message: MailMessage) -> [MailDraftFile] {
        (message.files ?? []).filter { !$0.inline }.map { MailDraftFile(original: $0, of: message.id) }
    }

    // MARK: - as they go

    /// A draft's files as its message carries them: its own copies read
    /// from here, another mail's fetched from Gmail (MailFiles).
    public static func parts(of draft: MailDraft, store: MailStore, provider: any MailProvider) async throws -> [MailCompose.Attached] {
        var out: [MailCompose.Attached] = []
        for file in draft.files {
            let data: Data
            if file.original {
                data = try await original(file, store: store, provider: provider)
            } else {
                guard let place = place(file, draft: draft.id, store: store), let read = try? Data(contentsOf: place) else {
                    throw MailTrouble.unreadable
                }
                data = read
            }
            out.append(MailCompose.Attached(name: file.name, mime: file.mime, data: data))
        }
        return out
    }

    /// Another mail's file, its bytes as Gmail keeps them: the copy kept
    /// on this Mac (MailFiles), fetched first when it isn't here.
    private static func original(_ file: MailDraftFile, store: MailStore, provider: any MailProvider) async throws -> Data {
        guard let files = MailFiles.of(store, provider) else { throw MailTrouble.unreadable }
        return try await files.data(message: file.message, part: file.part)
    }
}
