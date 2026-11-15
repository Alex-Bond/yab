import Foundation
import Testing
import YabCoreClient
@testable import Fast

/// Pure receipt and ownership transitions. Native compilation/runtime NOT_RUN.
@MainActor
struct ChromiumOriginalPDFPresenceTests {
    private let peer = NSObject(), replacementPeer = NSObject(), page = NSObject(), store = NSObject()
    private func owner(peer: NSObject? = nil, turn: Int = 1, process: UUID? = nil) -> ChromiumOriginalPDFPresenceState.Owner {
        .init(peer: ObjectIdentifier(peer ?? self.peer), process: process ?? UUID(), tab: "tab-A", profile: "public-A",
              pageOwner: ObjectIdentifier(page), store: ObjectIdentifier(store), epoch: 3, turn: turn, observation: UUID())
    }
    private func ack(document: Int = 41, browser: Int = 7) -> JSONValue {
        .object(["observing": .bool(true), "documentGeneration": .number(Double(document)), "nativeBrowserId": .number(Double(browser))])
    }
    private func packet(document: Int = 41, status: String = "ready") -> JSONValue {
        var native: [String: JSONValue] = ["version": .number(1), "browserId": .number(7),
            "kind": .string("originalLoadedPDFPresence"), "operation": .string("presence"), "status": .string(status),
            "available": .bool(status == "ready"), "complete": .bool(false), "loadedAtMetadataAck": .bool(status == "ready"),
            "generation": .string("subscription-3"), "rootDocument": .string("root-A"), "rootFrameId": .string("frame-root")]
        if status == "ready" {
            native.merge(["size": .number(9), "request": .string("presence-A"), "source": .string(""),
                "pdfDocument": .string("pdf-A"), "pdfFrameId": .string("frame-pdf"),
                "listener": .string("listener-A"), "pluginSource": .string("plugin-A")]) { _, new in new }
        }
        return .object(["tab": .string("tab-A"), "profile": .string("public-A"),
                        "documentGeneration": .number(Double(document)), "native": .object(native)])
    }
    private func change(_ packet: JSONValue, _ key: String, _ value: JSONValue) -> JSONValue {
        var outer = packet.object!, native = outer["native"]!.object!
        native[key] = value; outer["native"] = .object(native); return .object(outer)
    }
    private func identity(_ value: JSONValue? = nil) throws -> OriginalPDFPresenceIdentity {
        let report = try OriginalPDFPresenceReport(value ?? packet(), tab: "tab-A", profile: "public-A")
        return try #require(report.identity)
    }
    private func rejects(_ body: () throws -> Void) {
        do { try body(); Issue.record("Expected malformed or retired original PDF rejection") } catch {}
    }
    @Test func bothCapabilitiesAndExactVersionsAreRequired() {
        let hooks: [String: JSONValue] = ["nativeOriginalPDF": .bool(true), "nativeOriginalPDFVersion": .number(1),
            "nativeOriginalPDFPresence": .bool(true), "nativeOriginalPDFPresenceVersion": .number(1)]
        #expect(ChromiumOriginalPDFPresenceState.supported(hooks))
        for key in hooks.keys {
            var absent = hooks; absent[key] = nil
            #expect(!ChromiumOriginalPDFPresenceState.supported(absent))
            var malformed = hooks; malformed[key] = key.hasSuffix("Version") ? .bool(true) : .number(1)
            #expect(!ChromiumOriginalPDFPresenceState.supported(malformed))
        }
    }
    @Test func presenceBeforeRPCReplyCannotPromoteWithoutExactNativeMapping() throws {
        var state = ChromiumOriginalPDFPresenceState(); let o = owner(); state.begin(o)
        #expect(try state.receive(packet(document: 40), owner: o) == .waiting)
        #expect(state.ready == nil)
        #expect(try state.admit(ack(), owner: o) == .ignored)
        #expect(state.ready == nil)
        #expect(try state.receive(packet(), owner: o) == .ready(identity()))
        // 41 is a helper counter. The local turn deliberately equals 1.
        #expect(state.ready != nil && o.turn == 1 && state.admission?.documentGeneration == 41)
    }
    @Test func matchingEventQueuedBeforeAdmissionIsConsumedOnce() throws {
        var state = ChromiumOriginalPDFPresenceState(); let o = owner(); state.begin(o)
        #expect(try state.receive(packet(), owner: o) == .waiting)
        #expect(try state.admit(ack(), owner: o) == .ready(identity()))
        #expect(try state.receive(packet(), owner: o) == .unchanged)
    }
    @Test func obsoleteObserveReplyAndSameIDsOnReplacementPeerCannotPromote() throws {
        var state = ChromiumOriginalPDFPresenceState(); let old = owner(); state.begin(old)
        _ = try state.receive(packet(), owner: old)
        state.invalidate()
        #expect(try state.admit(ack(), owner: old) == .ignored)
        let replacement = owner(peer: replacementPeer); state.begin(replacement)
        _ = try state.admit(ack(), owner: replacement)
        #expect(try state.receive(packet(), owner: old) == .ignored)
        #expect(state.ready == nil)
        #expect(try state.receive(packet(), owner: replacement) == .ready(identity()))
    }
    @Test func equalTabAndObservationCannotCrossCapturedStoreOrNativeBrowser() throws {
        var state = ChromiumOriginalPDFPresenceState(); let original = owner(); state.begin(original)
        _ = try state.admit(ack(), owner: original)
        let otherStore = NSObject()
        let foreign = ChromiumOriginalPDFPresenceState.Owner(peer: original.peer, process: original.process,
            tab: original.tab, profile: original.profile, pageOwner: original.pageOwner,
            store: ObjectIdentifier(otherStore), epoch: original.epoch, turn: original.turn, observation: original.observation)
        #expect(try state.receive(packet(), owner: foreign) == .ignored)
        #expect(try state.receive(change(packet(), "browserId", .number(8)), owner: original) == .ignored)
        #expect(state.ready == nil)
        #expect(try state.receive(packet(), owner: original) == .ready(identity()))
    }
    @Test func navigationAndRetirementRejectOriginalPendingAndLateCallbacks() throws {
        var state = ChromiumOriginalPDFPresenceState(); let old = owner(); state.begin(old)
        _ = try state.admit(ack(), owner: old)
        _ = try state.receive(packet(), owner: old)
        let new = owner(turn: 2, process: old.process); state.begin(new)
        #expect(state.ready == nil)
        #expect(try state.receive(packet(), owner: old) == .ignored)
        _ = try state.admit(ack(document: 42), owner: new)
        #expect(try state.receive(packet(), owner: new) == .ignored)
        #expect(state.ready == nil)
        state.invalidate()
        #expect(try state.receive(packet(document: 42), owner: new) == .ignored)
    }
    @Test func unknownAndUnavailableRetireReadinessWithoutInventingBytes() throws {
        var state = ChromiumOriginalPDFPresenceState(); let o = owner(); state.begin(o)
        _ = try state.admit(ack(), owner: o); _ = try state.receive(packet(), owner: o)
        #expect(try state.receive(packet(status: "unknown"), owner: o) == .unavailable)
        #expect(state.ready == nil)
        #expect(try state.receive(packet(status: "unavailable"), owner: o) == .unavailable)
    }
    @Test func subscriptionAndRequestChangesDoNotCauseAnotherReadyForSameSource() throws {
        var state = ChromiumOriginalPDFPresenceState(); let o = owner(); state.begin(o)
        _ = try state.admit(ack(), owner: o); _ = try state.receive(packet(), owner: o)
        let duplicate = change(change(packet(), "request", .string("presence-B")), "generation", .string("subscription-99"))
        #expect(try state.receive(duplicate, owner: o) == .unchanged)
        #expect(try state.receive(change(packet(), "pluginSource", .string("plugin-B")), owner: o) == .ready(identity(change(packet(), "pluginSource", .string("plugin-B")))))
    }
    @Test func malformedNativeNumbersFlagsAndSourcesNeverBecomePresence() {
        let mutations: [String: [JSONValue]] = ["browserId": [JSONValue.bool(true), .number(7.5), .number(1e100)],
                              "size": [.number(0), .number(64*1024*1024+1), .number(9.5), .bool(true)],
                              "version": [.bool(true), .number(2)],
                              "complete": [.bool(true)], "available": [.number(1)],
                              "source": [.string("export-lease"), .null], "rootDocument": [.string("")],
                              "pluginSource": [.string("")]]
        for (key, values) in mutations {
            for value in values { rejects { _ = try OriginalPDFPresenceReport(change(packet(), key, value), tab: "tab-A", profile: "public-A") } }
        }
        rejects { _ = try OriginalPDFPresenceAdmission(.object(["observing": .bool(true)])) }
        rejects { _ = try OriginalPDFPresenceAdmission(.object(["observing": .bool(true), "documentGeneration": .bool(true), "nativeBrowserId": .number(7)])) }
        rejects { _ = try OriginalPDFPresenceReport(packet(), tab: "tab-A", profile: "other") }
    }
    @Test func freshStateMustMatchEveryCapturedNativeSourceStamp() throws {
        let binding = OriginalPDFBinding(tab: "tab-A", profile: "public-A", call: "read-A")
        var native = packet()["native"].object!
        native["kind"] = .string("originalLoadedPDF"); native["operation"] = .string("state")
        native["source"] = .string("new-state-export-source"); native["request"] = .string("state-A")
        let envelope: [String: JSONValue] = ["tab": .string(binding.tab), "profile": .string(binding.profile), "call": .string(binding.call),
            "nativeAcknowledged": .bool(true), "lease": .string("lease-A"), "native": .object(native)]
        let presence = try identity()
        try presence.requireMatch(OriginalPDFReceipt(.object(envelope), binding: binding, operation: "state"))
        for key in ["rootDocument", "rootFrameId", "pdfDocument", "pdfFrameId", "listener", "pluginSource", "browserId", "size"] {
            var body = native; body[key] = ["browserId", "size"].contains(key) ? .number(11) : .string("replacement")
            var changed = envelope; changed["native"] = .object(body)
            rejects { try presence.requireMatch(OriginalPDFReceipt(.object(changed), binding: binding, operation: "state")) }
        }
    }
    @Test func backgroundAndExistingDeskUseMetadataOnlyAndVisibleDuplicatesReadOnce() throws {
        var analysis = ChromiumOriginalPDFAnalysisState(); let source = try identity()
        #expect(analysis.prepare(source, visible: false, hasDesk: false) == .metadataOnly)
        #expect(analysis.prepare(source, visible: true, hasDesk: true) == .metadataOnly)
        #expect(analysis.prepare(source, visible: true, hasDesk: false) == .read)
        #expect(analysis.prepare(source, visible: true, hasDesk: false) == .cached(nil))
        let actualMutation1 = analysis.complete(source, form: true)
        #expect(actualMutation1)
        #expect(analysis.prepare(source, visible: true, hasDesk: false) == .cached(true))
        analysis.unavailable()
        #expect(analysis.prepare(source, visible: true, hasDesk: false) == .cached(true))
    }
    @Test func unknownCancelsPendingAnalysisAndForeignCompletionCannotPromote() throws {
        var analysis = ChromiumOriginalPDFAnalysisState(); let old = try identity()
        let new = try identity(change(packet(), "listener", .string("listener-B")))
        #expect(analysis.prepare(old, visible: true, hasDesk: false) == .read)
        analysis.unavailable()
        let actualMutation2 = analysis.complete(old, form: true)
        #expect(!actualMutation2)
        #expect(analysis.prepare(new, visible: true, hasDesk: false) == .read)
        let actualMutation3 = analysis.complete(old, form: true)
        #expect(!actualMutation3)
        let actualMutation4 = analysis.complete(new, form: false)
        #expect(actualMutation4)
        #expect(analysis.prepare(new, visible: true, hasDesk: false) == .cached(false))
    }
    @Test func binaryReadFailureDoesNotTurnDuplicateMetadataIntoRetryLoop() throws {
        var analysis = ChromiumOriginalPDFAnalysisState(); let source = try identity()
        _ = analysis.prepare(source, visible: true, hasDesk: false)
        analysis.failed(source)
        #expect(analysis.prepare(source, visible: true, hasDesk: false) == .cached(nil))
    }
}
