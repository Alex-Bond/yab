import Foundation

/// Explicit fixture-only evidence for the linked-color failure. Never enabled
/// in normal launches or Release, and never records page/account content.
@MainActor
enum LookEditDiagnostics {
    #if DEBUG
    private static var lastPath: String?
    private static var rows = 0
    #endif

    static func bind(_ model: SpaceTrayModel, in app: AppModel) -> String? {
        #if DEBUG
        guard app.isFixture, output != nil else { return nil }
        model.diagnosticOwner = model.diagnosticID
        return model.diagnosticID
        #else
        return nil
        #endif
    }

    static func record(_ event: String, owner: String, look: SpaceLook, space: Space.ID? = nil,
                       links: Int? = nil, primary: LookColor? = nil, following: [LookColor]? = nil) {
        #if DEBUG
        guard let url = output else { return }
        if lastPath != url.path { lastPath = url.path; rows = 0 }
        guard rows < 256 else { return }
        var row: [String: Any] = ["event": event, "owner": owner, "time": ProcessInfo.processInfo.systemUptime,
                                  "fixture": true, "primary": SpaceLook.hex(look.primary),
                                  "inputColors": look.colors.map(SpaceLook.hex), "storageKeys": look.raw.object?.keys.sorted() ?? []]
        if let space { row["space"] = space }
        if let links { row["links"] = links }
        if let primary { row["handlePrimary"] = SpaceLook.hex(primary.rgb) }
        if let following {
            row["renderedColors"] = following.map { SpaceLook.hex($0.rgb) }
            row["renderedPoints"] = following.map { [Double($0.point.x), Double($0.point.y)] }
        }
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size + UInt64(data.count) <= 65_536 else { return }
        do { try handle.write(contentsOf: data); rows += 1 } catch { return }
        #endif
    }

    #if DEBUG
    private static var output: URL? {
        let env = ProcessInfo.processInfo.environment
        guard env["YAB_TEST"] == "1", let path = env["YAB_LOOK_DIAGNOSTIC_PATH"],
              path.hasPrefix("/"), !path.hasSuffix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }
    #endif
}
