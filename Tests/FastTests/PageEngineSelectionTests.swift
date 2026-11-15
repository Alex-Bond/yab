import Testing
@testable import Fast

struct PageEngineSelectionTests {
    @Test func unsupportedArchitectureRefusesEveryChromiumOverride() {
        #expect(PageEngineSelection.requested(defaults: "chromium", environment: nil, permitted: false,
                                             bundledChromium: true, supportsChromium: false) == .webKit)
        #expect(PageEngineSelection.requested(defaults: "chromium", environment: "chromium", permitted: true,
                                             supportsChromium: false) == .webKit)
        #expect(PageEngineSelection.requested(defaults: nil, environment: "chromium", permitted: true,
                                             supportsChromium: false) == .webKit)
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: true,
                                             supportsChromium: false) == nil)
        #expect(PageEngineSelection.requested(defaults: "webKit", environment: "chromium", permitted: true,
                                             supportsChromium: false) == .webKit)
    }

    @Test func launchDefaultWinsOverInheritedEnvironment() {
        #expect(PageEngineSelection.requested(defaults: "webKit", environment: "chromium", permitted: true, supportsChromium: true) == .webKit)
        #expect(PageEngineSelection.requested(defaults: "chromium", environment: "webKit", permitted: true, supportsChromium: true) == .chromium)
    }

    @Test func absentOrUnknownChoiceKeepsTheFactoryDefault() {
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: true, supportsChromium: true) == nil)
        #expect(PageEngineSelection.requested(defaults: "typo", environment: "typo", permitted: true, supportsChromium: true) == nil)
        #expect(PageEngineSelection.requested(defaults: "typo", environment: "chromium", permitted: true, supportsChromium: true) == .chromium)
    }

    @Test func installedProductionIgnoresBothSwitches() {
        #expect(PageEngineSelection.requested(defaults: "chromium", environment: "chromium", permitted: false) == nil)
    }

    @Test func packagedProductionWithNoChoiceIsOnChromium() {
        // A new install and an update from a WebKit-only version have no key.
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: false,
                                             bundledChromium: true, supportsChromium: true) == .chromium)
        #expect(PageEngineSelection.requested(defaults: "typo", environment: "webKit", permitted: false,
                                             bundledChromium: true, supportsChromium: true) == .chromium)
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: true,
                                             bundledChromium: true, supportsChromium: true) == .chromium)
    }

    @Test func packagedProductionKeepsAChoiceMade() {
        #expect(PageEngineSelection.requested(defaults: "chromium", environment: nil, permitted: false,
                                             bundledChromium: true, supportsChromium: true) == .chromium)
        #expect(PageEngineSelection.requested(defaults: "webKit", environment: "chromium", permitted: false,
                                             bundledChromium: true, supportsChromium: true) == .webKit)
    }

    @Test func intelAndBuildsWithoutChromiumStayOnWebKit() {
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: false,
                                             bundledChromium: true, supportsChromium: false) == nil)
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: false,
                                             bundledChromium: false, supportsChromium: true) == nil)
        #expect(PageEngineSelection.requested(defaults: nil, environment: nil, permitted: true,
                                             bundledChromium: false, supportsChromium: true) == nil)
    }
}
