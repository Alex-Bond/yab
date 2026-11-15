import Foundation

extension YabCoreClient {
    /// Ready means a live document in the main frame's default execution
    /// context, not CEF's occasionally stale HasDocument flag.
    public func waitForDocument(tab: String, profile: String, url: String? = nil,
                                timeout: TimeInterval = 15) async throws -> JSONValue {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw YabCoreError.protocolViolation("Invalid readiness timeout")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        var params: [String: JSONValue] = ["tab": .string(tab), "profile": .string(profile)]
        if let url { params["url"] = .string(url) }
        var reason = "no answer yet"
        while clock.now < deadline {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            let state: JSONValue
            do { state = try await request("tab.readiness", params: params, timeout: max(0.001, seconds)) }
            catch YabCoreError.timeout { throw YabCoreError.remote("Document not ready: " + reason) }
            if let why = state["reason"].string { reason = why }
            if state["ready"] == .bool(true) {
                guard state["profile"] == .string(profile), state["devToolsReady"] == .bool(true),
                      state["proof"] == .string("mainFrameDocument"), state["frame"].string?.isEmpty == false,
                      (state["context"].number ?? 0) > 0, state["generation"].number != nil,
                      state["url"].string != nil, url == nil || state["url"] == .string(url!) else {
                    throw YabCoreError.protocolViolation("Readiness proof does not match the target")
                }
                try Task.checkCancellation()
                return state
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw YabCoreError.remote("Document not ready: " + reason)
    }
}
