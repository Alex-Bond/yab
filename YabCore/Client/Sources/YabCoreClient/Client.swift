import Foundation
import CryptoKit

/// One client owns one helper. Consume events once, in order, and reduce
/// page.state patches into the application's own page state.
public actor YabCoreClient {
    public nonisolated let events: AsyncStream<YabCoreEvent>
    private let eventSink: AsyncStream<YabCoreEvent>.Continuation
    private let socket: Socket
    private let diagnosticObservation: Bool
    private let diagnosticImagePinned: Bool
    private var originalDiagnosticHello: JSONValue?
    private var reader: Task<Void, Never>?
    // Separate original-native lane. Ordinary request cancellation retains its
    // existing behavior; original-native cancellation only detaches its waiter.
    private var originalReplyLedger = NativeOriginalReplyLedger()
    private var originalWaiters: [String: CheckedContinuation<OriginalNativeDelivery, Error>] = [:]
    private var originalTimers: [String: Task<Void, Never>] = [:]
    private var originalContexts: [String: OriginalNativeContext] = [:]
    private var originalSequence: UInt64 = 0
    private struct OriginalNativeContext: Sendable {
        let counterpart: NativeOriginalGroupCounterpart
    }
    private struct OriginalJournalStep: Sendable {
        let journal: NativeSwitchJournal, cursor: NativeSwitchJournal.Cursor, intent: NativeSwitchJournal.Intent
        let action: NativeSwitchJournal.Action
    }
    private struct OriginalNativeDelivery: Sendable {
        let result: JSONValue
        let context: OriginalNativeContext
        let write: SocketWriteTicket.Snapshot
        let envelopeSHA256: String
        let journalCursor: NativeSwitchJournal.Cursor?
    }
    private var originalPendingJournalCursors: [String: NativeSwitchJournal.Cursor] = [:]
    // Non-evicting resource credit: even canceled/unknown/in-flight native
    // groups retain their one slot. There is no automatic retire/retry path.
    private var originalSourceReservations: [UUID: OriginalSourceReservation] = [:]
    private struct OriginalSourceReservation {
        let journal: NativeSwitchJournal, intent: NativeSwitchJournal.Intent, context: OriginalNativeContext
    }
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private var connected = true
    var originalPeerLost = false
    // Only the original socket/witness sealed-image factory may create this.
    var originalGroupCounterpart: NativeOriginalGroupCounterpart? = nil
    var originalJournalBindings: [UUID: NativeOriginalJournalBinding] = [:]
    public internal(set) var originalJournalLoss: [UUID: NativeOriginalJournalLoss] = [:]
    // Native unknown never becomes an implicit retry on this exact endpoint.
    var nativeTextUncertain = NativeTextInputUncertainty()
    var nativeTextInFlight = Set<NativeTextInputEndpoint>()
    private var advertisedNativeHooks: [String: JSONValue] = [:]
    public private(set) var nativeHooks: [String: JSONValue] = [:]
    public private(set) var nativeGroupSource: [String: JSONValue] = [:]
    private func retainNativeHooks(_ hello: JSONValue) {
        advertisedNativeHooks = hello["nativeHooks"].object ?? [:]
        nativeHooks = advertisedNativeHooks
        // Advertising one-sided primitives cannot enable bidirectional use.
        nativeHooks["nativeGroupApprovals"] = .bool(false)
        nativeHooks["nativeGroupApprovalVersion"] = .number(0)
        nativeHooks["nativeGroupOwnerVersion"] = .number(0)
        nativeHooks["nativeGroupSources"] = .bool(false)
        nativeHooks["nativeGroupSourcesVersion"] = .number(0)
        nativeHooks["nativeGroupSnapshots"] = .bool(false)
        nativeHooks["nativeGroupSnapshotVersion"] = .number(0)
        nativeGroupSource = hello["nativeGroupSource"].object ?? [:]
    }

    private func retainDiagnosticHello(_ hello: JSONValue) {
        if diagnosticObservation { originalDiagnosticHello = hello }
    }
    /// Diagnostic JSON only. Never supplies a counterpart/native phase or
    /// reconnects. After loss it reports local unknown without a new peer reply.
    public func originalCallerDiagnostic() async throws -> JSONValue {
        guard diagnosticObservation else { throw YabCoreError.protocolViolation("Not the original diagnostic launch") }
        var result: [String: JSONValue] = ["classification": .string("ORIGINAL_DIAGNOSTIC_NOT_AUTHORITY"),
            "helloSnapshot": originalDiagnosticHello ?? .null,
            "connected": .bool(connected), "originalPeerLost": .bool(originalPeerLost),
            "counterpartPresent": .bool(originalGroupCounterpart != nil),
            "diagnosticImagePinned": .bool(diagnosticImagePinned),
            "nativeHooks": .object(nativeHooks), "nativeReply": .null]
        switch await originalPeerSource() {
        case .observed(let source):
            result["peerStatus"] = .string("observed")
            result["connection"] = .string(source.connection)
            result["helperEvidence"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(source.evidence))
        case .unknown: result["peerStatus"] = .string("unknown")
        case .unavailable: result["peerStatus"] = .string("unavailable")
        }
        if connected && !originalPeerLost {
            result["nativeReply"] = try await request("originalCaller.diagnostic")
        }
        result["connected"] = .bool(connected); result["originalPeerLost"] = .bool(originalPeerLost)
        return .object(result)
    }
    private func bindOriginalCaller(_ hello: JSONValue) async {
        let counterpart = await socket.acceptedOriginalCounterpart(hello)
        guard connected, !originalPeerLost, let counterpart else { return }
        originalGroupCounterpart = counterpart
        // Only after actual private factory success; advertised JSON alone
        // cannot restore availability or create the counterpart.
        for key in ["nativeGroupApprovals", "nativeGroupApprovalVersion", "nativeGroupOwnerVersion", "nativeGroupSnapshots", "nativeGroupSnapshotVersion", "nativeGroupSources", "nativeGroupSourcesVersion"] {
            nativeHooks[key] = advertisedNativeHooks[key]
        }
    }
    var originalEndpointConnected: Bool { connected }
    func originalSocketObservation() async -> NativeOriginalPeerObservation { await socket.originalPeerObservation() }
    private init(socket: Socket, diagnosticObservation: Bool, diagnosticImagePinned: Bool) {
        self.socket = socket
        self.diagnosticObservation = diagnosticObservation
        self.diagnosticImagePinned = diagnosticImagePinned
        var sink: AsyncStream<YabCoreEvent>.Continuation!
        // A dropped event is a disconnect, and a disconnect ends the helper and
        // every Chromium page. 512 was overrun while 120 tabs loaded at once
        // and the main thread was busy laying them out: give a burst room.
        events = AsyncStream(bufferingPolicy: .bufferingOldest(32_768)) { sink = $0 }
        eventSink = sink
    }
    public static func connect(path: String, originalLaunch: NativePeerIdentity.LaunchWitness? = nil) async throws -> YabCoreClient {
        let socket = try Socket(path: path, originalLaunch: originalLaunch)
        let client = YabCoreClient(socket: socket, diagnosticObservation: originalLaunch?.isDiagnosticObservation == true, diagnosticImagePinned: originalLaunch?.isDiagnosticImagePinned == true)
        await client.start()
        do {
            let hello = try await client.request("hello", params: socket.originalHandshakeParameters)
            guard hello["version"] == .number(1) else { throw YabCoreError.protocolViolation("Unsupported negotiated version") }
            await client.retainDiagnosticHello(hello)
            await client.retainNativeHooks(hello)
            await client.bindOriginalCaller(hello)
            return client
        }
        catch { await client.disconnect(); throw error }
    }
    private func start() {
        let messages = socket.messages
        reader = Task { [weak self] in
            do { for try await data in messages { await self?.receive(data) } }
            catch { await self?.fail(error); return }
            await self?.fail(YabCoreError.disconnected, originalLoss: .helperEOF)
        }
        socket.start()
    }
    private func receive(_ data: Data) {
        guard connected else { return }
        do {
            let message = try JSONDecoder().decode(Envelope.self, from: data)
            guard message.v == 1 else { throw YabCoreError.protocolViolation("Unsupported protocol version") }
            if let id = message.id {
                if originalReplyLedger.contains(id) {
                    receiveOriginalNative(message, data: data, id: id); return
                }
                // A cancelled request can still finish in the helper.
                guard let continuation = pending.removeValue(forKey: id) else { return }
                timers.removeValue(forKey: id)?.cancel()
                if let error = message.error {
                    continuation.resume(throwing: YabCoreError.remote(error["message"].string ?? "Remote operation failed"))
                } else { continuation.resume(returning: message.result ?? .null) }
            } else if let name = message.event {
                let event = YabCoreEvent(name: name, params: message.params ?? [:])
                observeOriginalSourceLoss(event) // Negative only, never source authority from event labels.
                if case .dropped = eventSink.yield(event) {
                    throw YabCoreError.protocolViolation("Event consumer fell behind")
                }
            } else { throw YabCoreError.protocolViolation("Message has neither id nor event") }
        } catch { fail(error) }
    }
    private func fail(_ error: Error, originalLoss: NativeSwitchJournal.Loss = .nativeOutcomeUnknown) {
        guard connected else { return }
        // Always said: losing the helper loses every Chromium page.
        FileHandle.standardError.write(Data("YabCore client disconnected: \(String(describing: error))\n".utf8))
        loseOriginalPeer(originalLoss)
        connected = false
        let continuations = pending.values
        pending.removeAll()
        timers.values.forEach { $0.cancel() }; timers.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
        eventSink.finish(); socket.close(); reader?.cancel(); reader = nil
    }
    public func disconnect() { fail(YabCoreError.disconnected) }
    private func cancel(_ id: String, error: Error) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }
    public func request(_ method: String, params: [String: JSONValue] = [:], timeout: TimeInterval = 20) async throws -> JSONValue {
        guard connected else { throw YabCoreError.disconnected }
        if method.hasPrefix("switch.group.") {
            return try await requestOriginalNative(method, params: params, timeout: timeout)
        }
        guard pending.count < 128, timeout.isFinite, timeout > 0, timeout <= 300 else {
            throw YabCoreError.protocolViolation("Request limit or invalid timeout")
        }
        let id = UUID().uuidString
        let data = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        guard data.count <= Socket.limit else { throw YabCoreError.protocolViolation("Request too large") }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) } catch { return }
                    await self?.cancel(id, error: YabCoreError.timeout)
                }
                socket.send(data)
            }
        }, onCancel: { Task { await self.cancel(id, error: CancellationError()) } })
    }
    private func originalContextCurrent(_ context: OriginalNativeContext) -> Bool {
        connected && !originalPeerLost && originalGroupCounterpart === context.counterpart &&
        nativeGroupSource["helperOwner"] == .string(context.counterpart.factoryOwner) &&
        nativeGroupSource["connection"] == .string(context.counterpart.groupConnection)
    }
    private func requestOriginalNative(_ method: String, params: [String: JSONValue], timeout: TimeInterval) async throws -> JSONValue {
        (try await requestOriginalNativeDelivery(method, params: params, timeout: timeout)).result
    }
    private func requestOriginalNativeDelivery(_ method: String, params: [String: JSONValue], timeout: TimeInterval,
                                              journalStep: OriginalJournalStep? = nil) async throws -> OriginalNativeDelivery {
        guard !originalReplyLedger.poisoned, originalReplyLedger.rows.count < 32,
              timeout.isFinite, timeout > 0, timeout <= 300, method.utf8.count <= 128,
              let original = originalGroupCounterpart else {
            throw YabCoreError.protocolViolation("Original native transport unavailable")
        }
        guard await originalGroupReady() else { throw YabCoreError.protocolViolation("Original bidirectional group endpoint is unavailable") }
        let context = OriginalNativeContext(counterpart: original)
        guard originalContextCurrent(context), !originalReplyLedger.poisoned,
              originalReplyLedger.rows.count < 32, originalSequence < UInt64.max else { throw YabCoreError.disconnected }
        try Task.checkCancellation()
        originalSequence += 1
        let id = "native:" + original.clientNonce + ":" + String(originalSequence)
        var parameters = params
        if journalStep != nil { parameters["command"] = .string(id) } // SAME real opaque wire/native/WAL command.
        let data = try JSONEncoder().encode(Request(id: id, method: method, params: parameters))
        guard data.count <= Socket.limit else { throw YabCoreError.protocolViolation("Request too large") }
        let ticket = socket.prepareTracked(data, request: id) { [weak self] in Task { await self?.originalWriteChanged(id) } }
        guard originalReplyLedger.reserve(id, ticket: ticket, connection: original.clientNonce) else {
            throw YabCoreError.protocolViolation("Original request registry unavailable")
        }
        originalContexts[id] = context // Registry exists BEFORE journal await and BEFORE any byte enqueue.
        return try await withTaskCancellationHandler(operation: {
            if let step = journalStep {
                guard let binding = originalJournalBindings[step.intent.id], binding.journal === step.journal,
                      binding.intent == step.intent, step.cursor.id == step.intent.id,
                      step.intent.peer == original.helper, step.intent.connection == original.clientNonce else {
                    detachOriginalWaiter(id, error: YabCoreError.disconnected); throw YabCoreError.disconnected
                }
                let exactWrite = ticket.snapshot()
                guard exactWrite.phase == .created, exactWrite.request == id, exactWrite.connection == original.clientNonce else {
                    detachOriginalWaiter(id, error: YabCoreError.disconnected); throw YabCoreError.disconnected
                }
                let stored = await step.journal.writeAhead(step.action, command: id, expected: step.cursor,
                                                          frameSHA256: exactWrite.frameSHA256, frameBytes: exactWrite.total)
                guard case .stored(let snapshot) = stored, snapshot.intent == step.intent,
                      snapshot.pending.last?.command == id, snapshot.pending.last?.action == step.action,
                      snapshot.pending.last?.frameSHA256 == exactWrite.frameSHA256, snapshot.pending.last?.frameBytes == exactWrite.total,
                      originalContextCurrent(context), !originalReplyLedger.poisoned, !Task.isCancelled else {
                    // No socket enqueue. The retained original row and journal
                    // are poisoned, never canceled or replayed as a new request.
                    detachOriginalWaiter(id, error: YabCoreError.disconnected); throw YabCoreError.disconnected
                }
                originalPendingJournalCursors[id] = snapshot.cursor
                // fsync may yield for longer than the original process lives.
                // Reobserve the REAL peer after it, not only cached connected.
                guard await originalGroupReady(), originalContextCurrent(context), !Task.isCancelled else {
                    detachOriginalWaiter(id, error: YabCoreError.disconnected); throw YabCoreError.disconnected
                }
            }
            guard originalContextCurrent(context), !originalReplyLedger.poisoned, !Task.isCancelled else {
                detachOriginalWaiter(id, error: YabCoreError.disconnected); throw YabCoreError.disconnected
            }
            return try await withCheckedThrowingContinuation { continuation in
                originalWaiters[id] = continuation
                originalTimers[id] = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1e9)) } catch { return }
                    await self?.detachOriginalWaiter(id, error: YabCoreError.timeout)
                }
                socket.enqueueTracked(data, ticket: ticket)
            }
        }, onCancel: { Task { await self.detachOriginalWaiter(id, error: CancellationError()) } })
    }
    private func originalWriteChanged(_ id: String) {
        guard let row = originalReplyLedger.rows[id] else { return }
        switch row.ticket.snapshot().phase {
        case .notEnqueued, .unknown:
            detachOriginalWaiter(id, error: YabCoreError.transport("Original write unavailable/unknown"))
        default: break // No global/older counter can dispatch this request.
        }
    }
    private func detachOriginalWaiter(_ id: String, error: Error) {
        guard originalReplyLedger.contains(id) else { return }
        originalReplyLedger.abandon(id)
        originalTimers.removeValue(forKey: id)?.cancel()
        let ownWaiter = originalWaiters.removeValue(forKey: id)
        // Sticky source/journal uncertainty BEFORE ANY original waiter resumes.
        // Ordinary routes remain connected; no native cancel/retire is emitted.
        loseOriginalPeer(.nativeOutcomeUnknown)
        ownWaiter?.resume(throwing: error)
        // The original ticket/context/row STAY. A native request is not canceled
        // because its UI task/timer stopped waiting. No second native send.
    }
    private func receiveOriginalNative(_ message: Envelope, data: Data, id: String) {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fact = originalReplyLedger.observedEnvelope(id, sha256: digest)
        guard fact == .envelope, let context = originalContexts[id], originalContextCurrent(context) else {
            if fact != .abandonedEnvelope { detachOriginalWaiter(id, error: YabCoreError.disconnected) }
            return // Late/duplicate records only digest, never a second reply.
        }
        if let error = message.error {
            detachOriginalWaiter(id, error: YabCoreError.remote(error["message"].string ?? "Native transport error")); return
        }
        guard let result = message.result else {
            detachOriginalWaiter(id, error: YabCoreError.protocolViolation("Missing original transport result")); return
        }
        guard let write = originalReplyLedger.rows[id]?.ticket.snapshot(),
              write.request == id, write.connection == context.counterpart.clientNonce,
              write.phase == .allWritten, write.written == write.total,
              originalReplyLedger.deliveredEnvelope(id) else {
            detachOriginalWaiter(id, error: YabCoreError.disconnected); return
        }
        originalContexts.removeValue(forKey: id)
        originalTimers.removeValue(forKey: id)?.cancel()
        let delivery = OriginalNativeDelivery(result: result, context: context, write: write, envelopeSHA256: digest,
                                              journalCursor: originalPendingJournalCursors.removeValue(forKey: id))
        originalWaiters.removeValue(forKey: id)?.resume(returning: delivery)
        // This is a private original TRANSPORT delivery. Only the separately
        // qualified sources path below may create a partial metadata receipt.
        // NativeVerifiedPhaseReceipt/full engine-switch authority stay absent.
    }
    private func observeOriginalSourceLoss(_ event: YabCoreEvent) {
        guard event.name == "page.crash" || event.name == "tab.closed", let tab = event.params["tab"]?.string,
              originalSourceReservations.values.contains(where: {
                  originalGroupCounterpart === $0.context.counterpart && $0.intent.members.contains(where: { $0.tab == tab })
              }) else { return }
        // An actual incoming crash/close is sufficient for NEGATIVE uncertainty.
        // Its tab label is never used to establish native process ownership.
        loseOriginalPeer(event.name == "page.crash" ? .sourceProcessLost : .nativeOutcomeUnknown)
    }
    private func originalSourcesQualified(_ context: OriginalNativeContext) async -> Bool {
        guard NativeOriginalSourcesPolicy.version == 1,
              NativeOriginalSourcesPolicy.helperCodeDirectories.contains(context.counterpart.helper.codeUnique),
              NativeOriginalSourcesPolicy.sdkFrameworkSHA256.count == 64,
              NativeOriginalSourcesPolicy.nativeSourceManifestSHA256.count == 64,
              NativeGroupApprovalCommand.available(nativeHooks),
              nativeHooks["nativeGroupSources"] == .bool(true), nativeHooks["nativeGroupSourcesVersion"] == .number(1),
              originalContextCurrent(context), !originalReplyLedger.poisoned else { return false }
        guard await originalGroupReady() else { return false }
        return originalContextCurrent(context) && !originalReplyLedger.poisoned
    }
    /// Partial, unused production primitive. Default0 returns BEFORE any WAL
    /// write/group dispatch. No public DTO can provide a receipt constructor.
    func recordOriginalGroupSources(journal: NativeSwitchJournal, cursor: NativeSwitchJournal.Cursor,
                                    coordinator: String) async -> NativeOriginalSourcesRecording {
        guard let original = originalGroupCounterpart else { return .unavailable }
        let context = OriginalNativeContext(counterpart: original)
        guard await originalSourcesQualified(context), originalSourceReservations.count < 2,
              originalSourceReservations[cursor.id] == nil else { return .unavailable }
        guard case .stored(let loaded) = await journal.load(cursor.id), loaded.cursor == cursor, loaded.phase == .intent,
              loaded.intent.peer == original.helper, loaded.intent.connection == original.clientNonce,
              loaded.intent.members.contains(where: { $0.tab == coordinator }),
              originalContextCurrent(context), !Task.isCancelled else { return .unknown }
        let intent = loaded.intent
        guard await trackOriginalJournal(journal, cursor: cursor) == .tracked,
              await originalSourcesQualified(context), originalSourceReservations.count < 2,
              originalSourceReservations[cursor.id] == nil, !Task.isCancelled else { return .unknown }
        originalSourceReservations[cursor.id] = OriginalSourceReservation(journal: journal, intent: intent, context: context)
        // Credit retained on every following exit, including successful source
        // observation. Only a future exact native retirement may release it.
        do {
            let members = intent.members.map { JSONValue.object(["tab": .string($0.tab), "profile": .string($0.profile), "document": .string($0.document)]) }
            let transaction = intent.id.uuidString.lowercased()
            let reserve = try await requestOriginalNativeDelivery("switch.group.native",
                params: ["action": .string("reserve"), "transaction": .string(transaction), "coordinator": .string(coordinator), "members": .array(members)],
                timeout: 60, journalStep: OriginalJournalStep(journal: journal, cursor: cursor, intent: intent, action: .reserve))
            let typedMembers = intent.members.compactMap { NativeGroupApprovalMember(tab: $0.tab, profile: $0.profile, document: $0.document) }
            guard let reserveCursor = reserve.journalCursor, await originalSourcesQualified(context),
                  reserve.context.counterpart === original, !Task.isCancelled, typedMembers.count == intent.members.count,
                  let command = NativeGroupApprovalCommand.reserve(transaction: transaction, members: typedMembers, coordinator: coordinator, id: reserve.write.request),
                  case .observed(let observation) = command.outcome(reserve.result),
                  observation.helperOwner == original.factoryOwner, observation.currentOriginalsVerified, observation.operationCurrent,
                  observation.native["phase"] == .string("reserved"), observation.native["processOwned"] == .bool(true),
                  observation.native["irreversible"] == .bool(false), observation.native["outcome"] == .string("pending"),
                  Self.originalMemberMapping(reserve.result, intent: intent) else { throw YabCoreError.disconnected }
            let delivery = try await requestOriginalNativeDelivery("switch.group.sources",
                params: ["action": .string("sources"), "transaction": .string(transaction), "members": .array(members),
                         "group": .string(observation.group), "recoveryToken": .string(observation.recoveryToken)],
                timeout: 60, journalStep: OriginalJournalStep(journal: journal, cursor: reserveCursor, intent: intent, action: .sources))
            guard let receipt = await originalSourcesReceipt(delivery, intent: intent, reservation: observation), !Task.isCancelled else {
                throw YabCoreError.disconnected
            }
            let stored = await journal.observedOriginalSources(receipt, expected: receipt.cursor)
            guard case .stored(let saved) = stored, saved.intent == intent, saved.phase == .sourcesObserved,
                  saved.sources == receipt.observation, await originalSourcesQualified(context), !Task.isCancelled else {
                throw YabCoreError.disconnected
            }
            return .observed(saved) // Metadata ONLY, never EngineSwitch authority/settings/install.
        } catch {
            loseOriginalPeer(.nativeOutcomeUnknown) // Poison native ledger BEFORE any returning caller.
            _ = await journal.sourceLostLatest(.nativeOutcomeUnknown, original: intent)
            return .unknown // No native cancel/retry/retire, including while a native callback remains in flight.
        }
    }
    // The sole partial native receipt constructor. It consumes the PRIVATE
    // receive-lane delivery, NOT public observation/JSON or a decoded journal.
    private func originalSourcesReceipt(_ delivery: OriginalNativeDelivery, intent: NativeSwitchJournal.Intent,
                                        reservation: NativeGroupApprovalObservation) async -> NativeOriginalSourcesReceipt? {
        let context = delivery.context, row = delivery.result
        guard await originalSourcesQualified(context), !Task.isCancelled,
              let cursor = delivery.journalCursor, cursor.id == intent.id,
              let binding = originalJournalBindings[intent.id], binding.intent == intent,
              intent.peer == context.counterpart.helper, intent.connection == context.counterpart.clientNonce,
              delivery.write.phase == .allWritten, delivery.write.written == delivery.write.total,
              delivery.write.connection == context.counterpart.clientNonce,
              row["version"] == .number(1), row["command"] == .string(delivery.write.request), row["action"] == .string("sources"),
              row["transaction"] == .string(intent.id.uuidString.lowercased()),
              row["helperOwner"] == .string(context.counterpart.factoryOwner), row["helperOwner"] == .string(reservation.helperOwner),
              row["nativeTransaction"] == .string(reservation.nativeTransaction),
              row["nativeAcknowledged"] == .bool(true), row["resultSource"] == .string("native-original-sources"),
              row["status"] == .string("observed"), row["currentOriginalsVerified"] == .bool(true), row["operationCurrent"] == .bool(true),
              row["commitAvailable"] == .bool(false), row["nativeAtomicSwitchCommit"] == .bool(false),
              Self.originalMemberMapping(row, intent: intent) else { return nil }
        let native = row["nativeReceipt"]
        guard native["version"] == .number(1), native["command"] == .string(delivery.write.request), native["action"] == .string("sources"),
              native["owner"] == .string(reservation.helperOwner), native["transaction"] == .string(reservation.nativeTransaction),
              native["group"] == .string(reservation.group), native["recoveryToken"] == .string(reservation.recoveryToken),
              native["phase"] == .string("reserved"), native["processOwned"] == .bool(true), native["clientAttached"] == .bool(true),
              native["irreversible"] == .bool(false), native["complete"] == .bool(false), native["outcome"] == .string("pending"),
              native["exclusiveNativeApprovals"] == .bool(true),
              Self.nativeOriginalSourceMembers(native, intent: intent),
              let metadata = NativeOriginalSourceMetadata.decodeMetadata(native, members: intent.members),
              metadata.processes.allSatisfy({ UUID(uuidString: $0.boot) == UUID(uuidString: intent.peer.bootSession) }),
              originalContextCurrent(context), !originalReplyLedger.poisoned else { return nil }
        // Recheck after bounded tree decoding, immediately before construction.
        guard await originalSourcesQualified(context), !Task.isCancelled else { return nil }
        return NativeOriginalSourcesReceipt(intent: intent, cursor: cursor, command: delivery.write.request,
            envelopeSHA256: delivery.envelopeSHA256, write: delivery.write, group: reservation.group, metadata: metadata)
    }
    private static func nativeOriginalSourceMembers(_ native: JSONValue, intent: NativeSwitchJournal.Intent) -> Bool {
        guard case .array(let values) = native["members"], values.count == intent.members.count else { return false }
        var seen = Set<Int32>()
        for value in values {
            guard let member = intent.members.first(where: { value["browserId"] == .number(Double($0.browser)) }),
                  seen.insert(member.browser).inserted, value["document"] == .string(member.document),
                  value["originalDestroyed"] == .bool(false), value["nativeDestroyed"] == .bool(false) else { return false }
        }
        return true
    }
    private static func originalMemberMapping(_ row: JSONValue, intent: NativeSwitchJournal.Intent) -> Bool {
        guard case .array(let values) = row["members"], values.count == intent.members.count else { return false }
        var seen = Set<String>()
        for value in values {
            guard let tab = value["tab"].string, seen.insert(tab).inserted,
                  let member = intent.members.first(where: { $0.tab == tab }),
                  value["profile"] == .string(member.profile), value["document"] == .string(member.document),
                  value["browserId"] == .number(Double(member.browser)) else { return false }
        }
        return true
    }
    func loseOriginalNativeReplies() {
        originalReplyLedger.sourceLost()
        originalTimers.values.forEach { $0.cancel() }; originalTimers.removeAll()
        let waiters = originalWaiters.values; originalWaiters.removeAll()
        waiters.forEach { $0.resume(throwing: YabCoreError.disconnected) }
        // Retain rows/contexts/tickets. No replacement, reconnect or new replies.
    }
    public func openProfile(_ profile: String, privateMode: Bool = false) async throws {
        _ = try await request("profile.open", params: ["profile": .string(profile), "private": .bool(privateMode)])
    }
    public func createTab(profile: String, url: String = "about:blank") async throws -> String {
        let value = try await request("tab.create", params: ["profile": .string(profile), "url": .string(url)])
        guard let tab = value["tab"].string else { throw YabCoreError.protocolViolation("Missing tab identifier") }
        return tab
    }
    public func navigate(tab: String, url: String) async throws {
        try await navigate(tab: tab, parameters: ["url": .string(url)])
    }
    /// Navigation parameters validated by the page, including its filtered referrer.
    public func navigate(tab: String, parameters: [String: JSONValue]) async throws {
        var params = parameters
        params["tab"] = .string(tab)
        _ = try await request("tab.navigate", params: params)
    }
    public func closeTab(_ tab: String) async throws { _ = try await request("tab.close", params: ["tab": .string(tab)]) }
    public func resize(tab: String, width: Double, height: Double, scale: Double) async throws -> JSONValue {
        try await request("tab.resize", params: ["tab": .string(tab), "width": .number(width), "height": .number(height), "scale": .number(scale)])
    }
    public func evaluate(tab: String, world: String, function: String, arguments: JSONValue = .null, userGesture: Bool = false) async throws -> JSONValue {
        try await request("script.evaluate", params: ["tab": .string(tab), "world": .string(world), "function": .string(function), "arguments": arguments, "userGesture": .bool(userGesture)])
    }
    public func bind(tab: String, world: String, name: String) async throws {
        _ = try await request("script.bind", params: ["tab": .string(tab), "world": .string(world), "name": .string(name)])
    }
    deinit { socket.close(); reader?.cancel(); eventSink.finish() }
}

