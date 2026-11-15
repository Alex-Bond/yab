import AppKit
import SwiftUI
import Testing
import SyncKit
import YabDesign
@testable import Fast

@MainActor
struct FolderColorTests {
    @Test func chosenColorPaintsTheWholeFolderOverAnyWindowTone() {
        for scheme in [ColorScheme.light, .dark] {
            for windowColor in [NSColor.white, .black, .systemPurple] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                environment.tone = Tone(windowColor)
                let neutral = Face.paint(pose: .seen, tint: .orange, folder: true, in: environment)
                for tint in FolderTint.allCases where tint != .black {
                    let paint = Face.paint(pose: .seen, tint: tint.ink(dark: scheme == .dark), folder: true,
                                           folderTint: tint, in: environment)
                    let shades = Shades(on: NSColor(tint.swatch), dark: scheme == .dark)
                    #expect(paint.ink == shades.line.cgColor)
                    #expect(paint.full == shades.strongNS.cgColor)
                    #expect(paint.body == shades.body.cgColor)
                    #expect(paint.back == shades.back.cgColor)
                    #expect(paint.body != neutral.body)
                }
            }
        }
    }

    @Test func noColorKeepsTheOriginalFolderShades() {
        for scheme in [ColorScheme.light, .dark] {
            for tone in [nil, Tone(NSColor.systemPurple)] {
                var environment = EnvironmentValues()
                environment.colorScheme = scheme
                environment.tone = tone
                let expected = tone.map(Palette.shades) ?? Palette.shades(dark: scheme == .dark)
                for tint in [nil, FolderTint.black] {
                    let paint = Face.paint(pose: .seen, tint: .orange, folder: true, folderTint: tint, in: environment)
                    #expect(paint.ink == expected.line.cgColor)
                    #expect(paint.body == expected.body.cgColor)
                    #expect(paint.back == expected.back.cgColor)
                }
            }
        }
    }

    @Test func cachedFolderPicturesChangeColorOpenAndClosed() throws {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            for unfolded in [false, true] {
                for size in [CGFloat(15), 48] {
                    func picture(_ tint: FolderTint) throws -> Data {
                        let paint = Face.paint(pose: .seen, tint: tint.swatch, folder: true, folderTint: tint, in: environment)
                        let image = try #require(FaceView.picture(pose: .seen, size: size, ink: paint.ink, full: paint.full,
                                                                body: paint.body, back: paint.back, folder: true,
                                                                unfolded: unfolded, script: false, scale: 2))
                        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    }
                    let orange = try picture(.orange)
                    #expect(orange != (try picture(.blue)))
                    #expect(orange == (try picture(.orange)))
                }
            }
        }
    }

    @Test func noEditOrEscapeLeavesNoUndoStep() {
        let browser = Browser(windowID: UUID())
        let nest = Nest(name: "Design")
        nest.color = FolderTint.blue.stored
        nest.customMark = "icon:star"
        let untouched = FolderCustomizeSession(folder: nest, browser: browser)
        untouched.finish()
        #expect(browser.steps.isEmpty)

        let editing = FolderCustomizeSession(folder: nest, browser: browser)
        editing.color(.red)
        editing.mark("🎨")
        editing.cancel()
        #expect(nest.color == FolderTint.blue.stored)
        #expect(nest.customMark == "icon:star")
        #expect(browser.steps.isEmpty)
    }

    @Test func colorAndRestoredIconUndoTogether() {
        let browser = Browser(windowID: UUID())
        let nest = Nest(name: "Design")
        nest.customMark = "icon:star"
        let editing = FolderCustomizeSession(folder: nest, browser: browser)
        editing.color(.purple)
        editing.mark("🎨")
        editing.mark(nil) // Restore Folder Icon
        editing.finish()
        #expect(nest.color == FolderTint.purple.stored)
        #expect(nest.customMark == nil)
        #expect(browser.steps.count == 1)
        #expect(browser.undoWindow())
        #expect(nest.color == nil)
        #expect(nest.customMark == "icon:star")
    }

    @Test func folderMenuOpensOneCustomizer() {
        let browser = Browser(windowID: UUID())
        let nest = Nest(name: "Design")
        let menu = NSHostingMenu(rootView: NestMenu(browser: browser, nest: nest))
        let list = ActionMenuList(menu: menu, falls: true)
        let titles = list.lines.map(\.title)
        #expect(titles.contains("Customize Folder…"))
        #expect(titles.firstIndex(of: "Customize Folder…") == titles.firstIndex(of: "Rename…").map { $0 + 1 })
        #expect(!titles.contains("Change Icon…"))
        #expect(!titles.contains(where: { $0.hasPrefix("Folder Color:") }))
    }

    @Test func colorAndIconTravelTogetherThroughNestedSessionPath() throws {
        let parent = Nest(name: "Work")
        parent.color = FolderTint.purple.stored
        parent.customMark = "icon:star"
        let child = Nest(name: "Design")
        child.parent = parent
        let data = try JSONEncoder().encode(child.path)
        let restored = try JSONDecoder().decode([Session.Step].self, from: data)
        let next = Nest(name: "Design")
        var nests: [String: Nest] = [:]
        next.file(in: restored, nests: &nests)
        #expect(next.parent?.color == FolderTint.purple.stored)
        #expect(next.parent?.customMark == "icon:star")
        #expect(FolderTint(stored: nil) == .black)
        #expect(FolderTint(stored: "black").stored == nil)
    }

    @Test func syncFolderCarriesChosenColor() {
        let folder = SyncFolder(id: "folder", space: "space", name: "Design", color: FolderTint.teal.stored)
        #expect(folder.fields["color"] == .string("teal"))
        #expect(SyncFolder(id: "neutral", space: "space").fields["color"] == .null)
    }
}
