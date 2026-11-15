import Testing
@testable import Fast

struct LocalInspectorOwnershipTests {
    private final class Page {}

    @Test func distinguishesOwners() {
        let page = Page(), other = Page()
        let id = ObjectIdentifier(page), unrelated = ObjectIdentifier(other)
        #expect(LocalInspectorOwnership.route(page: id, main: id, small: nil) == .main)
        #expect(LocalInspectorOwnership.route(page: id, main: nil, small: id) == .small)
        #expect(LocalInspectorOwnership.route(page: id, main: nil, small: unrelated) == .stale)
        #expect(LocalInspectorOwnership.route(page: id, main: id, small: id) == .main)
    }

    @Test func revokedOrReplacedOwnerIsStale() {
        let page = Page(), replacement = Page()
        let id = ObjectIdentifier(page)
        var small: ObjectIdentifier? = id
        #expect(LocalInspectorOwnership.route(page: id, main: nil, small: small) == .small)
        small = nil
        #expect(LocalInspectorOwnership.route(page: id, main: nil, small: small) == .stale)
        small = ObjectIdentifier(replacement)
        #expect(LocalInspectorOwnership.route(page: id, main: nil, small: small) == .stale)
        #expect(LocalInspectorOwnership.route(page: id, main: id, small: small) == .main)
    }
}
