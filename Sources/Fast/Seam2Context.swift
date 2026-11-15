import Foundation

/// The local space identity of a persistent engine profile. A view cannot
/// move its cookies into another context just because its row moved.
@MainActor
protocol PageSpaceContext: AnyObject {
    var profileSpaceID: UUID? { get }
    func usesSignIns(of space: UUID) -> Bool
}

extension ChromiumPage: PageSpaceContext {
    func usesSignIns(of space: UUID) -> Bool {
        !privateMode && profile == ChromiumPersistentProfiles.profile(store: Spaces.store(for: space), placement: space)
    }
}
