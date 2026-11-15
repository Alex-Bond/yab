import Foundation
import WebKit

/// Like extensions, add-ons belong to sign-ins, not to a window or a site.
/// Code is shared; installation switches and userscript values are separate.
struct AddonProfiles: Codable, Equatable {
    var enabled: [String: Bool]

    static func key(_ signIn: UUID?) -> String { signIn?.uuidString ?? "shared" }
    init(signIn: UUID?, enabled: Bool) { self.enabled = [Self.key(signIn): enabled] }
    init(legacy enabled: Bool, signIns: [UUID]) {
        self.init(signIn: nil, enabled: enabled)
        for signIn in signIns { self.enabled[Self.key(signIn)] = enabled }
    }
    func contains(_ signIn: UUID?) -> Bool { enabled[Self.key(signIn)] != nil }
    func isEnabled(in signIn: UUID?) -> Bool { enabled[Self.key(signIn)] == true }
    mutating func setEnabled(_ on: Bool, in signIn: UUID?) { enabled[Self.key(signIn)] = on }
    mutating func remove(_ signIn: UUID?) { enabled[Self.key(signIn)] = nil }

    @MainActor static func of(_ tab: Tab) -> UUID? { Spaces.ownSpace(of: tab.store) }
    @MainActor static func of(_ browser: Browser?) -> UUID? {
        of(space: browser?.spaceID ?? BrowserWindows.shared.activeBrowser?.spaceID ?? Space.firstID)
    }
    /// The sign-in a space runs add-ons with: nil for the shared one.
    @MainActor static func of(space: UUID) -> UUID? {
        if space == Space.firstID || space == Space.mailID || space == Space.pinsID || Spaces.sharing.contains(space) { return nil }
        return Spaces.signIn(of: space)
    }
    @MainActor static var existing: [UUID] { Spaces.read().filter(\.ownSignIns).map(\.id) }
}
