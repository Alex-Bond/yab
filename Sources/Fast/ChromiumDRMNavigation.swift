import Foundation
import YabCoreClient

/// A WebKit main-frame GET can carry its policy-filtered Referer header.
/// Preserve it on engine replacement instead of rejecting an ordinary link.
/// Other headers and request bodies still need a full request transport.
struct ChromiumDRMNavigation {
    let parameters: [String: JSONValue]

    /// Only for an allowed WKNavigationAction. WebKit synthesizes its UA and
    /// document Accept header; Chromium must compute its own for the new engine.
    /// Keep Referer, bodies and every other header for normal validation.
    static func webKitDocument(_ request: URLRequest) -> URLRequest {
        var result = request
        for name in (request.allHTTPHeaderFields ?? [:]).keys
            where ["user-agent", "accept"].contains(name.lowercased()) {
            result.setValue(nil, forHTTPHeaderField: name)
        }
        return result
    }

    init(_ request: URLRequest) throws {
        guard let url = request.url, (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else {
            throw YabCoreError.remote("Chromium dev tabs support GET navigation without a body")
        }
        var parameters: [String: JSONValue] = ["url": .string(url.absoluteString)]
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            guard name.lowercased() == "referer" else {
                throw YabCoreError.remote("Unsupported Chromium navigation header: " + name)
            }
            if value.isEmpty { continue }
            guard !value.contains("\r"), !value.contains("\n"),
                  var referrer = URLComponents(string: value),
                  ["http", "https"].contains(referrer.scheme?.lowercased() ?? ""),
                  referrer.host?.isEmpty == false else {
                throw YabCoreError.remote("Invalid navigation referrer")
            }
            referrer.user = nil
            referrer.password = nil
            referrer.fragment = nil
            guard let value = referrer.url?.absoluteString else { throw YabCoreError.remote("Invalid navigation referrer") }
            parameters["referrer"] = .string(value)
        }
        self.parameters = parameters
    }
}
