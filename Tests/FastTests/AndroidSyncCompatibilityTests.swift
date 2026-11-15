import Foundation
@testable import SyncKit
import Testing
@testable import Fast

struct AndroidSyncCompatibilityTests {
    private final class MetadataTransport: Transport, @unchecked Sendable {
        let server = MemoryServer()
        let lock = NSLock()
        var events: [String] = []
        var requests: [URLRequest] = []
        var socketHeaders: [String?] = []
        func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
            lock.lock(); events.append("register"); requests.append(request); lock.unlock()
            server.request(request, done)
        }
        func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line {
            lock.lock(); events.append("socket"); socketHeaders.append(request.value(forHTTPHeaderField: "X-Yab-Android-Sync")); lock.unlock()
            return server.open(request, received: received, closed: closed)
        }
    }

    @Test func aCachedTokenStillRefreshesCapabilityBeforeOpeningEachRun() async throws {
        let transport = MetadataTransport()
        let client = SyncClient(base: URL(string: "https://sync.test")!, journal: try Journal(path: nil, device: "mac"), seal: Seal.make(),
                                device: .init(id: "mac", name: "Mac", model: "Mac15,3"), token: "cached-before-upgrade", transport: transport)
        defer { client.stop() }
        func until(_ expected: SyncClient.State) async -> Bool {
            for _ in 0..<200 {
                if client.queue.sync(execute: { client.state == expected }) { return true }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return false
        }
        client.start()
        #expect(await until(.live))
        client.stop()
        #expect(await until(.off))
        client.start()
        #expect(await until(.live))
        transport.lock.lock()
        let events = transport.events, requests = transport.requests, headers = transport.socketHeaders
        transport.lock.unlock()
        #expect(events == ["register", "socket", "register", "socket"])
        #expect(headers == ["1", "1"])
        let body = try #require(requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let device = try #require(json["device"] as? [String: Any])
        #expect(device["platform"] as? String == "macos")
        #expect(device["formFactor"] as? String == "desktop")
        #expect(device["androidSync"] as? Int == 1)
    }

    @Test func explicitAndroidPlatformNeverBecomesAMacByItsModel() {
        let android = SyncClient.Listed(id: "android", name: "Pixel", model: "Mac15,3", lastSeen: nil, revoked: false,
                                        platform: "android", formFactor: "phone", androidSync: 1)
        #expect(android.isMobile)
        #expect(!android.isMac)
        let unknown = SyncClient.Listed(id: "unknown", name: "Other", model: "Other hardware", lastSeen: nil, revoked: false)
        #expect(!unknown.isMac)
        #expect(!unknown.isMobile)
        let legacyMac = SyncClient.Listed(id: "mac", name: "Mac", model: "Mac15,3", lastSeen: nil, revoked: false)
        #expect(legacyMac.isMac)
        #expect(legacyMac.androidSync == 0)
        let legacyPhone = SyncClient.Listed(id: "phone", name: "iPad", model: "iPad14,3", lastSeen: nil, revoked: false)
        #expect(legacyPhone.isMobile)
        #expect(!legacyPhone.isMac)
    }

    @Test func anAndroidPhonesCapabilityMustBeSelfStampedIncludingItsPlatform() throws {
        let android = try Journal(path: nil, device: "android")
        let fields: [String: Value] = ["device": "android", "kind": "android", "platform": "android", "open": 1, "androidSync": 1]
        let own = try android.change(.init(collection: OpenOnMac.capability, id: "android"), fields)
        #expect(OpenOnPhone.supports(own, device: "android"))
        #expect(AndroidSyncCompatibility.supports(own, device: "android"))
        let mac = try Journal(path: nil, device: "mac")
        let forged = try mac.change(.init(collection: OpenOnMac.capability, id: "android"), fields)
        #expect(!OpenOnPhone.supports(forged, device: "android"))
        #expect(!AndroidSyncCompatibility.supports(forged, device: "android"))
        var incomplete = fields
        incomplete.removeValue(forKey: "androidSync")
        let noVersion = try android.change(.init(collection: OpenOnMac.capability, id: "missing"), incomplete.merging(["device": "missing"]) { _, new in new })
        #expect(!OpenOnPhone.supports(noVersion, device: "missing"))
    }

    @Test func aMacAdvertisesAndroidCompatibilityInItsOwnCapability() throws {
        let mac = try Journal(path: nil, device: "mac")
        let own = try mac.change(.init(collection: OpenOnMac.capability, id: "mac"), SyncChats.capability(device: "mac"))
        #expect(AndroidSyncCompatibility.supports(own, device: "mac"))
        #expect(OpenOnMac.supports(own, device: "mac"))
        #expect(!OpenOnPhone.supports(own, device: "mac"))
    }
}
