import Foundation
import YabCoreClient

extension ChromiumScripts {
    /// Optional native file.open v1 provenance. Older helpers keep the native
    /// panel fallback. Only core may mint this metadata from the real request;
    /// a page relay or a recent CDP chooser observation is not a source.
    func fileFrame(_ params: [String: JSONValue], tab: String?) -> PageFrame? {
        guard let tab, !tab.isEmpty, params["tab"] == .string(tab),
              let request = params["request"]?.string, !request.isEmpty,
              let source = params["source"], source["version"] == .number(1),
              source["request"] == .string(request) else { return nil }
        let frame = source["frame"]
        guard let token = frame["token"].string, !token.isEmpty,
              let frameID = frame["frameId"].string, !frameID.isEmpty,
              case .bool = frame["main"],
              let href = frame["url"].string, !href.isEmpty, URL(string: href) != nil,
              frame["scheme"].string != nil, frame["host"].string != nil,
              let port = frame["port"].number, port.isFinite,
              port >= 0, port <= 65535, port.rounded() == port else { return nil }
        // The token is the native requesting document's Runtime uniqueContextId.
        // scripts.evaluate checks it is still live in this helper tab before
        // touching fileSpot. Core must retain/cancel that same native request.
        return frames(.array([frame]), tab: tab).first
    }
}
