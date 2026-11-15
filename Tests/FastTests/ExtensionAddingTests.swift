import AppKit
import Foundation
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionAddingTests {
    @Test func folderApprovalRepairsConcurrentNativeAdoptionAndSurvivesRestart() throws {
        _ = NSApplication.shared
        let signIn = UUID()
        let file = Extensions.list(of: signIn)
        defer { try? FileManager.default.removeItem(at: file) }
        let list = Extensions(signIn: signIn)
        let id = "abcdefghijklmnopabcdefghijklmnop"
        let source = URL(fileURLWithPath: "/tmp/custom extension with spaces")
        // A native list read can finish while the approved load is awaiting
        // its reply. Its generic adoption must not turn a folder into a store ID.
        list.takeNative(id: id, name: "Custom", version: "1.0", enabled: true)
        list.takeNative(id: id, name: "Custom", version: "1.0", enabled: true,
                        fromStore: false, source: source, permissions: ["permission:tabs"])
        list.takeNative(id: id, name: "Custom", version: "1.0", enabled: true)
        #expect(list.installed.count == 1)
        let reopened = Extensions(signIn: signIn)
        let item = try #require(reopened.installed.first)
        #expect(item.id == id)
        #expect(!item.fromStore)
        #expect(item.source == source.path)
        #expect(item.permissions == ["permission:tabs"])
        #expect(item.enabled)
        #expect(reopened.contexts.isEmpty)
    }
}
