import Testing
@testable import Fast

/// The pure decision called by actual LinkWindow.present. These values
/// cannot open a Browser, touch Store, inspect a profile or move a Space.
@MainActor
struct LinkWindowFullscreenAdmissionTests {
    private typealias Owner = LinkWindow.OwnFullscreenAdmission
    private typealias Admission = LinkWindow.FullscreenAdmission

    private func owner(screen: Int = 0, gate: Gate? = nil) -> Owner {
        Owner(screenIndex: screen, registeredNormalKeyOwner: gate != .registeredNormalKeyOwner,
              appActive: gate != .appActive, visible: gate != .visible,
              miniaturized: gate == .notMiniaturized, onActiveSpace: gate != .onActiveSpace,
              nativeFullscreen: gate != .nativeFullscreen, settled: gate != .settled)
    }

    enum Gate: CaseIterable, Equatable {
        case registeredNormalKeyOwner, appActive, visible, notMiniaturized
        case onActiveSpace, nativeFullscreen, settled
    }

    @Test(arguments: [0, 1, 2])
    func aSettledOwnFullscreenUpgradesOnlyTheSelectedPanel(screen: Int) {
        let result = LinkWindow.fullscreenAdmission(
            legacyScreenIndex: screen, legacyOver: false, pointerScreenIndex: screen,
            own: owner(screen: screen))
        #expect(result == Admission(screenIndex: screen, over: true))
    }

    @Test(arguments: Gate.allCases)
    func everyEligibilityGateIsRequired(gate: Gate) {
        // A missing registered normal key owner includes private/unregistered
        // windows. A maximized ordinary window fails nativeFullscreen.
        let result = LinkWindow.fullscreenAdmission(
            legacyScreenIndex: 0, legacyOver: false, pointerScreenIndex: 0,
            own: owner(gate: gate))
        #expect(result == Admission(screenIndex: 0, over: false))
    }

    @Test func noOwnerNeverFallsBackToAnotherMainOrRememberedWindow() {
        #expect(LinkWindow.fullscreenAdmission(
            legacyScreenIndex: 0, legacyOver: false, pointerScreenIndex: 0, own: nil)
            == Admission(screenIndex: 0, over: false))
    }

    enum LegacyCase: CaseIterable {
        case missingTarget, missingPointer, noScreens, unmappableTarget
        case fullscreenOnAnotherDisplay, rememberedOtherDisplay, foreignFreeAlternative
        case foreignFullscreenOverlay, foreignOverlayWithoutOwner
    }

    @Test(arguments: LegacyCase.allCases)
    func legacyScreenAndForeignPolicyAlwaysWin(scenario: LegacyCase) {
        let target: Int?, pointer: Int?, over: Bool, candidate: Owner?
        switch scenario {
        case .missingTarget:
            target = nil; pointer = 0; over = false; candidate = owner()
        case .missingPointer:
            target = 0; pointer = nil; over = false; candidate = owner()
        case .noScreens:
            target = nil; pointer = nil; over = true; candidate = nil
        case .unmappableTarget:
            target = -1; pointer = -1; over = false; candidate = owner(screen: -1)
        case .fullscreenOnAnotherDisplay:
            target = 0; pointer = 0; over = false; candidate = owner(screen: 1)
        case .rememberedOtherDisplay:
            target = 1; pointer = 0; over = false; candidate = owner()
        case .foreignFreeAlternative:
            target = 1; pointer = 0; over = false; candidate = owner(screen: 1)
        case .foreignFullscreenOverlay:
            target = 0; pointer = 0; over = true; candidate = owner()
        case .foreignOverlayWithoutOwner:
            target = 0; pointer = 0; over = true; candidate = nil
        }
        #expect(LinkWindow.fullscreenAdmission(
            legacyScreenIndex: target, legacyOver: over, pointerScreenIndex: pointer, own: candidate)
            == Admission(screenIndex: target, over: over))
    }
}
