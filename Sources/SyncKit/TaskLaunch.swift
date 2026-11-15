import Foundation

/// A local reservation for an iPhone request, not permission to run an agent.
/// The first foundation has no execution/capability/Phone activation path.
public enum TaskLaunch {
    public enum Failure: Error, Equatable { case context, stale, corrupt }
    public enum Reservation: Equatable { case reserved(Mapping), consumed }

    /// IDs and the digest only. The local receipt does not copy page contents
    /// or the phone's words into a second persistence channel.
    public struct Mapping: Codable, Equatable, Sendable {
        public let version: Int
        public let request: String
        public let digest: String
        public let account: String
        public let phone: String
        public let mac: String
        public let space: String
        public let session: String
        public let cli: String
        public let policy: String
        public let attempted: Bool

        init(request: TaskRecords.Request, session: String, cli: String) throws {
            version = 1; self.request = request.id; digest = try request.digest()
            account = request.account; phone = request.phone; mac = request.mac
            space = request.space; self.session = session; self.cli = cli
            policy = "read-only/v1"; attempted = true
            try validate()
        }

        public func validate() throws {
            guard version == 1, attempted, policy == "read-only/v1",
                  UUID(uuidString: request)?.uuidString.lowercased() == request,
                  UUID(uuidString: session)?.uuidString.lowercased() == session,
                  digest.utf8.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  [account, phone, mac, space].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200
                      && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
                  phone != mac, ChatAgent(rawValue: cli) != nil else { throw Failure.corrupt }
        }

        func matches(_ original: TaskRecords.Request) throws -> Bool {
            try validate()
            let originalDigest = try original.digest()
            return request == original.id && digest == originalDigest
                && account == original.account && phone == original.phone
                && mac == original.mac && space == original.space
        }
    }

    /// The future adapter supplies the locally active client/device list and
    /// an actual public space ID. This reserves only; no callbacks or launch.
    public static func reserve(_ record: Record, client: SyncClient, knownPhones: [SyncClient.Listed],
                               publicSpace: String, cli: String) throws -> Reservation {
        guard client.state == .live, client.journal.clock.device == client.device.id,
              let body = record["body"]?.string, body.utf8.count <= 524_288,
              let request = try? JSONDecoder().decode(TaskRecords.Request.self, from: Data(body.utf8)),
              knownPhones.contains(where: { $0.id == request.phone && !$0.revoked
                  && $0.isMobile }) else { throw Failure.context }
        return try client.journal.reserveTaskCommand(record, account: client.seal.account,
                                                     device: client.device.id, phone: request.phone,
                                                     publicSpace: publicSpace, cli: cli)
    }
}
