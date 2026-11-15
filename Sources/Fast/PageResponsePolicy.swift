import Foundation

enum PageResponsePolicy {
    static func decide(_ response: URLResponse, canShowMIMEType: Bool) -> PagePolicy {
        if let http = response as? HTTPURLResponse {
            // A process handoff can deliver an empty response before the
            // real headers arrive. It is not an unsupported file type.
            if http.statusCode == 0 || (300...399).contains(http.statusCode) { return .allow }
            if let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
               disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
                return .download
            }
        }
        // WebKit cannot classify a response without a type. Turning that
        // into a download interrupts the document and can leave only its
        // head on screen, with neither content nor a loading indicator.
        guard let type = response.mimeType, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .allow
        }
        return canShowMIMEType ? .allow : .download
    }
}
