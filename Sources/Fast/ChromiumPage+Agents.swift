import Foundation
import YabCoreClient

extension ChromiumPage {
    /// Security checks cannot use childFrames' bounded snapshot inventory.
    /// Include the main document and every attached renderer, or refuse.
    func agentFrames() async throws -> [PageFrame] {
        // Navigation can replace the tree between CDP replies. Retry only
        // by collecting a fresh complete inventory; never admit a partial one.
        // Persistent failures, including inventory limits, still refuse.
        let deadline = Date().addingTimeInterval(1)
        for attempt in 0..<10 {
            do { return try await agentFramesOnce() }
            catch {
                if attempt == 9 || Date() >= deadline { throw error }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw PageEngineError.foreignFrame
    }

    private func agentFramesOnce() async throws -> [PageFrame] {
        // This also waits for initial navigation and the serialized input tail.
        do { _ = try await call("return true", in: .agent, gesture: false) }
        catch { throw AgentFramesError.step("agent world call", error) }
        let (core, id) = try await endpoint()
        let result: JSONValue
        do { result = try await core.request("agents.frames", params: ["tab": .string(id)]) }
        catch { throw AgentFramesError.step("agents.frames", error) }
        guard case .array(let values) = result["frames"], !values.isEmpty,
              values.count <= 256 else { throw PageEngineError.foreignFrame }
        let frames = scripts.frames(.array(values), tab: id)
        guard frames.count == values.count, frames.filter(\.isMain).count == 1 else {
            throw PageEngineError.foreignFrame
        }
        return frames
    }
}

enum AgentFramesError: Error, CustomStringConvertible {
    case step(String, Error)
    var description: String { if case .step(let name, let error) = self { return "\(name): \(error)" }; return "" }
}
