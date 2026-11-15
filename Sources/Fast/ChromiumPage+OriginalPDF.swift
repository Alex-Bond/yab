import Foundation
import PDFKit
import YabCoreClient

extension ChromiumPage {
    struct OriginalPDFEndpoint: Sendable {
        let core: YabCoreClient
        let binding: OriginalPDFBinding
        let epoch: Int, turn: Int, printEpoch: Int
        let generation: UUID, observation: UUID
        let owner: ObjectIdentifier
        let presence: OriginalPDFPresenceIdentity
    }
    func originalPDFBytes() async throws -> Data {
        let endpoint = try await captureOriginalPDFEndpoint()
        let data = try await endpoint.core.originalPDFData(binding: endpoint.binding,
                                                          expectedPresence: endpoint.presence) { [weak self] in
            await self?.originalPDFEndpointIsCurrent(endpoint) == true
        }
        guard originalPDFEndpointIsCurrent(endpoint), !Task.isCancelled,
              let document = PDFDocument(data: data), document.pageCount > 0 else { throw CancellationError() }
        return data
    }

    /// Called only by authenticated attach, never by reconnecting for metadata.
    func refreshOriginalPDFPresence(core: YabCoreClient, remote: String, hooks: [String: JSONValue]) {
        guard ChromiumProcess.shared.isCurrent(core), remoteID == remote else { return }
        if originalPDFPeer !== core { invalidateOriginalPDFPresence(releasePeer: true) }
        originalPDFPeer = core
        originalPDFHooks = hooks
        originalPDFAdmissionAllowed = true
        restartOriginalPDFPresence()
    }
    func restartOriginalPDFPresence(force: Bool = false) {
        guard let core = originalPDFPeer, ChromiumOriginalPDFPresenceState.supported(originalPDFHooks),
              let scope = captureOriginalPDFPresenceOwner(core: core) else { return }
        if !force, let existing = originalPDFPresence.owner,
           existing.peer == scope.peer, existing.process == scope.process,
           existing.tab == scope.tab, existing.profile == scope.profile,
           existing.pageOwner == scope.pageOwner, existing.store == scope.store, existing.epoch == scope.epoch, existing.turn == scope.turn { return }
        originalPDFObservationTask?.cancel()
        originalPDFPresence.begin(scope)
        originalPDFObservationTask = Task { @MainActor [weak self] in
            guard let self, self.originalPDFPresenceOwnerIsCurrent(scope, core: core) else { return }
            do {
                let reply = try await core.request("page.originalPDF.observe", params: [
                    "tab": .string(scope.tab), "profile": .string(scope.profile), "enabled": .bool(true)], timeout: 10)
                guard !Task.isCancelled, self.originalPDFPresenceOwnerIsCurrent(scope, core: core) else { return }
                let update = try self.originalPDFPresence.admit(reply, owner: scope)
                self.applyOriginalPDFPresence(update)
            } catch {
                guard self.originalPDFPresenceOwnerIsCurrent(scope, core: core) else { return }
                self.invalidateOriginalPDFPresence()
            }
        }
    }
    /// The source connection comes from the original event loop, not a current
    /// client lookup or a peer identifier supplied in the wire payload.
    func receiveOriginalPDFPresence(_ event: YabCoreEvent, from core: YabCoreClient, generation: UUID) {
        guard let scope = originalPDFPresence.owner, scope.peer == ObjectIdentifier(core),
              scope.process == generation, originalPDFPresenceOwnerIsCurrent(scope, core: core) else { return }
        do { applyOriginalPDFPresence(try originalPDFPresence.receive(.object(event.params), owner: scope)) }
        catch { invalidateOriginalPDFPresence() }
    }
    func invalidateOriginalPDFPresence(releasePeer: Bool = false) {
        originalPDFAdmissionAllowed = false
        originalPDFObservationTask?.cancel(); originalPDFObservationTask = nil
        originalPDFPresence.invalidate()
        originalPDFPresenceBecameUnavailable()
        if releasePeer { originalPDFPeer = nil; originalPDFHooks = [:] }
        // Native navigation/browser teardown removes its subscription. An
        // unscoped asynchronous observe:false could cancel a replacement owner.
    }
    private func applyOriginalPDFPresence(_ update: ChromiumOriginalPDFPresenceState.Update) {
        switch update {
        case .ready, .unchanged: presentOriginalPDFPresence()
        case .unavailable: originalPDFPresenceBecameUnavailable()
        case .ignored, .waiting: break
        }
    }
}
