import Foundation
import YabCoreClient

/// An agent's files, given to a Chromium page as Chromium's own automation
/// gives them (Puppeteer's uploadFile, Playwright's setInputFiles): by path,
/// into the file field (DOM.setFileInputFiles), or to the picker a press opens,
/// intercepted in the renderer. Never the person's chooser: Chrome opens none
/// for a hidden or inactive tab, and an agent's tab works out of sight
/// (feedback #1963). YabCore's agent_files.inc does the DevTools part.
extension ChromiumPage {
    /// Waiters for the picker a press opens, one per page.
    @MainActor static var fileOffers: [ObjectIdentifier: @MainActor (String?) -> Void] = [:]
    static let replaced = "another upload in this page took its place"

    /// The field `body` returns, in the agent's world, given `paths`. False
    /// when it returned no file field.
    func agentSetFiles(_ body: String, arguments: [String: Any], frame: PageFrame?, paths: [String]) async throws -> Bool {
        let frameToken = try scripts.token(frame, tab: remoteID)
        await tail?.value
        let (core, id) = try await endpoint()
        let turn = documentTurn
        guard arguments.keys.allSatisfy({ $0.range(of: "^[A-Za-z_$][A-Za-z0-9_$]*$", options: .regularExpression) != nil }) else {
            throw YabCoreError.remote("Invalid JavaScript argument name")
        }
        let function = "async function(args){const {\(arguments.keys.sorted().joined(separator: ","))}=args;\n\(body)\n}"
        let args = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: arguments))
        var params: [String: JSONValue] = ["tab": .string(id), "world": .string(ChromiumScripts.world(.agent)),
            "function": .string(function), "arguments": args, "files": .array(paths.map(JSONValue.string))]
        let result: JSONValue
        if let frameToken {
            params["frame"] = .string(frameToken)
            result = try await core.request("scripts.evaluate", params: params)
        } else {
            params["document"] = try await core.waitForDocument(tab: id, profile: profile, timeout: 10)
            result = try await core.request("script.evaluate", params: params)
        }
        guard !retired, remoteID == id, documentTurn == turn else { throw CancellationError() }
        return result["set"] == .bool(true)
    }

    /// Offers `paths` to the next picker the page opens; `done` hears whether
    /// it took them (nil) or why not. Withdrawn after `seconds`.
    func agentOfferFiles(_ paths: [String], seconds: Double, opened: @escaping @MainActor () -> Void,
                         done: @escaping @MainActor (_ taken: Bool, _ error: String?) -> Void) {
        let key = ObjectIdentifier(self)
        Task { @MainActor in
            do {
                let (core, id) = try await endpoint()
                _ = try await core.request("files.offer", params: ["tab": .string(id), "paths": .array(paths.map(JSONValue.string))])
                var settled = false
                @MainActor func finish(_ taken: Bool, _ error: String?, withdraw: Bool = true) {
                    guard !settled else { return }
                    settled = true
                    if withdraw {
                        Self.fileOffers.removeValue(forKey: key)
                        if !taken { Task { _ = try? await core.request("files.offer", params: ["tab": .string(id), "withdraw": .bool(true)]) } }
                    }
                    done(taken, error)
                }
                // A newer upload in this page holds the offer now: the older one hears so and lets it be.
                Self.fileOffers[key]?(Self.replaced)
                Self.fileOffers[key] = { error in finish(error == nil, error, withdraw: error != Self.replaced) }
                Task { @MainActor in try? await Task.sleep(for: .seconds(seconds)); finish(false, nil) }
                opened()
            } catch { done(false, error.localizedDescription) }
        }
    }

    /// YabCore's "files.taken": the offered files went into the picker's field.
    func receiveFilesTaken(_ p: [String: JSONValue]) {
        Self.fileOffers[ObjectIdentifier(self)]?(p["error"]?.string)
    }
}
