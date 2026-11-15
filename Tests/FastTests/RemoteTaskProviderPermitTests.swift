import Foundation
import SyncKit
import Testing
@testable import Fast

/// Remote preparation captures existing profile consent, without starting
/// a provider, connecting one, or widening the phone's read-only session.
@MainActor
@Suite(.serialized)
struct RemoteTaskProviderPermitTests {
    @MainActor
    private final class Fixture {
        let agents: Agents
        let consent: ProviderConsent
        let folder: URL
        var journal: Journal?
        private let saved: [(String, Any?)]

        init() throws {
            try #require(Store.testing)
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("remote-task-permit-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            journal = try Journal(path: folder.appendingPathComponent("journal.sqlite").path, device: "mac")
            let keys = ["agents.explicit-connections.v1", "agents.revoked-connections.v1",
                        "agents.connection-generation.codex", "agents.consent-migrated.v1"]
            saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
            agents = Agents()
            consent = ProviderConsent.shared
            consent.revoke("codex")
            // Start unconnected, distinct from the explicit-revocation case.
            Store.settings.set((Store.settings.stringArray(forKey: "agents.revoked-connections.v1") ?? [])
                .filter { $0 != "codex" }, forKey: "agents.revoked-connections.v1")
        }

        func prepare() throws -> Agents.Session {
            let journal = try #require(journal)
            let request = try TaskRecords.Request(account: "owned-account", phone: "phone", mac: "mac",
                                                   space: "owned-space", words: "Read this synthetic public task")
            let raw = Record(collection: TaskRecords.requestCollection, id: request.id, fields: try request.fields(),
                             stamps: ["body": Stamp(wall: 1, device: "phone")])
            _ = try journal.receive([(record: raw, version: 1)])
            guard case let .reserved(mapping) = try journal.reserveTaskCommand(raw, account: "owned-account",
                device: "mac", phone: "phone", publicSpace: "owned-space", cli: "codex") else {
                throw TaskLaunch.Failure.context
            }
            return try agents.prepareRemoteTask(mapping, journal: journal, account: "owned-account", device: "mac")
        }

        func expectRefused(_ session: Agents.Session) {
            #expect(!agents.dispatchAllowed(session))
            #expect(session.state == .failed)
            #expect(session.result == ProviderConsent.refusal)
            #expect(AgentTaskObservation(session).status == .failed)
            #expect(session.process == nil && session.server == nil && session.input == nil)
            #expect(session.lastSent.isEmpty && session.queue.isEmpty && !session.full && !session.movable)
        }

        func requireFreshCaptureWhenPresent(_ session: Agents.Session) throws {
            // The parent's missing capture is isolated by the positive test.
            // Candidate negative controls must begin with valid authority.
            if let permit = session.providerPermit {
                try #require(permit.valid && permit.cli == session.cli && !permit.connecting)
            }
        }

        func close() {
            consent.revoke("codex")
            for (key, value) in saved {
                if let value { Store.settings.set(value, forKey: key) }
                else { Store.settings.removeObject(forKey: key) }
            }
            journal = nil
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func isolated(_ body: (Fixture) throws -> Void) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let starts = ConsentAudit.snapshot().filter { $0.key.hasPrefix("cli.start.") }
        try body(fixture)
        #expect(ConsentAudit.snapshot().filter { $0.key.hasPrefix("cli.start.") } == starts)
    }

    @Test func connectedTaskRetainsChosenProviderPermit() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            try #require(fixture.consent.permit("codex")?.valid == true)
            let session = try fixture.prepare()
            let origin = try #require(session.remoteTask)
            #expect(session.cli == origin.mapping.cli && session.cli == "codex")
            #expect(origin.mapping.session == session.id)
            #expect(session.fromPhone && !session.full && !session.movable)
            #expect(session.turnPermit.valid && session.memoryEpoch == ContextPrivacy.shared.epoch)
            #expect(session.backgroundPermit == nil && session.contextGrant == nil && !session.knowing)
            #expect(session.providerPermit?.cli == origin.mapping.cli)
            #expect(session.providerPermit?.connecting == false)
            #expect(session.providerPermit?.valid == true)
            #expect(fixture.agents.dispatchAllowed(session))
            #expect(session.state == .starting && session.remoteTask == origin)
            #expect(fixture.agents.mcpArgs(session).contains("--phone-read-only"))
            #expect(session.process == nil && session.server == nil && session.lastSent.isEmpty)

            fixture.consent.revoke("codex")
            fixture.consent.grant("codex")
            let fresh = try fixture.prepare()
            #expect(fresh !== session && fresh.id != session.id)
            #expect(fresh.providerPermit?.valid == true)
            #expect(fixture.agents.dispatchAllowed(fresh))
            #expect(fresh.turnPermit.valid && fresh.memoryEpoch == ContextPrivacy.shared.epoch)
            #expect(!fresh.full && !fresh.movable && fresh.process == nil && fresh.server == nil)
        }
    }

    @Test func disconnectedProviderIsRefused() throws {
        try isolated { fixture in
            try #require(!fixture.consent.allows("codex"))
            try #require(!(Store.settings.stringArray(forKey: "agents.revoked-connections.v1") ?? []).contains("codex"))
            let session = try fixture.prepare()
            #expect(session.providerPermit == nil)
            fixture.expectRefused(session)
        }
    }

    @Test func revokedProviderIsRefused() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            fixture.consent.revoke("codex")
            try #require(!fixture.consent.allows("codex"))
            try #require((Store.settings.stringArray(forKey: "agents.revoked-connections.v1") ?? []).contains("codex"))
            let session = try fixture.prepare()
            #expect(session.providerPermit == nil)
            fixture.expectRefused(session)
        }
    }

    @Test func disconnectAfterPreparationRefusesDispatch() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            try #require(fixture.consent.permit("codex")?.valid == true)
            let session = try fixture.prepare()
            try fixture.requireFreshCaptureWhenPresent(session)
            fixture.consent.revoke("codex")
            #expect(session.providerPermit?.valid != true)
            fixture.expectRefused(session)
        }
    }

    @Test func reconnectDoesNotReviveExistingTask() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            let session = try fixture.prepare()
            try fixture.requireFreshCaptureWhenPresent(session)
            let origin = try #require(session.remoteTask)
            let epoch = session.providerPermit?.epoch
            fixture.consent.revoke("codex")
            fixture.consent.grant("codex")
            try #require(fixture.consent.permit("codex")?.valid == true)
            let again = try fixture.agents.prepareRemoteTask(origin.mapping, journal: try #require(fixture.journal),
                                                            account: "owned-account", device: "mac")
            #expect(again === session && fixture.agents.sessions.count == 1)
            #expect(again.remoteTask == origin && again.providerPermit?.epoch == epoch)
            #expect(again.providerPermit?.valid != true)
            fixture.expectRefused(again)
        }
    }

    @Test func revokedTurnRefusesDispatch() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            let session = try fixture.prepare()
            try fixture.requireFreshCaptureWhenPresent(session)
            session.turnPermit.revoke()
            #expect(!session.turnPermit.valid)
            fixture.expectRefused(session)
        }
    }

    @Test func staleMemoryEpochRefusesDispatch() throws {
        try isolated { fixture in
            fixture.consent.grant("codex")
            let session = try fixture.prepare()
            try fixture.requireFreshCaptureWhenPresent(session)
            // Exercise the captured epoch mismatch without clearing shared
            // Memory or changing another suite's privacy generation.
            session.memoryEpoch = "stale-" + UUID().uuidString
            fixture.expectRefused(session)
        }
    }
}
