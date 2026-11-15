import AppKit

/// One pending Copy Image intent across windows. A later copy, or anything
/// else put on its pasteboard while the image loads, keeps ownership.
@MainActor
final class ImageCopy {
    static let shared = ImageCopy()

    struct Request {
        fileprivate let id: UUID
        fileprivate let board: NSPasteboard
        fileprivate let count: Int
    }

    enum Outcome: Equatable { case copied, failed, superseded }
    private var latest: UUID?

    /// Called at command entry, before its asynchronous task is scheduled.
    func begin(on board: NSPasteboard) -> Request {
        let id = UUID()
        latest = id
        return Request(id: id, board: board, count: board.changeCount)
    }

    private func owns(_ request: Request) -> Bool {
        latest == request.id && request.board.changeCount == request.count
    }

    /// Reporting is in the same main-actor turn as the guarded write. The
    /// caller must not announce an old result after another await boundary.
    func copy(_ request: Request, read: @MainActor () async -> Data?,
              report: @MainActor (Bool) -> Void) async -> Outcome {
        guard owns(request) else { return .superseded }
        let data = await read()
        guard owns(request) else { return .superseded }
        let image = data.flatMap { NSImage(data: $0) }
        guard owns(request) else { return .superseded }
        guard let image else {
            report(false)
            return .failed
        }
        request.board.clearContents()
        let wrote = request.board.writeObjects([image])
        report(wrote)
        return wrote ? .copied : .failed
    }
}
