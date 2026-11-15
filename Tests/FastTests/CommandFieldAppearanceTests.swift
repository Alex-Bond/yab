import AppKit
import SwiftUI
import Testing
@testable import Fast

@MainActor
struct CommandFieldAppearanceTests {
    @Test func explicitThemeWinsOverSystemAppearance() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let system = try #require(NSAppearance(named: name))
            let light = Look.light.appearance ?? system
            let dark = Look.dark.appearance ?? system
            #expect(Omnibox.colorScheme(for: light) == .light)
            #expect(Omnibox.colorScheme(for: dark) == .dark)
        }
    }

    @Test func systemThemeFollowsSystemAppearance() throws {
        #expect(Look.system.appearance == nil)
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let system = try #require(NSAppearance(named: name))
            let app = Look.system.appearance ?? system
            #expect(Omnibox.colorScheme(for: app) == (name == .darkAqua ? .dark : .light))
        }
    }

    @Test func accessibilityAppearancesKeepTheirScheme() throws {
        let light = try #require(NSAppearance(named: .accessibilityHighContrastAqua))
        let dark = try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        #expect(Omnibox.colorScheme(for: light) == .light)
        #expect(Omnibox.colorScheme(for: dark) == .dark)
    }

    @Test func privateFieldsKeepTheirExistingDarkAppearance() throws {
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let app = try #require(NSAppearance(named: name))
            #expect(Omnibox.colorScheme(for: app, privateField: true) == .dark)
        }
    }
}
