import Foundation
import Testing
@testable import YabCoreClient

/// Actual Foundation Process/static-code preparation. This does not launch CEF,
/// prove a signed parent/socket, or construct a native owner/phase.
struct ChromiumOriginalCallerDiagnosticTests {
    @Test func closedProductionNeverMutatesUnusedTask() {
        let process = Process()
        let input = process.standardInput as AnyObject?
        #expect(NativePeerIdentity.prepareLaunch(process) == nil)
        #expect(process.processIdentifier == 0)
        #expect(process.standardInput as AnyObject? === input)
    }
    @Test func diagnosticRejectsNonstandardInputBeforeChangingTask() {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.arguments = []; process.standardInput = pipe
        #expect(NativePeerIdentity.prepareDiagnosticLaunch(process) == nil)
        #expect((process.standardInput as? Pipe) === pipe)
        #expect(process.processIdentifier == 0)
    }
    @Test func actualStaticObservationPreparationCannotCaptureUnlaunchedOrReusedChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.arguments = []
        if NativePeerIdentity.diagnosticImagePolicyConfigured {
            guard case .helperImageRefused = NativePeerIdentity.prepareDiagnosticLaunchResult(process) else {
                Issue.record("Foreign system executable was not refused by exact compiled helper pin"); return
            }
            #expect(process.standardInput == nil)
            return
        }
        let prepared = try #require(NativePeerIdentity.prepareDiagnosticLaunch(process))
        #expect(prepared.isDiagnosticObservation)
        #expect(prepared.captureLaunched() == nil) // No actual original birth, never fabricate it.
        #expect(prepared.captureLaunched() == nil) // Consumed failure cannot upgrade/retry.
        #expect(process.processIdentifier == 0)
        #expect(NativePeerIdentity.prepareLaunch(process) == nil) // Default production remains closed.
    }
}
