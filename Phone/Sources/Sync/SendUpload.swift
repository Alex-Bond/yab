import Foundation
import SyncKit

/// A photo or file going with words to a Mac's chat, its bytes ready: a
/// photo already made a JPEG of at most 2048 on its long side. PhoneSync
/// writes its parts (SyncSendFile) before the send.
public nonisolated struct SendUpload: Equatable, Sendable {
    public var name: String
    /// Its MIME type, "image/jpeg" for a photo.
    public var type: String
    public var data: Data

    public init(name: String, type: String, data: Data) {
        self.name = name; self.type = type; self.data = data
    }

    /// What stops files going: too many, one too big, all too much, or a
    /// Mac that doesn't take them.
    public nonisolated enum Failure: LocalizedError, Equatable {
        case tooMany, tooBig, tooMuch, unsupported

        public var errorDescription: String? {
            switch self {
            case .tooMany: "Up to \(SyncSendFile.mostCount) files at a time"
            case .tooBig: "A file can be up to \(SyncSendFile.most / 1_000_000) MB"
            case .tooMuch: "Up to \(SyncSendFile.mostTogether / 1_000_000) MB at a time"
            case .unsupported: "Update Yab on your Mac to send it photos and files"
            }
        }
    }

    /// Whether files of these sizes may go in one send.
    public static func check(_ sizes: [Int]) -> Failure? {
        if sizes.count > SyncSendFile.mostCount { return .tooMany }
        if sizes.contains(where: { $0 > SyncSendFile.most }) { return .tooBig }
        if sizes.reduce(0, +) > SyncSendFile.mostTogether { return .tooMuch }
        return nil
    }
}
