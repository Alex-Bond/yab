import Foundation
import CryptoKit
import Testing
@testable import Fast

@Suite(.serialized)
struct ApplePasswordsTests {
    @Test func onlyAwakeTimeCountsTowardTheNativePortExpiry() {
        let heard = SuspendingClock.now
        #expect(ExtensionNative.nativeHostAlive(since: heard, now: heard))
        #expect(ExtensionNative.nativeHostAlive(since: heard, now: heard.advanced(by: .seconds(79))))
        #expect(!ExtensionNative.nativeHostAlive(since: heard, now: heard.advanced(by: .seconds(80))))
        #expect(!ExtensionNative.nativeHostAlive(since: heard, now: heard.advanced(by: .seconds(100))))
        let beat = heard.advanced(by: .seconds(75))
        #expect(ExtensionNative.nativeHostAlive(since: beat, now: heard.advanced(by: .seconds(100))))
    }

    private final class Messages: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func heard() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await condition())
    }

    private func script(_ body: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("apple-passwords-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("helper")
        try ("#!/usr/bin/python3\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    @Test func repliesBeforeTheReaderAndInOneChunkAreKept() async throws {
        let program = try script("""
        import json, struct, sys, time
        frames = b''
        for cmd in [14, 15, 4]:
            body = json.dumps({'cmd': cmd}).encode()
            frames += struct.pack('<I', len(body)) + body
        sys.stdout.buffer.write(frames)
        sys.stdout.buffer.flush()
        time.sleep(30)
        """)
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let pipe = HostPipe(program: program, origin: "test", buffersReplies: true)
        let messages = Messages()
        pipe.onMessage = { _ in messages.heard() }
        defer { pipe.stop() }
        try pipe.start()
        let timeout = Task {
            try await Task.sleep(for: .seconds(5))
            pipe.stop()
        }
        defer { timeout.cancel() }
        // The old transport loses all three before a read is installed.
        try await eventually { messages.total == 3 }
        for cmd in [14, 15, 4] {
            let reply = try await pipe.readOne() as? [String: Any]
            #expect(reply?["cmd"] as? Int == cmd)
        }
    }

    @Test func pushesAreHeardWhileAReaderIsWaiting() async throws {
        let program = try script("""
        import json, struct, sys, time
        sys.stdin.buffer.read(1)
        body = json.dumps({'cmd': 10}).encode()
        sys.stdout.buffer.write(struct.pack('<I', len(body)) + body)
        sys.stdout.buffer.flush()
        time.sleep(30)
        """)
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let pipe = HostPipe(program: program, origin: "test", buffersReplies: true)
        let messages = Messages()
        pipe.onMessage = { _ in messages.heard() }
        defer { pipe.stop() }
        try pipe.start()
        let read = Task { try await pipe.readOne() }
        try pipe.write(["cmd": 4])
        let reply = try await read.value as? [String: Any]
        #expect(reply?["cmd"] as? Int == 10)
        try await eventually { messages.total == 1 }
    }

    @Test func pairingSurvivesRepeatedRequestsAndMalformedReplies() async throws {
        let program = try helper(ending: "pass")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        #expect(await passwords.isPaired)
        for _ in 0..<10 {
            // A failed query is not evidence that Apple ended the session.
            await #expect(throws: ApplePasswordsSRP.Failure.unexpected) {
                _ = try await passwords.logins(for: "example.test")
            }
            #expect(await passwords.isPaired)
        }
        await passwords.cancelPairing()
        #expect(await passwords.isPaired)
    }

    @Test(arguments: [9, 10])
    func applesSessionEndingPushRequiresPairing(cmd: Int) async throws {
        let program = try helper(ending: "send({'cmd': \(cmd)})")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        #expect(await passwords.isPaired)
        await passwords.cancelPairing()
        try await eventually { await !passwords.isPaired }
    }

    @Test func anActualHelperExitRequiresANewPairing() async throws {
        let program = try helper(ending: "sys.exit(0)")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        #expect(await passwords.isPaired)
        await passwords.cancelPairing()
        try await eventually { await !passwords.isPaired }
        // A fresh helper negotiates a fresh key, rather than reusing the old one.
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        #expect(await passwords.isPaired)
        await passwords.cancelPairing()
    }

    @Test func aReloginPushDuringPairingCannotBeOverwrittenByTheReply() async throws {
        let program = try helper(ending: "pass", beforeProof: "send({'cmd': 10}); time.sleep(0.1)")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        await #expect(throws: ApplePasswords.Failure.notPaired) {
            try await passwords.finishPairing(code: "123456")
        }
        #expect(await !passwords.isPaired)
    }

    @Test func aSlowAnswerKeepsTheHelperAndIsNotTheNextRequestsAnswer() async throws {
        // The first answer comes after the wait ran out; the second never.
        let program = try helper(ending: "pass", logins: """
        logins = globals().get('logins', 0) + 1
                if logins == 1:
                    time.sleep(0.4)
                    send({'cmd': 4, 'payload': {}})
        """)
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program, patience: 0.02)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        let helperBefore = await passwords.processIdentifier
        await #expect(throws: ApplePasswords.Failure.timedOut) {
            _ = try await passwords.logins(for: "first.test")
        }
        try await Task.sleep(for: .milliseconds(500))
        // Taken for this request's answer it would fail as malformed at once.
        await #expect(throws: ApplePasswords.Failure.timedOut) {
            _ = try await passwords.logins(for: "second.test")
        }
        #expect(await passwords.isPaired)
        #expect(await passwords.processIdentifier == helperBefore)
    }

    @Test func aSaveNeverAnsweredKeepsTheSessionEvenWithListsUnheard() async throws {
        let program = try helper(ending: "pass", logins: "pass")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program, patience: 0.005)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        let helperBefore = await passwords.processIdentifier
        await #expect(throws: ApplePasswords.Failure.timedOut) {
            try await passwords.save(host: "example.test", user: "fixture", password: "fixture")
        }
        // Apple's alert may be up: the helper isn't called stuck meanwhile.
        for _ in 0..<4 {
            await #expect(throws: ApplePasswords.Failure.timedOut) {
                _ = try await passwords.logins(for: "example.test")
            }
        }
        #expect(await passwords.isPaired)
        #expect(await passwords.processIdentifier == helperBefore)
    }

    @Test func repeatedMissingAnswersNeverDestroyThePairedHelper() async throws {
        let program = try helper(ending: "pass", logins: "pass")
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program, patience: 0.02)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        let helperBefore = await passwords.processIdentifier
        for _ in 0..<6 {
            await #expect(throws: ApplePasswords.Failure.timedOut) {
                _ = try await passwords.logins(for: "example.test")
            }
        }
        #expect(await passwords.isPaired)
        #expect(await passwords.processIdentifier == helperBefore)
    }

    @Test func aReadRunsOutWithTheHostAliveAndItsLaterWordKept() async throws {
        let program = try script("""
        import json, struct, sys, time
        time.sleep(0.4)
        body = json.dumps({'cmd': 4}).encode()
        sys.stdout.buffer.write(struct.pack('<I', len(body)) + body)
        sys.stdout.buffer.flush()
        time.sleep(30)
        """)
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let pipe = HostPipe(program: program, origin: "test", buffersReplies: true)
        defer { pipe.stop() }
        try pipe.start()
        // A deadline already past doesn't hang the read.
        await #expect(throws: ApplePasswords.Failure.timedOut) {
            _ = try await pipe.readOne(until: SuspendingClock.now, otherwise: ApplePasswords.Failure.timedOut)
        }
        let reply = try await pipe.readOne(until: SuspendingClock.now.advanced(by: .seconds(5)), otherwise: ApplePasswords.Failure.timedOut) as? [String: Any]
        #expect(reply?["cmd"] as? Int == 4)
    }

    /// A separate process using the helper's framing and SRP server math.
    /// No Apple Account, Keychain, credentials or browser entitlement.
    private func helper(ending: String, beforeProof: String = "pass", codes: String = "pass",
                        logins: String = "send({'cmd': 4, 'payload': {}})", saves: String = "pass") throws -> URL {
        try script("""
        import base64, hashlib, json, struct, sys, time
        N = int('\(ApplePasswordsSRP.N.bytes.map { String(format: "%02x", $0) }.joined())', 16)
        g, b, salt = 5, 987654321, b'fixture-salt'
        def raw(n): return n.to_bytes((n.bit_length() + 7) // 8, 'big')
        def pad(n): return n.to_bytes(384, 'big')
        def sha(*parts): return hashlib.sha256(b''.join(parts)).digest()
        def number(data): return int.from_bytes(data, 'big')
        def enc(data): return base64.b64encode(data).decode()
        def send(obj):
            body = json.dumps(obj).encode()
            sys.stdout.buffer.write(struct.pack('<I', len(body)) + body)
            sys.stdout.buffer.flush()
        while True:
            size = sys.stdin.buffer.read(4)
            if len(size) != 4: break
            msg = json.loads(sys.stdin.buffer.read(struct.unpack('<I', size)[0]))
            cmd = msg['cmd']
            if cmd == 14:
                send({'cmd': 14, 'capabilities': {'shouldUseBase64': True, 'canFillOneTimeCodes': True}})
            elif cmd == 2:
                payload = json.loads(msg['msg'])
                pake = json.loads(base64.b64decode(payload['PAKE']))
                if pake['MSG'] == 0:
                    tid = pake['TID']
                    A = number(base64.b64decode(pake['A']))
                    x = number(sha(salt, sha((tid + ':123456').encode())))
                    v = pow(g, x, N)
                    k = number(sha(pad(N), pad(g)))
                    B = (k * v + pow(g, b, N)) % N
                    u = number(sha(pad(A), pad(B)))
                    K = sha(raw(pow(A * pow(v, u, N) % N, b, N)))
                    M = sha(bytes(a ^ z for a, z in zip(sha(raw(N)), sha(pad(g)))), sha(tid.encode()), salt, raw(A), raw(B), K)
                    hamk = sha(raw(A), M, K)
                    reply = {'TID': tid, 'MSG': 1, 'PROTO': 1, 's': enc(salt), 'B': enc(raw(B))}
                else:
                    assert base64.b64decode(pake['M']) == M
                    \(beforeProof)
                    reply = {'TID': tid, 'MSG': 3, 'ErrCode': 0, 'HAMK': enc(hamk)}
                send({'cmd': 2, 'payload': {'QID': payload['QID'], 'PAKE': enc(json.dumps(reply).encode())}})
            elif cmd in (4, 5):
                \(logins)
            elif cmd == 6:
                \(saves)
            elif cmd in (16, 17):
                \(codes)
            elif cmd == 19:
                \(ending)
        """)
    }

    /// Real framing, SRP and AES-GCM envelopes, with only synthetic accounts.
    /// The Python peer exports its fixture session key so Swift can encrypt
    /// replies without a third-party Python crypto dependency.
    @Test(arguments: [true, false])
    func authenticatedCodeUsesCmd17AndWaitsForItsReply(matchingAccount: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("code-peer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = String(decoding: try encoder.encode(folder.path), as: UTF8.self)
        let program = try helper(ending: "pass", beforeProof: "__import__('pathlib').Path(\(path), 'key').write_bytes(K)", codes: """
        from pathlib import Path
                folder = Path(\(path))
                request = folder / ('request-' + str(cmd))
                request.with_suffix('.tmp').write_text(json.dumps(msg))
                request.with_suffix('.tmp').replace(request)
                if cmd == 17: send({'cmd': 15})
                reply = folder / ('reply-' + str(cmd))
                while not reply.exists(): time.sleep(0.01)
                send(json.loads(reply.read_text()))
        """)
        defer { try? FileManager.default.removeItem(at: program.deletingLastPathComponent()) }
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        let key = SymmetricKey(data: try Data(contentsOf: folder.appendingPathComponent("key")).prefix(16))
        let peer = Task {
            for cmd in [16, 17] {
                let file = folder.appendingPathComponent("request-\(cmd)")
                try await eventually { FileManager.default.fileExists(atPath: file.path) }
                let message = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
                #expect(message["url"] == nil)
                let payloadText = try #require(message["payload"] as? String)
                let payload = try #require(JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
                #expect(payload["QID"] as? String == (cmd == 16 ? "CmdGetOneTimeCodes" : "CmdDidFillOneTimeCode"))
                let envelopeText = try #require(payload["SMSG"] as? String)
                let envelope = try #require(JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any])
                let encrypted = try #require((envelope["SDATA"] as? String).flatMap { Data(base64Encoded: $0) })
                let nonce = try AES.GCM.Nonce(data: encrypted.suffix(16))
                let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: encrypted.dropLast(32), tag: encrypted.dropLast(16).suffix(16))
                let plain = try AES.GCM.open(box, using: key)
                let body = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
                #expect(body["ACT"] as? Int == (cmd == 16 ? 5 : 2))
                #expect(body["TYPE"] as? String == "oneTimeCodes")
                #expect(body["frameURLs"] as? [String] == ["https://autofill.test/challenge"])
                #expect(body["username"] as? String == "fixture@example.test")
                if cmd == 17 { try await Task.sleep(for: .milliseconds(150)) }
                let answer: [String: Any] = ["STATUS": 0, "RequiresUserAuthenticationToFill": cmd == 16,
                    "Entries": [["source": "totp", "domain": "autofill.test", "username": cmd == 16 || matchingAccount ? "fixture@example.test" : "other@example.test", "code": cmd == 16 ? "" : "246801"]]]
                let replyNonce = try AES.GCM.Nonce(data: Data(repeating: UInt8(cmd), count: 16))
                let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: answer), using: key, nonce: replyNonce)
                let replyEnvelope: [String: Any] = ["TID": envelope["TID"]!, "SDATA": (Data(replyNonce) + sealed.ciphertext + sealed.tag).base64EncodedString()]
                let reply: [String: Any] = ["cmd": cmd, "payload": ["SMSG": replyEnvelope]]
                try JSONSerialization.data(withJSONObject: reply).write(to: folder.appendingPathComponent("reply-\(cmd)"), options: .atomic)
            }
        }
        defer { peer.cancel() }
        let hints = try await passwords.codes(page: "https://autofill.test/challenge", user: "fixture@example.test")
        #expect(hints.map(\.code) == [""])
        if matchingAccount {
            let code = try await passwords.code(page: "https://autofill.test/challenge", user: "fixture@example.test")
            #expect(code == "246801")
        } else {
            await #expect(throws: ApplePasswords.Failure.unexpected) {
                _ = try await passwords.code(page: "https://autofill.test/challenge", user: "fixture@example.test")
            }
        }
        try await peer.value
    }

    // MARK: saving

    /// A helper whose encrypted replies come from this test (`answer`, by cmd
    /// and how many of that cmd came before), with what was sent recorded.
    private final class SavePeer: @unchecked Sendable {
        let folder: URL
        let lock = NSLock()
        var bodies: [Int: [[String: Any]]] = [:]
        var server: Task<Void, Error>?

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("save-peer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        deinit {
            server?.cancel()
            try? FileManager.default.removeItem(at: folder)
        }

        /// Python, in a helper's cmd branch: hands the request over, waits.
        var relay: String {
            """
            from pathlib import Path
                    folder = Path('\(folder.path)')
                    request = folder / ('request-' + str(cmd))
                    request.with_suffix('.tmp').write_text(json.dumps(msg))
                    request.with_suffix('.tmp').replace(request)
                    reply = folder / ('reply-' + str(cmd))
                    while not reply.exists(): time.sleep(0.01)
                    body = reply.read_text()
                    reply.unlink()
                    send(json.loads(body))
            """
        }

        var keeping: String { "__import__('pathlib').Path('\(folder.path)', 'key').write_bytes(K)" }

        func count(_ cmd: Int) -> Int { lock.withLock { bodies[cmd]?.count ?? 0 } }
        func body(_ cmd: Int, _ at: Int = 0) -> [String: String] {
            lock.withLock { (bodies[cmd]?[at] ?? [:]).compactMapValues { $0 as? String } }
        }

        func serve(_ answer: @escaping @Sendable (Int, Int) -> [String: Any]) {
            server = Task { [folder] in
                while !Task.isCancelled {
                    for cmd in [4, 5, 6] {
                        let file = folder.appendingPathComponent("request-\(cmd)")
                        guard let data = try? Data(contentsOf: file) else { continue }
                        try FileManager.default.removeItem(at: file)
                        let message = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        let payloadText = try #require(message["payload"] as? String)
                        let payload = try #require(JSONSerialization.jsonObject(with: Data(payloadText.utf8)) as? [String: Any])
                        let envelopeText = try #require(payload["SMSG"] as? String)
                        let envelope = try #require(JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any])
                        let sealedIn = try #require((envelope["SDATA"] as? String).flatMap { Data(base64Encoded: $0) })
                        let key = SymmetricKey(data: try Data(contentsOf: folder.appendingPathComponent("key")).prefix(16))
                        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: sealedIn.suffix(16)),
                                                        ciphertext: sealedIn.dropLast(32), tag: sealedIn.dropLast(16).suffix(16))
                        let body = try #require(JSONSerialization.jsonObject(with: AES.GCM.open(box, using: key)) as? [String: Any])
                        let turn = self.lock.withLock {
                            let turn = self.bodies[cmd]?.count ?? 0
                            self.bodies[cmd, default: []].append(body)
                            return turn
                        }
                        let nonce = try AES.GCM.Nonce(data: Data(repeating: UInt8(cmd), count: 16))
                        let sealed = try AES.GCM.seal(JSONSerialization.data(withJSONObject: answer(cmd, turn)), using: key, nonce: nonce)
                        let back: [String: Any] = ["TID": envelope["TID"]!, "SDATA": (Data(nonce) + sealed.ciphertext + sealed.tag).base64EncodedString()]
                        try JSONSerialization.data(withJSONObject: ["cmd": cmd, "payload": ["SMSG": back]])
                            .write(to: folder.appendingPathComponent("reply-\(cmd)"), options: .atomic)
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    /// Paired with a peer: `saves` is the helper's cmd 6 branch, or the relay.
    private func savePeer(saves: String? = nil, answer: @escaping @Sendable (Int, Int) -> [String: Any]) async throws -> (SavePeer, ApplePasswords) {
        let peer = try SavePeer()
        let program = try helper(ending: "pass", beforeProof: peer.keeping, logins: peer.relay, saves: saves ?? peer.relay)
        let passwords = ApplePasswords(program: program)
        try await passwords.beginPairing()
        try await passwords.finishPairing(code: "123456")
        peer.serve(answer)
        return (peer, passwords)
    }

    @Test func aSaveSendsWhatTheExtensionSends() async throws {
        let (peer, passwords) = try await savePeer { _, _ in ["STATUS": 0] }
        try await passwords.save(host: "site.test", user: "ann", password: "fixture-secret")
        let body = peer.body(6)
        #expect(body["NURL"] == "site.test")
        #expect(body["NUSR"] == "ann")
        #expect(body["NPWD"] == "fixture-secret")
        #expect(peer.count(4) == 0)
    }

    @Test func anEntryAlreadyKeptIsSaved() async throws {
        let (peer, passwords) = try await savePeer { _, _ in ["STATUS": 7] }
        try await passwords.save(host: "site.test", user: "ann", password: "fixture-secret")
        #expect(peer.count(6) == 1)
    }

    @Test(arguments: [1, 2, 5, 6, 8])
    func aRefusalStaysARefusal(status: Int) async throws {
        let (peer, passwords) = try await savePeer { _, _ in ["STATUS": status] }
        await #expect(throws: ApplePasswords.Failure.refused(status)) {
            try await passwords.save(host: "site.test", user: "ann", password: "fixture-secret")
        }
        #expect(peer.count(4) == 0)
        #expect(await passwords.isPaired)
    }

    @Test func aLockedVaultKeepsPairingAndCanAnswerAfterUnlock() async throws {
        let (peer, passwords) = try await savePeer { _, turn in
            ["STATUS": 0, "RequiresUserAuthenticationToFill": turn == 0,
             "Entries": [["USR": "fixture", "sites": ["site.test"]]]]
        }
        let helperBefore = await passwords.processIdentifier
        for _ in 0..<2 {
            let entries = try await passwords.logins(for: "site.test")
            #expect(entries.map(\.user) == ["fixture"])
            #expect(await passwords.isPaired)
            #expect(await passwords.processIdentifier == helperBefore)
        }
        #expect(peer.count(4) == 2)
    }

    /// A pick asks Touch ID once (2026-11-08, the way the iCloud Passwords
    /// extension does in Chromium): when the helper said it asks before
    /// filling from the site, its password comes proven and Yab's own
    /// question isn't put again (Vault.proveToFill). A helper that doesn't
    /// ask, or never said, leaves Yab's question in place.
    @Test(arguments: [true, false])
    func theHelpersOwnTouchIDIsTheFillsOne(asks: Bool) async throws {
        let (peer, passwords) = try await savePeer { cmd, _ in
            var answer: [String: Any] = ["STATUS": 0,
                                         "Entries": [["USR": "ann", "PWD": cmd == 5 ? "fixture-secret" : "Not Included", "sites": ["site.test"]]]]
            if cmd == 4, asks { answer["RequiresUserAuthenticationToFill"] = true }
            return answer
        }
        let vault = AppleVault(passwords: passwords, connect: { true })
        let logins = try await vault.logins(for: "site.test")
        #expect(logins.map(\.user) == ["ann"])
        let secret = try await vault.secret(logins[0])
        #expect(secret.password == "fixture-secret")
        #expect(secret.proven == asks)
        #expect(peer.count(5) == 1)
        // No list for a site yet: nothing said, so not proven.
        #expect(await passwords.asksBeforeFilling("other.test") == false)
    }

    @Test(arguments: [1, 2, 5, 6, 8])
    func aRefusedListDoesNotTurnOffPairingAndTheNextListWorks(status: Int) async throws {
        let (peer, passwords) = try await savePeer { _, turn in
            ["STATUS": turn == 0 ? status : 0,
             "Entries": turn == 0 ? [] : [["USR": "fixture", "sites": ["site.test"]]]]
        }
        let pid = await passwords.processIdentifier
        await #expect(throws: ApplePasswords.Failure.refused(status)) {
            _ = try await passwords.logins(for: "site.test")
        }
        #expect(await passwords.isPaired)
        let entries = try await passwords.logins(for: "site.test")
        #expect(entries.map(\.user) == ["fixture"])
        #expect(await passwords.isPaired)
        #expect(await passwords.processIdentifier == pid)
        #expect(peer.count(4) == 2)
    }

    /// The reply tagged cmd 4, with nothing in it: only the list can tell.
    @Test(arguments: [true, false])
    func aReplyWithNoAnswerAsksTheList(listed: Bool) async throws {
        let (peer, passwords) = try await savePeer(saves: "send({'cmd': 4, 'payload': {}})") { _, _ in
            ["STATUS": listed ? 0 : 3, "Entries": listed ? [["USR": "ann", "sites": ["site.test"]]] : []]
        }
        if listed {
            try await passwords.save(host: "site.test", user: "ann", password: "fixture-secret")
        } else {
            await #expect(throws: ApplePasswordsSRP.Failure.unexpected) {
                try await passwords.save(host: "site.test", user: "ann", password: "fixture-secret")
            }
        }
        #expect(peer.count(4) == 1)
    }

    /// Yab started again: still connected, no longer paired. Save pairs first.
    @Test(arguments: [true, false])
    func saveAfterARestartPairsFirst(yes: Bool) async throws {
        let peer = try SavePeer()
        let program = try helper(ending: "pass", beforeProof: peer.keeping, logins: peer.relay, saves: peer.relay)
        let passwords = ApplePasswords(program: program)
        peer.serve { _, _ in ["STATUS": 0] }
        let vault = AppleVault(passwords: passwords, connect: {
            guard yes else { return false }
            try? await passwords.beginPairing()
            try? await passwords.finishPairing(code: "123456")
            return await passwords.isPaired
        })
        if yes {
            try await vault.save(host: "site.test", user: "ann", password: "fixture-secret")
            #expect(peer.count(6) == 1)
        } else {
            await #expect(throws: ApplePasswords.Failure.notPaired) {
                try await vault.save(host: "site.test", user: "ann", password: "fixture-secret")
            }
            #expect(peer.count(6) == 0)
        }
    }

    /// Apple says the session is over (status 9) as the save arrives.
    @Test func anExpiredSessionPairsAndSavesAgain() async throws {
        let (peer, passwords) = try await savePeer { _, turn in ["STATUS": turn == 0 ? 9 : 0] }
        let vault = AppleVault(passwords: passwords, connect: {
            try? await passwords.beginPairing()
            try? await passwords.finishPairing(code: "123456")
            return await passwords.isPaired
        })
        try await vault.save(host: "site.test", user: "ann", password: "fixture-secret")
        #expect(peer.count(6) == 2)
        #expect(await passwords.isPaired)
    }

    @Test func verificationCodesAreTheSitesTimeCodesOnly() {
        let answer: [String: Any] = ["STATUS": 0, "Entries": [
            ["code": "482 913", "username": "erik@example.com", "domain": "accounts.linear.app", "source": "totp"],
            ["code": "771204", "username": "erik@example.com", "domain": "linear.app", "source": "sms"],
            ["code": "555111", "username": "erik@example.com", "domain": "other.com", "source": "totp"],
        ]]
        let codes = ApplePasswords.codes(in: answer, host: "linear.app", locked: false)
        #expect(codes == [ApplePasswords.Code(code: "482913", user: "erik@example.com", site: "linear.app")])
        // Touch ID first: whose it is, never the digits.
        #expect(ApplePasswords.codes(in: answer, host: "linear.app", locked: true).map(\.code) == [""])
    }

    @Test func aCodeKeptForARelatedSiteIsOfferedOnlyWhenNamed() {
        // X's code, kept in Passwords under twitter.com, on x.com.
        let answer: [String: Any] = ["Entries": [
            ["code": "246801", "username": "sam", "domain": "twitter.com", "source": "totp"],
            ["code": "555111", "username": "sam", "domain": "other.com", "source": "totp"],
        ]]
        #expect(ApplePasswords.codes(in: answer, host: "x.com", locked: false).isEmpty)
        #expect(ApplePasswords.codes(in: answer, host: "x.com", locked: false, also: ["twitter.com"])
                == [ApplePasswords.Code(code: "246801", user: "sam", site: "x.com")])
    }

    @Test func aCodeIsAskedForThePageWithoutItsQuery() {
        #expect(Browser.codePage(URL(string: "https://linear.app/login/2fa?token=abc#x")) == "https://linear.app/login/2fa")
        #expect(Browser.codePage(URL(string: "http://linear.app/login")) == nil)
    }
}


extension ApplePasswordsTests {
    @MainActor @Test func submittedPasswordIsComparedThroughTheAppleHelper() async throws {
        let user = UUID().uuidString
        let (peer, passwords) = try await savePeer { cmd, _ in
            ["STATUS": 0, "Entries": [["USR": user, "PWD": cmd == 5 ? "fixture-secret" : "Not Included",
                                      "sites": ["www.github.com"]]]]
        }
        defer { peer.server?.cancel() }
        let adapter = AppleVault(passwords: passwords, connect: { false })
        let login = Login(host: "github.com", user: user, password: "fixture-secret")
        #expect(await PasswordSaveDecision.check(login, known: [], apple: adapter) == .none)
        #expect(peer.count(4) == 1)
        #expect(peer.count(5) == 1)
        #expect(peer.body(5)["USR"] == user)
        var changed = login
        changed.password = "changed-secret"
        #expect(await PasswordSaveDecision.check(changed, known: [], apple: adapter) == .update)
        // Exact filled/saved credentials can suppress a duplicate; a username
        // alone must never suppress an Update.
        #expect(peer.count(5) == 2)
    }
}
