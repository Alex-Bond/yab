import Foundation
import SyncKit

/// Capability replies contain live permissions, not a time-to-live guess.
/// Compare their small value inputs on every read; a changed grant, session,
/// preference or background metadata result cannot reuse an old answer.
@MainActor
final class AgentCapabilityCache {
    struct Assistant: Equatable {
        var grant: AssistantGrant
        var space: String
        var spaces: [String]
        var connected: Bool
        var approvalDevices: [String]
        var tasks: Bool
        var started: [String]
        @MainActor private static let mac = Host.current().localizedName ?? "Mac"

        @MainActor var answer: [String: Any] {
            ["id": grant.id, "name": grant.name, "client": grant.client,
             "space": space, "allSpaces": grant.allSpaces == true, "spaces": spaces,
             "mode": grant.mode.rawValue, "mail": grant.mail && connected,
             "messages": grant.messages, "cards": grant.cards, "paused": grant.paused,
             "never": grant.never, "allowedSites": grant.allowedSites ?? [], "only": grant.only,
             "approvalDevices": approvalDevices, "tasks": tasks, "mac": Self.mac, "started": started]
        }

        @MainActor static func read(_ grant: AssistantGrant, browser: Browser) -> Self {
            let space = browser.spaces.first { $0.id == grant.space } ?? browser.spaces.first
            return Self(grant: grant, space: grant.spaceName(in: browser.spaces),
                        spaces: grant.allSpaces == true ? browser.spaces.map(\.name) : [space?.name].compactMap { $0 },
                        connected: MailCenter.shared.connected,
                        approvalDevices: SyncCenter.shared.assistantAnswererNames,
                        tasks: AgentSetupModel.shared.canRunTasks(), started: Agents.shared.assistantStarted(grant.id))
        }
    }

    struct State: Equatable {
        var folder: Bool
        var boost: Bool
        var messages: Bool
        var mail: Bool
        var mailbox: Bool
        var mailAgents: Bool
        var recall: Bool
        var asking: String
        var knowing: Bool
        var assistant: Assistant?

        @MainActor var answer: [String: Any] {
            ["folder": folder, "boost": boost, "messages": messages, "mail": mail,
             "mailbox": mailbox, "mailAgents": mailAgents, "recall": recall,
             "asking": asking, "knowing": knowing,
             "assistant": assistant.map { $0.answer as Any } ?? NSNull()]
        }
    }

    private var entries: [String: (State, [String: Any])] = [:]
    private(set) var builds = 0

    func answer(session: String?, state: State) -> [String: Any] {
        let key = session ?? ""
        if let (before, answer) = entries[key], before == state { return answer }
        // Unknown caller IDs must not grow this cache for the life of Yab.
        if entries.count >= 512 { entries.removeAll(keepingCapacity: true) }
        let answer = state.answer
        entries[key] = (state, answer)
        builds += 1
        return answer
    }
}

/// This is display metadata, never the authority for accepting an approval.
/// Journal.record waits on the journal's serial queue: a Sync reconcile can
/// hold it for seconds. Capability polling must never join that queue on main.
@MainActor
final class AssistantAnswererNames {
    private(set) var names: [String] = []
    private var generation = 0

    func refresh(read: @escaping @Sendable () -> [String]) {
        generation &+= 1
        let asked = generation
        names = []
        Task { [weak self] in
            let names = await Task.detached(priority: .utility, operation: read).value
            guard let self, self.generation == asked else { return }
            self.names = names
        }
    }
}

extension SyncCenter {
    var assistantAnswererNames: [String] { capabilityAnswerers.names }

    func refreshAssistantAnswererNames() {
        let journal = on ? journal : nil
        let devices = devices
        let thisDevice = Self.deviceID
        capabilityAnswerers.refresh {
            guard let journal else { return [] }
            return devices.filter { device in
                device.id != thisDevice && !device.revoked
                    && AssistantApprovalRecords.answers(journal.record(.init(collection: OpenOnMac.capability, id: device.id)), device: device.id)
            }.map(\.name)
        }
    }
}

/// Session fields are reference values also used by provider readers. Their
/// change hook only bumps a locked token; the cached list is read on main.
final class AgentCapabilityRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return revision }
    func invalidate() { lock.lock(); revision &+= 1; lock.unlock() }
}