/// A partial native-source metadata token, NOT NativeVerifiedPhaseReceipt.
/// Cannot be decoded or made by @testable adapters/public observation parsers.
final class NativeOriginalSourcesReceipt: Sendable {
    let intent: NativeSwitchJournal.Intent
    let cursor: NativeSwitchJournal.Cursor
    let command: String
    let observation: NativeSwitchJournal.SourcesObservation
    fileprivate init(intent: NativeSwitchJournal.Intent, cursor: NativeSwitchJournal.Cursor, command: String,
                     envelopeSHA256: String, write: SocketWriteTicket.Snapshot, group: String, metadata: NativeOriginalSourceMetadata) {
        self.intent = intent; self.cursor = cursor; self.command = command
        observation = NativeSwitchJournal.SourcesObservation(envelopeSHA256: envelopeSHA256,
            requestFrameSHA256: write.frameSHA256,
            groupSHA256: NativeOriginalSourceMetadata.hash(Data(group.utf8)),
            sourceReceiptSHA256: NativeOriginalSourceMetadata.hash(Data(metadata.sourceReceipt.utf8)),
            frameTreeSHA256: metadata.frameTreeSHA256, requestFrameBytes: write.total, treeSequence: metadata.treeSequence,
            phaseSequence: metadata.phaseSequence, operationSequence: metadata.operationSequence,
            processes: metadata.processes.map { .init(launchIncarnation: $0.launchIncarnation, osPID: $0.osPID, pidVersion: $0.pidVersion,
                birthSec: $0.birthSec, birthUsec: $0.birthUsec, boot: $0.boot, executable: $0.executable,
                argvDigest: $0.argvDigest, codeUnique: $0.codeUnique, signingID: $0.signingID, auditDigest: $0.auditDigest) })
    }
}
enum NativeOriginalSourcesRecording: Sendable { case unavailable, unknown, observed(NativeSwitchJournal.Snapshot) }
