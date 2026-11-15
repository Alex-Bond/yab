import Foundation
import YabCoreClient

/// These are local ownership guards, not fabricated native document tokens.
@MainActor
struct ChromiumOriginalPDFPresenceState {
    struct Owner: Equatable {
        let peer: ObjectIdentifier
        let process: UUID
        let tab: String, profile: String
        let pageOwner: ObjectIdentifier
        let store: ObjectIdentifier
        let epoch: Int, turn: Int
        let observation: UUID
    }
    enum Update: Equatable {
        case ignored, waiting, unchanged, unavailable
        case ready(OriginalPDFPresenceIdentity)
    }
    private(set) var owner: Owner?
    private(set) var admission: OriginalPDFPresenceAdmission?
    private(set) var ready: OriginalPDFPresenceIdentity?
    private var pending: OriginalPDFPresenceReport?

    static func supported(_ hooks: [String: JSONValue]) -> Bool {
        hooks["nativeOriginalPDF"] == .bool(true) && hooks["nativeOriginalPDFVersion"] == .number(1) &&
        hooks["nativeOriginalPDFPresence"] == .bool(true) && hooks["nativeOriginalPDFPresenceVersion"] == .number(1)
    }
    mutating func begin(_ owner: Owner) {
        invalidate(); self.owner = owner
    }
    mutating func invalidate() {
        owner = nil; admission = nil; pending = nil; ready = nil
    }
    mutating func admit(_ reply: JSONValue, owner: Owner) throws -> Update {
        guard self.owner == owner else { return .ignored }
        admission = try OriginalPDFPresenceAdmission(reply)
        guard let pending else { return .waiting }
        self.pending = nil
        return consume(pending)
    }
    mutating func receive(_ packet: JSONValue, owner: Owner) throws -> Update {
        guard self.owner == owner else { return .ignored }
        let report = try OriginalPDFPresenceReport(packet, tab: owner.tab, profile: owner.profile)
        guard admission != nil else { pending = report; return .waiting }
        return consume(report)
    }
    private mutating func consume(_ report: OriginalPDFPresenceReport) -> Update {
        guard admission?.matches(report) == true else { return .ignored }
        guard let identity = report.identity else { ready = nil; return .unavailable }
        guard ready != identity else { return .unchanged }
        ready = identity
        return .ready(identity)
    }
}

/// Shared with PDFPaper so the byte-fetch gate is testable without a browser.
@MainActor
struct ChromiumOriginalPDFAnalysisState {
    enum Decision: Equatable { case metadataOnly, read, cached(Bool?) }
    private(set) var source: OriginalPDFPresenceIdentity?
    private var attempted: OriginalPDFPresenceIdentity?
    private var pending: OriginalPDFPresenceIdentity?
    private var form: Bool?

    mutating func unavailable() {
        source = nil
        if pending != nil { attempted = nil; form = nil }
        pending = nil
    }
    mutating func prepare(_ identity: OriginalPDFPresenceIdentity, visible: Bool, hasDesk: Bool) -> Decision {
        source = identity
        guard visible, !hasDesk else { return .metadataOnly }
        if attempted == identity { return .cached(form) }
        attempted = identity; pending = identity; form = nil
        return .read
    }
    mutating func complete(_ identity: OriginalPDFPresenceIdentity, form: Bool) -> Bool {
        guard source == identity, pending == identity else { return false }
        pending = nil; self.form = form
        return true
    }
    mutating func failed(_ identity: OriginalPDFPresenceIdentity) {
        guard source == identity, pending == identity else { return }
        pending = nil
        // Repeated metadata/layout is not an automatic binary retry loop.
        // An explicit Fill & Sign action still performs a fresh native read.
    }
}
