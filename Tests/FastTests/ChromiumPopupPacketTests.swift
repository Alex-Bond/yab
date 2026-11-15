import AppKit
import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized)
@MainActor
struct ChromiumPopupPacketTests {
    private let id = String(repeating: "a", count: 32)
    private let profile = "popup-fixture-profile"

    private func packet(_ state: String = "frame", token: String = "original-popup") -> [String: JSONValue] {
        ["profile": .string(profile), "state": .string(state), "token": .string(token), "extensionId": .string(id),
         "contextId": .number(42), "pixelWidth": .number(800), "pixelHeight": .number(600), "scale": .number(2)]
    }

    @Test func nativeRetinaGeometryUsesOriginalContextAndPointSize() throws {
        let value = try #require(ChromiumPopupPacket(packet(), profile: profile))
        let frame = try #require(value.frame)
        #expect(frame.context == 42 && frame.width == 400 && frame.height == 300)
        #expect(frame.pixelWidth == 800 && frame.pixelHeight == 600 && frame.scale == 2)
        #expect(ChromiumPopupPacket(packet("shown"), profile: profile)?.frame == nil)
        #expect(ChromiumPopupPacket(packet("closed"), profile: profile)?.frame == nil)
    }

    @Test func invalidContextNeverReachesTrappingIntegerConversion() {
        for invalid in [-1.0, 0, 0.5, .nan, .infinity, -.infinity, Double(UInt32.max) + 1, 1e100] {
            var p = packet(); p["contextId"] = .number(invalid)
            #expect(ChromiumPopupPacket(p, profile: profile) == nil)
        }
        var p = packet(); p["contextId"] = .number(Double(UInt32.max))
        #expect(ChromiumPopupPacket(p, profile: profile)?.frame?.context == UInt32.max)
    }

    @Test func invalidSurfaceDimensionsAndScaleAreNotClampedIntoAVisiblePopup() {
        for key in ["pixelWidth", "pixelHeight"] {
            for invalid in [-1.0, 0, 0.5, .nan, .infinity, 32769, 1e100] {
                var p = packet(); p[key] = .number(invalid)
                #expect(ChromiumPopupPacket(p, profile: profile) == nil)
            }
        }
        for invalid in [-1.0, 0, 0.5, .nan, .infinity, 8.1] {
            var p = packet(); p["scale"] = .number(invalid)
            #expect(ChromiumPopupPacket(p, profile: profile) == nil)
        }
        var p = packet(); p["pixelWidth"] = .number(32768); p["scale"] = .number(1)
        #expect(ChromiumPopupPacket(p, profile: profile) == nil)
    }

    @Test func unknownStateMissingIdentityAndForeignProfileAreRejected() {
        #expect(ChromiumPopupPacket(packet(), profile: "foreign") == nil)
        #expect(ChromiumPopupPacket(packet("unexpected"), profile: profile) == nil)
        for key in ["profile", "state", "token", "extensionId", "contextId", "pixelWidth", "pixelHeight", "scale"] {
            var p = packet(); p.removeValue(forKey: key)
            #expect(ChromiumPopupPacket(p, profile: profile) == nil)
        }
        for invalid in ["", "not-an-original-id", String(repeating: "q", count: 32)] {
            var p = packet(); p["extensionId"] = .string(invalid)
            #expect(ChromiumPopupPacket(p, profile: profile) == nil)
        }
        for invalid in ["", "token\u{0}suffix", String(repeating: "a", count: 257)] {
            var p = packet(); p["token"] = .string(invalid)
            #expect(ChromiumPopupPacket(p, profile: profile) == nil)
        }
    }

    @Test func malformedForeignAndRetiredEventsCannotMutateOriginalPopup() throws {
        _ = NSApplication.shared
        let tab = Tab(shy: true)
        let page = ChromiumPage(tab: tab, profile: profile)
        defer { page.retire(call: false, pictureInPicture: false); tab.close() }
        var changed = 0
        page.onExtensionPopup = { _ in changed += 1 }
        page.receivePopup(packet("shown"))
        let original = try #require(page.extensionPopup)
        #expect(changed == 1 && !original.closed && original.contextID == 0)
        var malformed = packet(); malformed["contextId"] = .number(-1)
        page.receivePopup(malformed)
        var foreign = packet("closed"); foreign["extensionId"] = .string(String(repeating: "b", count: 32))
        page.receivePopup(foreign)
        page.receivePopup(packet("closed", token: "another-popup"))
        #expect(page.extensionPopup === original && changed == 1 && !original.closed && original.contextID == 0)
        original.close()
        original.update(try #require(ChromiumPopupPacket(packet(), profile: profile)?.frame))
        page.receivePopup(packet())
        #expect(original.closed && original.contextID == 0 && original.pointSize == .zero)
        #expect(page.extensionPopup === original && changed == 1)
        page.receivePopup(packet("closed"))
        #expect(page.extensionPopup == nil && changed == 2)
        #expect(page.remoteID == nil)
    }

    @Test func extensionCreationIndexAndEndpointNeverUseTrappingOrForeignFallbacks() throws {
        var value: [String: JSONValue] = ["tab": .string("original-child"), "extensionId": .string(id),
                                       "active": .bool(true), "openerTab": .string("original-owner")]
        #expect(try #require(ExtensionTabRequest(value, remoteID: "original-child", profile: profile)).index == -1)
        for valid in [-1.0, 0, 3, Double(Int32.max)] {
            value["index"] = .number(valid)
            #expect(ExtensionTabRequest(value, remoteID: "original-child", profile: profile)?.index == Int(exactly: valid))
        }
        for invalid in [-2.0, -0.5, 1.5, .nan, .infinity, 1e100, Double(Int32.max) + 1] {
            value["index"] = .number(invalid)
            #expect(ExtensionTabRequest(value, remoteID: "original-child", profile: profile) == nil)
        }
        value["index"] = .number(0)
        #expect(ExtensionTabRequest(value, remoteID: "foreign-child", profile: profile) == nil)
        var foreign = value; foreign["profile"] = .string("foreign")
        #expect(ExtensionTabRequest(foreign, remoteID: "original-child", profile: profile) == nil)
        foreign = value; foreign["extensionId"] = .string("not-an-extension")
        #expect(ExtensionTabRequest(foreign, remoteID: "original-child", profile: profile) == nil)
        foreign = value; foreign["openerTab"] = .string("original-child")
        #expect(ExtensionTabRequest(foreign, remoteID: "original-child", profile: profile) == nil)
        foreign = value; foreign["active"] = .number(1)
        #expect(ExtensionTabRequest(foreign, remoteID: "original-child", profile: profile) == nil)
    }
}
