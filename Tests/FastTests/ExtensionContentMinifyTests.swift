import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct ExtensionContentMinifyTests {
    private func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("extension-content-memory-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"{"manifest_version":3,"name":"Content memory test","version":"1.0","background":{"service_worker":"worker.js"},"content_scripts":[{"matches":["<all_urls>"],"js":["page.js"],"run_at":"document_start"}]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "globalThis.originalWorker = true;\n".write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try "globalThis.originalContent = true;\n".write(to: folder.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        return folder
    }

    @Test func generatedContentIsBoundToTheUnchangedFullSource() {
        #expect(ExtensionShims.contentScript.hasPrefix("/* yab-extension-content source-sha256=\(hash(ExtensionShims.script)) "))
    }

    @Test func generatedContentIsBoundToTheNativePrunerOutput() {
        let expected = hash(ExtensionShims.contentPart(of: ExtensionShims.script))
        let header = ExtensionShims.contentScript.split(separator: "\n", maxSplits: 1).first
        #expect(header?.contains("content-sha256=\(expected) */") == true)
    }

    @Test func theContentSourceUsesFewerSharedMemoryPages() {
        let before = ExtensionShims.contentPart(of: ExtensionShims.script)
        let after = ExtensionShims.contentScript
        #expect(after.utf8.count < before.utf8.count * 3 / 5)
        let beforePages = (before.utf16.count * 2 + 16_383) / 16_384
        let afterPages = (after.utf16.count * 2 + 16_383) / 16_384
        #expect(afterPages < beforePages, "A compact resource must save actual 16 KiB source pages")
    }

    @Test func allEightContentFlagCombinationsRemainValidJavaScript() throws {
        let flags = ["__YAB_DCL_LATE__", "__YAB_PORT_TRACE__", "__YAB_PORT_SLOW__"]
        for mask in 0..<8 {
            var script = ExtensionShims.contentScript
            for (bit, flag) in flags.enumerated() {
                script = script.replacingOccurrences(of: flag, with: mask & (1 << bit) == 0 ? "false" : "true")
            }
            #expect(!script.contains("__YAB_"))
            let context = try #require(JSContext())
            // With no chrome.runtime the shim leaves immediately, after the
            // engine has parsed the entire script, including all its branches.
            context.evaluateScript(script)
            #expect(context.exception == nil, "flag combination \(mask): \(context.exception?.toString() ?? "")")
            #expect(context.objectForKeyedSubscript("__yabShim")?.isUndefined == true)
        }
    }

    @Test func prepareWritesCompactContentAndKeepsTheFullWorkerShim() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        try ExtensionShims.prepare(folder, fresh: true)
        let content = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.content), encoding: .utf8)
        let worker = try String(contentsOf: folder.appendingPathComponent("worker.js"), encoding: .utf8)
        #expect(content == ExtensionShims.contentShim(for: folder))
        #expect(content.hasPrefix("/* yab-extension-content "))
        #expect(!content.contains("__YAB_"))
        #expect(worker.hasPrefix(ExtensionShims.marker))
        #expect(worker.contains(ExtensionShims.ender))
        #expect(worker.hasSuffix("globalThis.originalWorker = true;\n"))
        #expect(!worker.contains("/* yab-extension-content "))
        #expect(try String(contentsOf: folder.appendingPathComponent("page.js"), encoding: .utf8) == "globalThis.originalContent = true;\n")
    }

    @Test func aPreviouslyPreparedVersionRewritesItsContentWithoutDroppingTheWorker() throws {
        let folder = try fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let oldInput = ExtensionShims.script + PasskeyRelay.page + ExtensionShims.idlePage + ExtensionShims.audioPage + ExtensionShims.revision + ExtensionShims.lateSetting
        let oldVersion = String(hash(oldInput).prefix(16)) + (Store.testing ? "-test" : "")
        #expect(oldVersion != ExtensionShims.version, "The generated resource must participate in the prepare version")
        try oldVersion.write(to: folder.appendingPathComponent(ExtensionShims.stamp), atomically: true, encoding: .utf8)
        try "old content".write(to: folder.appendingPathComponent(ExtensionShims.content), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder)
        #expect(try String(contentsOf: folder.appendingPathComponent(ExtensionShims.stamp), encoding: .utf8) == ExtensionShims.version)
        let content = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.content), encoding: .utf8)
        #expect(content.hasPrefix("/* yab-extension-content "))
        #expect(try String(contentsOf: folder.appendingPathComponent("worker.js"), encoding: .utf8).hasSuffix("globalThis.originalWorker = true;\n"))
    }
}
