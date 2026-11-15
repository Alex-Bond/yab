import AppKit
import Testing
@testable import Fast

/// A pinned extension's tip says a short name and its button's key, loaded
/// or asleep alike (ExtensionTip, Extensions.buttons).
@Suite
struct ExtensionTipTests {
    static let nordName = "NordPass® Password Manager & Digital Vault"
    static let stackName = "BrowserStack Bug Capture: Report & resolve bugs faster"

    static let stack: [String: Any] = [
        "name": stackName,
        "action": ["default_title": stackName],
        "commands": [
            "takeScreenshot": ["suggested_key": ["default": "Alt+Shift+S"], "description": "Take a screenshot"],
            "startVideoRecording": ["suggested_key": ["default": "Alt+Shift+V"], "description": "Record video"],
            "startVideoRecordingScreen": ["global": true, "suggested_key": ["default": "Ctrl+Shift+9"]],
        ],
    ]

    @Test func storeSentencesAreCutToTheName() {
        #expect(ExtensionTip.short(Self.nordName) == "NordPass")
        #expect(ExtensionTip.short(Self.stackName) == "BrowserStack Bug Capture")
        #expect(ExtensionTip.short("Grammarly - AI Writing") == "Grammarly")
        #expect(ExtensionTip.short("uBlock Origin") == "uBlock Origin")
        #expect(ExtensionTip.short("Raycast Companion") == "Raycast Companion")
    }

    @Test func labelRuleIsTheSameLoadedOrAsleep() {
        // Loaded: the action's label is the store name, WebKit's displayName.
        #expect(ExtensionTip.label(action: Self.nordName, name: Self.nordName, displayName: Self.nordName, shortName: "NordPass") == "NordPass")
        // Asleep: the label it kept, the same store name, and the manifest's short name.
        #expect(ExtensionTip.label(action: Self.nordName, name: Self.nordName, displayName: nil, shortName: "NordPass") == "NordPass")
        // No short name: the store name cut where it turns into a sentence.
        #expect(ExtensionTip.label(action: Self.stackName, name: Self.stackName, displayName: Self.stackName, shortName: "") == "BrowserStack Bug Capture")
        #expect(ExtensionTip.label(action: "", name: Self.stackName, displayName: nil, shortName: "") == "BrowserStack Bug Capture")
        // WebKit hands the whole name over as the short name when there is none.
        #expect(ExtensionTip.label(action: Self.stackName, name: Self.stackName, displayName: Self.stackName, shortName: Self.stackName) == "BrowserStack Bug Capture")
        // A title of its own stays, as the extension's tip says it.
        #expect(ExtensionTip.label(action: "Open Claude", name: "Claude", displayName: "Claude", shortName: "") == "Open Claude")
    }

    @Test func anotherCommandsKeyIsNotTheButtons() {
        let keys = ExtensionTip.keys(Self.stack, saved: [:])
        #expect(keys.contains(.init(command: "takeScreenshot", hotkey: Hotkey("s", [.option, .shift]))))
        #expect(keys.contains(.init(command: "startVideoRecordingScreen", hotkey: Hotkey("9", [.command, .shift]))))
        #expect(ExtensionTip.buttonKey(keys) == nil)
    }

    @Test func theButtonsKeySuggestedOrSet() {
        var manifest = Self.stack
        var commands = manifest["commands"] as! [String: Any]
        commands["_execute_action"] = ["suggested_key": ["default": "Ctrl+Shift+Period", "mac": "Command+Shift+Period"]]
        commands["_execute_browser_action"] = ["suggested_key": ["default": "Alt+B"]]
        manifest["commands"] = commands
        let suggested = ExtensionTip.buttonKey(ExtensionTip.keys(manifest, saved: [:]))
        #expect(suggested == .init(command: "_execute_action", hotkey: Hotkey(".", [.command, .shift])))
        #expect(suggested?.hotkey.text == "⇧⌘.")

        // One set in Settings wins; one taken away leaves none.
        let flags = Int(NSEvent.ModifierFlags([.option, .shift]).rawValue)
        let set = ExtensionTip.keys(manifest, saved: ["_execute_action": ["key": "n", "flags": flags]])
        #expect(ExtensionTip.buttonKey(set)?.hotkey == Hotkey("n", [.option, .shift]))
        let cleared = ExtensionTip.keys(manifest, saved: ["_execute_action": ["key": "", "flags": 0]])
        #expect(ExtensionTip.buttonKey(cleared) == nil)

        // A key set for a command with no suggested key of its own.
        let added = ExtensionTip.keys(Self.stack, saved: ["takeScreenshot": ["key": "x", "flags": flags]])
        #expect(added.contains(.init(command: "takeScreenshot", hotkey: Hotkey("x", [.option, .shift]))))
    }

    @Test func comboReading() {
        #expect(ExtensionTip.hotkey("MacCtrl+Shift+Y") == Hotkey("y", [.control, .shift]))
        #expect(ExtensionTip.hotkey("Alt+Comma") == Hotkey(",", [.option]))
        #expect(ExtensionTip.hotkey("Shift+F5") == Hotkey("f5", [.shift]))
        #expect(ExtensionTip.hotkey("S") == nil)
        #expect(ExtensionTip.hotkey("Alt+MediaNextTrack") == nil)
    }

