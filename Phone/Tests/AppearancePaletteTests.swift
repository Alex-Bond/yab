import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class AppearancePaletteTests: XCTestCase {
    func testAppearanceChoiceReachesSwiftUIAndUIKitAndSystemFollowsTheOS() {
        let name = "appearance-palette-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        for choice in SettingsStore.Appearance.allCases {
            store.appearance = choice
            for systemDark in [false, true] {
                let expectedDark = choice == .dark || (choice == .system && systemDark)
                XCTAssertEqual(AppAppearance.scheme(store, systemIsDark: systemDark), expectedDark ? .dark : .light)
                let style = AppAppearance.windowStyle(choice)
                if choice == .system {
                    XCTAssertEqual(style, .unspecified, "System leaves the actual window style to iOS")
                } else {
                    XCTAssertEqual(style, expectedDark ? .dark : .light)
                }
            }
        }
    }

    func testLightPaletteKeepsReferenceColorsAndOpacity() {
        let references: [(Color, UInt32, Double)] = [
            (Ink.primary, 0x1C1C1E, 1), (Ink.secondary, 0x3C3C43, 0.72),
            (Ink.rowGlyph, 0x3A3A3C, 1), (Ink.warn, 0xA44B05, 1),
            (Ink.done, 0x1E6B3A, 1),
            (SettingsInk.footer, 0x3C3C43, 1), (SettingsInk.group, 0xFFFFFF, 1),
            (ChatInk.list, 0xFAFAFC, 1), (TaskInk.doneGround, 0xF6F6F3, 1),
            (Ink.rowSubtitle, 0x5A5A62, 1), (Metrics.Field.backdrop, 0xF2F2F5, 0.66),
        ]
        for (color, rgb, alpha) in references {
            let c = components(color, style: .light)
            XCTAssertEqual(c.0, Double((rgb >> 16) & 255) / 255, accuracy: 0.002)
            XCTAssertEqual(c.1, Double((rgb >> 8) & 255) / 255, accuracy: 0.002)
            XCTAssertEqual(c.2, Double(rgb & 255) / 255, accuracy: 0.002)
            XCTAssertEqual(c.3, alpha, accuracy: 0.002)
        }
    }

    func testDarkWordsAndActionsRemainReadableAcrossOwnSurfaces() {
        let words: [Color] = [Ink.primary, Ink.secondary, Ink.tertiary, Ink.rowSubtitle,
                              Ink.warn, Ink.done, Ink.newAnswer, ChatInk.needs, TaskInk.quiet]
        for ground in [Ink.ground, Ink.surface, Ink.card, SettingsInk.group] {
            XCTAssertLessThan(luminance(components(ground, style: .dark)), 0.05, "a dark surface stays charcoal")
            for ink in words {
                XCTAssertGreaterThanOrEqual(contrast(ink, on: ground), 4.5, "words remain readable on every dark surface")
            }
        }
        for ground in [ChatInk.ink, TaskInk.ink, Ink.button] {
            XCTAssertGreaterThanOrEqual(contrast(.white, on: ground), 4.5, "primary actions keep white words readable")
        }
        XCTAssertGreaterThanOrEqual(contrast(SettingsInk.onInk, on: SettingsInk.ink), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(SettingsInk.footer, on: SettingsInk.pageGround), 4.5)
    }

    func testDarkAddressSelectionHasReadableWordsAndShadowsAreRemoved() {
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let selection = Color(uiColor: Metrics.Field.selection.resolvedColor(with: dark))
        XCTAssertGreaterThanOrEqual(contrast(Ink.black, on: selection), 4.5)
        XCTAssertEqual(components(Ink.shadow, style: .dark).3, 0, accuracy: 0.001)
        XCTAssertEqual(components(Ink.shadow, style: .light).3, 1, accuracy: 0.001)
        for color in [Ink.privateField, Ink.privateCard, Ink.privateGlass] {
            let light = components(color, style: .light), dark = components(color, style: .dark)
            XCTAssertEqual(light.0, dark.0, accuracy: 0.001)
            XCTAssertEqual(light.1, dark.1, accuracy: 0.001)
            XCTAssertEqual(light.2, dark.2, accuracy: 0.001)
            XCTAssertEqual(light.3, dark.3, accuracy: 0.001)
        }
    }

    func testNewAnswerUsesSystemPrimaryAndReadableCounterInkInBothAppearances() {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let actual = components(Ink.newAnswer, style: style)
            let primary = components(Color(uiColor: .label), style: style)
            XCTAssertEqual(actual.0, primary.0, accuracy: 0.001)
            XCTAssertEqual(actual.1, primary.1, accuracy: 0.001)
            XCTAssertEqual(actual.2, primary.2, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(contrast(Ink.onNewAnswer, on: Ink.newAnswer, style: style), 4.5)
            for ground in [Ink.card, ChatInk.list] {
                XCTAssertGreaterThanOrEqual(contrast(ChatInk.newAnswer, on: ground, style: style), 4.5)
            }
        }
    }

    private func components(_ color: Color, style: UIUserInterfaceStyle) -> (Double, Double, Double, Double) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        var out: (Double, Double, Double, Double) = (0, 0, 0, 0)
        traits.performAsCurrent {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
            out = (Double(r), Double(g), Double(b), Double(a))
        }
        return out
    }

    private func contrast(_ ink: Color, on ground: Color, style: UIUserInterfaceStyle = .dark) -> Double {
        let g = components(ground, style: style), i = components(ink, style: style)
        let blended = (i.0 * i.3 + g.0 * (1 - i.3), i.1 * i.3 + g.1 * (1 - i.3), i.2 * i.3 + g.2 * (1 - i.3), 1.0)
        let values = [luminance(blended), luminance(g)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    private func luminance(_ c: (Double, Double, Double, Double)) -> Double {
        let linear: (Double) -> Double = { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return linear(c.0) * 0.2126 + linear(c.1) * 0.7152 + linear(c.2) * 0.0722
    }
}
