import Foundation

/// The selected words belong to one opening of Find. A reply from a closed
/// opening must not replace the words in the next one.
@MainActor
final class FindSelectionRequest {
    typealias Reply = ([String: Any]?) -> Void
    private var pending: UUID?

    func request(send: (@escaping Reply) -> Void, receive: @escaping Reply) {
        let id = UUID()
        pending = id
        send { [weak self] answer in
            guard let self, pending == id else { return }
            // Consume before delivery: delivery can open another request.
            pending = nil
            receive(answer)
        }
    }

    func cancel() { pending = nil }
}
