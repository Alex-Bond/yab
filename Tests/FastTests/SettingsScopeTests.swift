import Foundation
import Testing
@testable import Fast

struct SettingsScopeTests {
    @Test func indexedDefaultAndOverrideKeepDifferentOwnership() {
        let defaultRow = SettingsItem(id: "search-engine", page: .search, title: "Search with")
        let overrideRow = SettingsItem(id: "space-search", page: .spaces, title: "Search with")
        #expect(defaultRow.scope == .globalDefault)
        #expect(SettingsScope.of(anchor: "search-engine-custom") == .globalDefault)
        #expect(overrideRow.scope == .space)
        #expect(SettingsScope.of(anchor: "site-search") == .global)
        #expect(SettingsScope.of(anchor: "search-suggest") == .global)
        #expect(SettingsScope.of(anchor: "warn-quit") == .global)
    }

    @Test func unreviewedRowsNeverBecomeGlobalByAssumption() {
        #expect(SettingsScope.of(anchor: "unknown-setting") == nil)
        #expect(SettingsScope.of(anchor: "browser-look") == nil)
        #expect(SettingsScope.of(anchor: "space-search-not-a-real-anchor") == nil)
    }

    @Test func ownedEnginesResolveWithoutReadingGlobalPreferences() throws {
        let first = try #require(EngineChoice.own(Engine.bing.rawValue, custom: nil))
        let second = try #require(EngineChoice.own(Engine.duckduckgo.rawValue, custom: nil))
        #expect(first.engine == .bing)
        #expect(second.engine == .duckduckgo)
        #expect(first.url(for: "fixture")?.host == "www.bing.com")
        #expect(second.url(for: "fixture")?.host == "duckduckgo.com")
        // nil means inheritance; do not call .global and read the real store.
        #expect(EngineChoice.own(nil, custom: nil) == nil)
        #expect(EngineChoice.own("not-an-engine", custom: nil) == nil)
    }

    @Test func serializedSpaceFieldsRemainIndependent() throws {
        var first = Space(id: UUID(), name: "First", icon: "A", ownSignIns: false)
        let second = Space(id: UUID(), name: "Second", icon: "B", ownSignIns: true,
                           search: Engine.duckduckgo.rawValue)
        first.search = Engine.bing.rawValue
        first.name = "Renamed"
        let data = try JSONEncoder().encode([first, second])
        let decoded = try JSONDecoder().decode([Space].self, from: data)
        #expect(decoded == [first, second])
        #expect(decoded[0].search != decoded[1].search)
        #expect(decoded[1].name == "Second")
        #expect(decoded[0].ownSignIns == false)
        #expect(decoded[1].ownSignIns == true)
        // Resetting one override preserves the other space and original IDs.
        var reset = decoded
        reset[0].search = nil
        #expect(reset[0].id == first.id)
        #expect(reset[0].search == nil)
        #expect(reset[1] == second)
    }
}
