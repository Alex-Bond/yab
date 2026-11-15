import AppKit
import YabCoreClient

/// Isolated observation of the retained original process/client/bootstrap only.
/// No source admission, lease, recovery owner or production counterpart.
@MainActor
final class ChromiumOriginalCallerDiagnostic {
    let id = UUID().uuidString.lowercased()
    let deadline: Bool
    var launchConsumed = false
    var helperImageRefused = false
    var client: YabCoreClient?
    var process: Process?
    var witness: NativePeerIdentity.LaunchWitness?
    private(set) var disconnected = false
    init(deadline: Bool) { self.deadline = deadline }
    func describe() async throws -> JSONValue {
        guard let client else { throw YabCoreError.transport("Original diagnostic connection unavailable") }
        return .object(["session": .string(id), "deadline": .bool(deadline),
            "originalPID": .number(Double(process?.processIdentifier ?? 0)),
            "originalProcessRunning": .bool(process?.isRunning == true),
            "disconnectedByProbe": .bool(disconnected),
            "observation": try await client.originalCallerDiagnostic()])
    }
    func disconnect() async {
        guard !disconnected else { return }; disconnected = true
        await client?.disconnect() // Original socket only. Never connection().
    }
    func releaseDeadline() async throws -> Bool {
        guard deadline, !disconnected, let client,
              case .observed = await client.originalPeerSource() else { return false }
        guard !disconnected, self.client === client else { return false }
        return witness?.releaseDiagnosticDeadline() == true
    }
}

extension Bench {
    func chromiumOriginalCallerDiagnostic(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "Diagnostic requires isolated world"]); return }
        let owner = ChromiumProcess.shared
        let action = request["action"] as? String ?? "inspect"
        Task { @MainActor in
            do {
                let diagnostic: ChromiumOriginalCallerDiagnostic
                if action == "begin" {
                    guard owner.mayBeginOriginalCallerDiagnostic else {
                        throw YabCoreError.transport("Original diagnostic is one shot and must precede helper startup")
                    }
                    diagnostic = ChromiumOriginalCallerDiagnostic(deadline: request["deadline"] as? Bool == true)
                    owner.originalCallerDiagnostic = diagnostic // Retain failed attempt too, no upgrade/retry.
                    _ = try await owner.connection()
                } else {
                    guard let original = owner.originalCallerDiagnostic, request["session"] as? String == original.id else {
                        throw YabCoreError.transport("Exact original diagnostic session required")
                    }
                    diagnostic = original
                    if action == "disconnect" { await diagnostic.disconnect() }
                    else if action == "release-deadline" {
                        let dispatched = try await diagnostic.releaseDeadline()
                        answer(["session": diagnostic.id, "controlByteDispatched": dispatched, "nativeValidationApplied": false]); return
                    } else if action != "inspect" { throw YabCoreError.protocolViolation("Unknown diagnostic action") }
                }
                let value = try await diagnostic.describe()
                answer(["value": try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))])
            } catch {
                if action == "begin", owner.originalCallerDiagnostic?.helperImageRefused == true {
                    answer(["diagnosticLaunchStatus": "helper-image-refused", "compiledImageGatePresent": NativePeerIdentity.diagnosticImagePolicyConfigured,
                        "helperLaunched": false, "acceptedVersion": 0]); return
                }
                answer(["error": String(describing: error)])
            }
        }
    }
}