    @Test func factsReadTranslations() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tip-\(UUID().uuidString)")
        let messages = folder.appendingPathComponent("_locales/en")
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = #"{"extName": {"message": "NordPass® Password Manager & Digital Vault"}, "short": {"message": "NordPass"}}"#
        try Data(json.utf8).write(to: messages.appendingPathComponent("messages.json"))
        let manifest: [String: Any] = ["name": "__MSG_extName__", "short_name": "__MSG_short__", "default_locale": "en", "action": [:]]
        let facts = ExtensionTip.facts(manifest, folder: folder, saved: [:])
        #expect(facts.shortName == "NordPass")
        #expect(facts.title == "")
        // A key with no translation says nothing rather than __MSG_.
        let missing = ExtensionTip.facts(["short_name": "__MSG_nope__", "default_locale": "en"], folder: folder, saved: [:])
        #expect(missing.shortName == "")
    }
}

/// An extension's commands in Settings › Shortcuts: what is listed for one
/// asleep, and the alias and on switch kept for each (ExtensionCommands).
@Suite
struct ExtensionCommandsTests {
    @Test func theButtonsCommandFirstThenTheRest() {
        let commands = ExtensionTip.commands(ExtensionTipTests.stack)
        #expect(commands.first == .init(id: "_execute_action", title: ""))
        #expect(commands.map(\.id) == ["_execute_action", "startVideoRecording", "startVideoRecordingScreen", "takeScreenshot"])
        #expect(commands.last?.title == "Take a screenshot")
        // No button, no Open row.
        #expect(ExtensionTip.commands(["commands": ["go": ["description": "Go"]]]).map(\.id) == ["go"])
        // A Manifest V2 button.
        #expect(ExtensionTip.commands(["manifest_version": 2, "browser_action": [:]]).map(\.id) == ["_execute_browser_action"])
    }

    @Test func aliasAndOffKeptPerCommand() throws {
        let settings = try #require(UserDefaults(suiteName: "ExtensionCommandsTests-\(UUID().uuidString)"))
        let id = "mdplmiioglkpgkdblijgilgebpppgblm"
        #expect(ExtensionCommands.kept(id, "takeScreenshot", in: settings) == .init())
        ExtensionCommands.set(.init(alias: "shot", off: false), id, "takeScreenshot", in: settings)
        ExtensionCommands.set(.init(alias: "rec", off: true), id, "startVideoRecording", in: settings)
        #expect(ExtensionCommands.kept(id, "takeScreenshot", in: settings).alias == "shot")
        #expect(ExtensionCommands.kept(id, "startVideoRecording", in: settings).off)
        // One turned off answers to no alias.
        let aliases = ExtensionCommands.aliases(in: settings, ids: [id])
        #expect(aliases["shot"]?.command == "takeScreenshot")
        #expect(aliases["rec"] == nil)
        // Back to nothing: the entry goes, and the key with the last one.
        ExtensionCommands.set(.init(), id, "takeScreenshot", in: settings)
        ExtensionCommands.set(.init(), id, "startVideoRecording", in: settings)
        #expect(settings.dictionary(forKey: ExtensionCommands.key(id)) == nil)
    }

    @Test func aliasesAreCleaned() {
        #expect(ExtensionCommands.clean("  Shot ") == "shot")
    }
}

/// A square extension icon gets an app icon's corners; a round or rounded
/// one stays as it is (ExtensionIconShape).
@Suite
struct ExtensionIconShapeTests {
    static func drawn(_ shape: @escaping (NSRect) -> NSBezierPath) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            shape(rect).fill()
            return true
        }
    }

    static func alpha(_ image: NSImage, _ x: Int, _ y: Int) -> CGFloat {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
    }

    @Test func aSquareIsRounded() {
        let square = Self.drawn { NSBezierPath(rect: $0) }
        #expect(ExtensionIconShape.isSquare(square))
        let rounded = ExtensionIconShape.clipped(square)
        #expect(Self.alpha(rounded, 0, 0) < 0.1)
        #expect(Self.alpha(rounded, 32, 32) > 0.9)
        #expect(Self.alpha(rounded, 32, 0) > 0.9)
    }

    @Test func roundAndRoundedStayAsTheyAre() {
        #expect(!ExtensionIconShape.isSquare(Self.drawn { NSBezierPath(ovalIn: $0) }))
        #expect(!ExtensionIconShape.isSquare(Self.drawn { NSBezierPath(roundedRect: $0, xRadius: 12, yRadius: 12) }))
        // An icon with room round it, as many have.
        #expect(!ExtensionIconShape.isSquare(Self.drawn { NSBezierPath(rect: $0.insetBy(dx: 6, dy: 6)) }))
    }

    @MainActor @Test func theSameIconIsCutOnce() {
        let square = Self.drawn { NSBezierPath(rect: $0) }
        let first = ExtensionIconShape.rounded(square)
        #expect(first !== square)
        #expect(ExtensionIconShape.rounded(square) === first)
        let round = Self.drawn { NSBezierPath(ovalIn: $0) }
        #expect(ExtensionIconShape.rounded(round) === round)
    }
}
