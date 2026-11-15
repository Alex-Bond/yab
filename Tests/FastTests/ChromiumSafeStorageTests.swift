import Foundation
import Security
import Testing
@testable import Fast

struct ChromiumSafeStorageTests {
    @Test func existingSecretIsUsedByteForByte() throws {
        let old = Data("original-0.47.8-secret".utf8)
        let result = try ChromiumSafeStorage.obtain(read: { (errSecSuccess, old) },
            add: { _ in Issue.record("must not write an existing item"); return errSecIO },
            random: { Issue.record("must not rotate a key"); return Data() })
        #expect(result == old)
    }

    @Test func denialAndCorruptionNeverCreateOrRotateAKey() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable, errSecSuccess] {
            #expect(throws: (any Error).self) {
                try ChromiumSafeStorage.obtain(read: { (status, nil) },
                    add: { _ in Issue.record("must not replace an unreadable item"); return errSecIO },
                    random: { Issue.record("must not create a key after denial"); return Data() })
            }
        }
    }

    @Test func onlyAbsenceCreatesAKey() throws {
        let fresh = Data("fresh-synthetic-key".utf8)
        var written: Data?
        let result = try ChromiumSafeStorage.obtain(read: { (errSecItemNotFound, nil) },
            add: { written = $0; return errSecSuccess }, random: { fresh })
        #expect(result == fresh)
        #expect(written == fresh)
    }

    @Test func concurrentFirstCreationKeepsTheWinningSecret() throws {
        let winner = Data("other-Yab-process-key".utf8)
        var reads = 0
        let result = try ChromiumSafeStorage.obtain(read: {
            reads += 1
            return reads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, winner)
        }, add: { _ in errSecDuplicateItem }, random: { Data("losing-random-key".utf8) })
        #expect(result == winner)
        #expect(reads == 2)
    }

    @Test func failedPersistenceCannotBecomeASessionOnlyEncryptionKey() {
        #expect(throws: (any Error).self) {
            try ChromiumSafeStorage.obtain(read: { (errSecItemNotFound, nil) },
                add: { _ in errSecInteractionNotAllowed }, random: { Data("unsaved".utf8) })
        }
    }
}

struct ChromiumSafeStorageBrokerTests {
    private func exchange(expectedChild: Bool, authorized: Bool = true, provide: @escaping @Sendable () throws -> Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ys-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("key.sock").path
        let broker = try ChromiumSafeStorageBroker(path: path, authorize: { _ in authorized }, provide: provide)
        defer { broker.stop() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(sys.argv[1]); data=b''\nwhile True:\n p=s.recv(8192)\n if not p: break\n data+=p\nsys.stdout.buffer.write(data)", path]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        broker.launched(pid: expectedChild ? child.processIdentifier : getpid())
        let frame = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        #expect(child.terminationStatus == 0)
        return frame
    }

    @Test func exactChildGetsTheExistingSecretOnce() throws {
        let secret = Data("synthetic-existing-key".utf8)
        let frame = try exchange(expectedChild: true, provide: { secret })
        var length = UInt32(secret.count).bigEndian
        var expected = withUnsafeBytes(of: &length) { Data($0) }
        expected.append(secret)
        #expect(frame == expected)
    }

    @Test func anotherProcessCannotTriggerAKeychainRead() throws {
        let frame = try exchange(expectedChild: false, provide: {
            Issue.record("unauthenticated peer must never read Keychain")
            return Data("must-not-leave".utf8)
        })
        #expect(frame.isEmpty)
    }

    @Test func aLaunchedButUntrustedImageCannotReadTheKey() throws {
        let frame = try exchange(expectedChild: true, authorized: false, provide: {
            Issue.record("an untrusted image must never receive the owner's key")
            return Data("must-not-leave".utf8)
        })
        #expect(frame.isEmpty)
    }

    @Test func aDifferentSignedExecutableDoesNotAuthorizeTheTestProcess() {
        #expect(!ChromiumSafeStorage.authorizes(pid: getpid(), helper: URL(fileURLWithPath: "/usr/bin/true")))
    }

    @Test func deniedAccessClosesTheChannelWithoutAFallbackKey() throws {
        let frame = try exchange(expectedChild: true, provide: {
            throw ChromiumSafeStorage.Failure(status: errSecAuthFailed)
        })
        #expect(frame.isEmpty)
    }
}
