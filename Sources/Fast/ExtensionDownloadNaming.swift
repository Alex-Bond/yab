import Foundation

/// The filename event is a request, not a notification. Its native owner
/// waits for each extension's one reply or for that context to go away.
@MainActor
enum ExtensionDownloadNaming {
    private struct Pending {
        let order: [String]
        var waiting: Set<String>
        var suggestions: [String: String] = [:]
        let reply: (String?) -> Void
    }
    private static var pending: [String: Pending] = [:]

    static func begin(extensions: [String], reply: @escaping (String?) -> Void) -> String? {
        guard !extensions.isEmpty else { reply(nil); return nil }
        let request = UUID().uuidString
        pending[request] = Pending(order: extensions, waiting: Set(extensions), reply: reply)
        return request
    }

    static func suggest(_ request: String, by id: String, filename: String?) {
        guard var item = pending[request], item.waiting.remove(id) != nil else { return }
        if let filename, let safe = DownloadRequest.relativeFilename(filename) { item.suggestions[id] = safe }
        if item.waiting.isEmpty {
            pending[request] = nil
            // The caller supplies installation order, preserved across updates.
            // Like Chrome, the most recently installed suggesting extension wins.
            item.reply(item.order.reversed().compactMap { item.suggestions[$0] }.first)
        } else { pending[request] = item }
    }

    static func unloaded(_ id: String) {
        for request in Array(pending.keys) { suggest(request, by: id, filename: nil) }
    }

    static func cancel(_ request: String) {
        pending.removeValue(forKey: request)?.reply(nil)
    }
}
