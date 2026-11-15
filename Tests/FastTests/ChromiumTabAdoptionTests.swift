import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumTabAdoptionTests {
    @Test func blankURLIsNeitherAuthorizationNorAReasonToRejectANativeRequest() {
        let blank: [String: JSONValue] = ["url": .string("about:blank")]
        #expect(!ChromiumTabAdoption.hasNativeRequest(blank))
        var popup = blank
        popup["creationPurpose"] = .string("popup")
        popup["opener"] = .string("owner")
        popup["source"] = .object(["url": .string("https://example.test"), "main": .bool(true)])
        #expect(ChromiumTabAdoption.hasNativeRequest(popup))
        var created = blank
        created["creationPurpose"] = .string("extension")
        created["extensionCreation"] = .object(["extensionId": .string(String(repeating: "a", count: 32))])
        #expect(ChromiumTabAdoption.hasNativeRequest(created))
        created["extensionCreation"] = .object(["extensionId": .string("bad")])
        #expect(!ChromiumTabAdoption.hasNativeRequest(created))
    }
    @Test func nativeExtensionIndexIsClampedWithoutChangingOrdinaryPopupPlacement() {
        let id = String(repeating: "a", count: 32)
        func params(_ index: Double, extensionID: String? = nil) -> [String: JSONValue] {
            ["extensionCreation": .object(["extensionId": .string(extensionID ?? id), "index": .number(index)])]
        }
        #expect(ChromiumTabAdoption.extensionIndex(params(0), count: 5) == 0)
        #expect(ChromiumTabAdoption.extensionIndex(params(99), count: 5) == 5)
        #expect(ChromiumTabAdoption.extensionIndex(params(-1), count: 5) == nil)
        #expect(ChromiumTabAdoption.extensionIndex(params(1.5), count: 5) == nil)
        #expect(ChromiumTabAdoption.extensionIndex(params(0, extensionID: "bad"), count: 5) == nil)
        #expect(ChromiumTabAdoption.extensionIndex(["index": .number(0)], count: 5) == nil)
    }
    @Test func rowObserversSeeThePreparedHandleWithoutCreatingAnotherBrowser() throws {
        _ = NSApplication.shared
        var constructions = 0
        let factory = PageEngineFactory(kinds: [.chromium]) { tab, _ in
            constructions += 1
            return ChromiumPage(tab: tab)
        }
        let tab = Tab(engine: .chromium, factory: factory)
        defer { tab.close() }
        let prepared = try #require(tab.prepareChromiumPageForAdoption(profile: Space.firstID.uuidString))
        #expect(tab.page === prepared)
        #expect(constructions == 0)
        #expect(prepared.remoteID == nil)
    }
    private func event(profile: String, privateMode: Bool, opener: String? = nil) -> YabCoreEvent {
        var params: [String: JSONValue] = ["tab": .string("native-child"), "profile": .string(profile), "private": .bool(privateMode),
            "creationPurpose": .string("extension"),
            "extensionCreation": .object(["extensionId": .string(String(repeating: "a", count: 32))])]
        if let opener { params["opener"] = .string(opener) }
        return YabCoreEvent(name: "tab.created", params: params)
    }

    @Test func aLostOpenerDoesNotFallBackToTheActiveWindow() {
        _ = NSApplication.shared
        #expect(ChromiumTabAdoption.install(event(profile: Space.firstID.uuidString, privateMode: false, opener: "lost"), opener: nil) == nil)
    }

    @Test func aNativePrivateDocumentCannotBecomeANormalTab() {
        _ = NSApplication.shared
        let normal = Tab()
        defer { normal.close() }
        #expect(ChromiumTabAdoption.install(event(profile: "private-" + Space.firstID.uuidString, privateMode: true), opener: normal) == nil)
        #expect(normal.builtPage == nil)
    }

    @Test func aDifferentNativeProfileCannotUseTheOpenersSpace() {
        _ = NSApplication.shared
        let normal = Tab()
        defer { normal.close() }
        #expect(ChromiumTabAdoption.install(event(profile: UUID().uuidString, privateMode: false), opener: normal) == nil)
        #expect(normal.builtPage == nil)
    }

    @Test func aPrivateFlagCannotReinterpretAPersistentProfile() {
        #expect(ChromiumTabAdoption.install(event(profile: Space.firstID.uuidString, privateMode: true), opener: nil) == nil)
        #expect(ChromiumTabAdoption.install(event(profile: "private-" + Space.firstID.uuidString, privateMode: false), opener: nil) == nil)
    }
}
