import Foundation
import Observation

/// Locally created public conversations. Sync histories keep their own journal.
/// This file never changes the browser profile, website namespace or sync keys.
@MainActor
@Observable
final class LocalChatProfile {
    struct Entry: Codable, Equatable, Sendable {
        enum Origin: String, Codable, Sendable { case localPublic }
        var origin: Origin = .localPublic
        var chat: Chat
        var draft: String = ""
        /// Only the locally authored prefix is stored after a Mac handoff.
        var remoteChat: Chat.ID? = nil

        var isValid: Bool {
            origin == .localPublic && LocalChatProfile.isLocalID(chat.id) && !chat.ephemeral && chat.task == nil
                && (remoteChat == nil || LocalChatProfile.isRemoteID(remoteChat!))
        }

        /// An interrupted local model turn cannot resume by replaying a send.
        func checkpoint() -> Entry {
            var saved = self
            saved.chat.messages = chat.messages.map { message in
                guard message.role == .typing || message.role == .wait else { return message }
                return Message(role: .note, text: "This answer was interrupted. Ask again to continue.")
            }
            return saved
        }
    }

    private struct Snapshot: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry] = []

        var isValid: Bool {
            let remotes = entries.compactMap(\.remoteChat)
            return version == 1 && entries.allSatisfy(\.isValid)
                && Set(entries.map { $0.chat.id }).count == entries.count && Set(remotes).count == remotes.count
        }
    }

    nonisolated static let maximumBytes = 16 * 1024 * 1024
    let file: URL
    private var snapshot: Snapshot
    private(set) var lastWriteError: String?
    @ObservationIgnored private let writer: Writer
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let preservesUnreadableFile: Bool

    init(folder: URL, maximumBytes: Int = LocalChatProfile.maximumBytes) {
        let maximumBytes = max(1, maximumBytes)
        let file = folder.appendingPathComponent("local-chats.json")
        self.file = file
        var preserve = false
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
                saved.entries.removeAll { $0.remoteChat?.hasPrefix("c:") == true }
                guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
                snapshot = saved
            } catch {
                // Keep the original bytes for recovery; an empty launch is not
                // evidence that the person's existing conversations were empty.
                snapshot = Snapshot()
                preserve = true
                lastWriteError = "Local conversations could not be read. The saved file was kept."
            }
        } else {
            snapshot = Snapshot()
        }
        preservesUnreadableFile = preserve
        writer = Writer(file: file, maximumBytes: maximumBytes)
    }

    var entries: [Entry] { snapshot.entries }

    /// Mac heads use a:. A local prefix retains its original public ID.
    nonisolated static func isLocalID(_ id: Chat.ID) -> Bool {
        !id.isEmpty && !id.hasPrefix("a:") && !id.hasPrefix("c:")
    }

    nonisolated static func isRemoteID(_ id: Chat.ID) -> Bool {
        id.hasPrefix("a:") && id.count > 2
    }

    func capture(_ entries: [Entry]) {
        guard !preservesUnreadableFile else { return }
        let next = Snapshot(entries: entries.filter(\.isValid).map { $0.checkpoint() })
        guard next.isValid, next != snapshot else { return }
        snapshot = next
        revision += 1
        let revision = revision
        Task { [weak self, writer] in
            do {
                try await writer.write(next, revision: revision)
                self?.lastWriteError = nil
            } catch {
                self?.lastWriteError = "Local conversations could not be saved. Try again before closing Yab."
            }
        }
    }

    /// Backgrounding awaits the latest checkpoint alongside the browser profile.
    func flush() async {
        guard !preservesUnreadableFile else { return }
        revision += 1
        do {
            try await writer.write(snapshot, revision: revision)
            lastWriteError = nil
        } catch {
            lastWriteError = "Local conversations could not be saved. Try again before closing Yab."
        }
    }

    private actor Writer {
        let file: URL
        let maximumBytes: Int
        var writtenRevision = -1

        init(file: URL, maximumBytes: Int) {
            self.file = file
            self.maximumBytes = maximumBytes
        }

        func write(_ snapshot: Snapshot, revision: Int) throws {
            guard revision > writtenRevision else { return }
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            writtenRevision = revision
        }
    }
}
