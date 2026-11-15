import AppKit
import Testing
import WebKit
@testable import Fast

/// NordPass checks its vault database before starting OAuth and keeps a
/// separate Dexie logging database with an auto-increment primary key.
@MainActor
@Suite(.serialized)
struct ExtensionIndexedDBTests {
    @Test(arguments: [false, true], [false, true])
    func extensionPagesCommitAndReadIndexedDB(prepared: Bool, persistent: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-idb-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"IndexedDB test","version":"1.0","permissions":["storage","unlimitedStorage"]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "<html><head><script src=database.js></script></head><body>Database fixture</body></html>"
            .write(to: folder.appendingPathComponent("app.html"), atomically: true, encoding: .utf8)
        try Self.database.write(to: folder.appendingPathComponent("database.js"), atomically: true, encoding: .utf8)
        if prepared { try ExtensionShims.prepare(folder, fresh: true) }
        let ext = try await WKWebExtension(resourceBaseURL: folder)
        let context = WKWebExtensionContext(for: ext)
        WKWebExtension.MatchPattern.registerCustomURLScheme(Extensions.scheme)
        context.baseURL = URL(string: "chrome-extension://idb-\(UUID().uuidString.lowercased())/")!
        let configuration = persistent ? WKWebExtensionController.Configuration(identifier: UUID()) : .nonPersistent()
        let store = persistent ? WKWebsiteDataStore(forIdentifier: UUID()) : .nonPersistent()
        configuration.defaultWebsiteDataStore = store
        let views = WKWebViewConfiguration()
        views.websiteDataStore = store
        views.preferences.inactiveSchedulingPolicy = .none
        configuration.webViewConfiguration = views
        let controller = WKWebExtensionController(configuration: configuration)
        try controller.load(context)
        defer { try? controller.unload(context) }
        let config = try #require(context.webViewConfiguration)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), configuration: config)
        web.load(URLRequest(url: context.baseURL.appendingPathComponent("app.html")))
        var result: String?
        for _ in 0..<200 {
            result = (try? await web.evaluateJavaScript("JSON.stringify(globalThis.databaseResult ?? null)")) as? String
            if result != nil, result != "null" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(result == #"{"logs":2,"vault":"fixture","bytes":3}"#, "IndexedDB result: \(result ?? "timed out")")
        // A second view sees the same committed data after closing the first
        // connection, as the extension page and its worker need to.
        let reader = WKWebView(frame: .zero, configuration: config)
        reader.load(URLRequest(url: context.baseURL.appendingPathComponent("app.html")))
        var reread: String?
        for _ in 0..<200 {
            reread = (try? await reader.evaluateJavaScript("JSON.stringify(globalThis.databaseResult ?? null)")) as? String
            if reread != nil, reread != "null" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(reread == #"{"logs":4,"vault":"fixture","bytes":3}"#, "Second IndexedDB view: \(reread ?? "timed out")")
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    private static let database = #"""
    (async () => {
      const request = r => new Promise((resolve, reject) => {
        r.onsuccess = () => resolve(r.result);
        r.onerror = () => reject(r.error);
      });
      const complete = t => new Promise((resolve, reject) => {
        t.oncomplete = resolve;
        t.onabort = () => reject(t.error || new Error('Transaction aborted'));
        t.onerror = () => reject(t.error);
      });
      try {
        const opening = indexedDB.open('logging', 1);
        opening.onupgradeneeded = () => {
          const logs = opening.result.createObjectStore('jsLogs', {autoIncrement:true});
          for (const key of ['message','timestamp','logLevel','logSource']) logs.createIndex(key,key);
        };
        const logs = await request(opening);
        for (let i=0; i<2; i++) {
          const tx = logs.transaction('jsLogs','readwrite'), done = complete(tx);
          await request(tx.objectStore('jsLogs').add({message:'fixture',timestamp:'2026',logLevel:'Info',logSource:'page'}));
          await done;
        }
        const openingVault = indexedDB.open('vault', 10);
        openingVault.onupgradeneeded = () => {
          const db = openingVault.result;
          db.createObjectStore('metadata',{keyPath:'uuid'});
          const keys = db.createObjectStore('applicationKeys',{keyPath:'id',autoIncrement:true});
          keys.createIndex('identityUser',['identityUuid','userUuid']);
          db.createObjectStore('appData',{keyPath:'id',autoIncrement:true});
        };
        const vault = await request(openingVault);
        const tx = vault.transaction(['metadata','appData'],'readwrite'), done = complete(tx);
        tx.objectStore('metadata').put({uuid:'fixture',data:new Uint8Array([1,2,3])});
        tx.objectStore('appData').add({name:'fixture'});
        await done;
        const record = await request(vault.transaction('metadata').objectStore('metadata').get('fixture'));
        const count = await request(logs.transaction('jsLogs').objectStore('jsLogs').count());
        databaseResult = {logs:count,vault:record.uuid,bytes:record.data.length};
        logs.close(); vault.close();
      } catch (e) { databaseResult = {error:e.name,message:e.message}; }
    })();
    """#
}
