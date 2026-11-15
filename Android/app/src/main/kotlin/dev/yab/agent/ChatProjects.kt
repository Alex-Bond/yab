package dev.yab.agent

import dev.yab.core.sync.ChatProjects
import dev.yab.core.sync.SyncProject

/** One account publication, never projects from a previous account paired with today's route. */
data class ChatProjectsSnapshot(
    val account: String? = null,
    val device: String? = null,
    val epoch: Long = 0,
    val projects: List<SyncProject> = emptyList(),
    val removed: Boolean = false,
    val generation: Long = 0,
    val routing: ChatProjectRouting = ChatProjectRouting(),
    val memberships: List<ChatProjectMembership> = emptyList(),
    private val presences: Map<String, ChatProjectPresence> = projects.associate { it.id to ChatProjectPresence(it.id) },
) {
    val listed: List<SyncProject> get() = projects.filterNot { it.archived }
    fun project(id: String?): SyncProject? = projects.singleOrNull { it.id == id }
    fun presence(id: String?): ChatProjectPresence? = presences[id]
    fun matches(connection: RemoteConnection): Boolean = !removed && account != null && !device.isNullOrBlank() &&
        connection.account == account && connection.epoch == epoch
    companion object {
        /** The producer retires disappearances before publishing, including an unrendered remove/readd. */
        fun publish(previous: ChatProjectsSnapshot, account: String?, device: String?, epoch: Long,
            projects: List<SyncProject>, removed: Boolean = false, connection: RemoteConnection? = null,
            memberships: List<ChatProjectMembership> = emptyList()): ChatProjectsSnapshot {
            val sameOwner = account != null && previous.account == account && previous.device == device && previous.epoch == epoch && !removed && !previous.removed
            val ids = if (removed || account == null || device.isNullOrBlank()) emptySet() else projects.map { it.id }.toSet()
            previous.presences.forEach { (id, token) -> if (!sameOwner || id !in ids) token.retire() }
            val tokens = ids.associateWith { id -> previous.presences[id]?.takeIf { sameOwner && it.current(previous) } ?: ChatProjectPresence(id) }
            val next = ChatProjectsSnapshot(account, device, epoch, if (removed) emptyList() else projects,
                removed, previous.generation, connection?.let { ChatProjectRouting.read(it) } ?: ChatProjectRouting(), memberships, tokens)
            return if (next == previous) previous else next.copy(generation = previous.generation + 1)
        }
    }
}

data class ChatProjectMembership(val chat: String, val mac: String, val provider: AgentProvider?, val project: String?)

class ChatProjectPresence internal constructor(val id: String) {
    @Volatile private var retired = false
    internal fun retire() { retired = true }
    fun current(snapshot: ChatProjectsSnapshot): Boolean = !retired && snapshot.presence(id) === this && snapshot.project(id) != null && !snapshot.removed
}

/** Only capability and selected-route facts; unrelated presence timestamps do not churn controls. */
data class ChatProjectRouting(val selected: String? = null, val destinations: List<Destination> = emptyList(),
    val routes: Map<AgentProvider, String?> = emptyMap()) {
    data class Destination(val id: String, val projects: Boolean, val metadata: Boolean, val providers: Set<AgentProvider>)
    companion object {
        fun read(connection: RemoteConnection) = ChatProjectRouting(connection.selectedMac,
            connection.macs.map { Destination(it.id, it.takesProjects, it.takesMetadata, it.providers) }.sortedBy { it.id },
            AgentProvider.entries.associateWith { connection.route(it)?.id })
    }
}

/** Opaque original project action. A failed source or publication can never become current again. */
class ChatProjectLease internal constructor(
    internal val kind: Kind,
    val snapshot: ChatProjectsSnapshot,
    val chat: AgentChat?,
    val project: String?,
    val mac: String,
    val provider: AgentProvider,
    private val source: () -> Boolean,
) {
    internal enum class Kind { START, MOVE, DRAFT, SEND }
    @Volatile private var retired = false
    fun retire() { retired = true }
    fun sourceCurrent(): Boolean {
        if (retired) return false
        if (!runCatching(source).getOrDefault(false)) { retired = true; return false }
        return true
    }
    fun current(projects: ChatProjectsSnapshot, connection: RemoteConnection): Boolean {
        if (!sourceCurrent()) return false
        val destination = connection.macs.singleOrNull { it.id == mac }
        val target = snapshot.project(project)
        val valid = projects == snapshot && snapshot.matches(connection) && destination != null && destination.takesProjects &&
            (kind == Kind.MOVE || provider in destination.providers) && (kind != Kind.MOVE || destination.takesMetadata) &&
            (project == null || ChatProjects.valid(project) && target != null && !target.archived) &&
            (kind == Kind.MOVE || chat?.owner != null || connection.route(provider)?.id == mac)
        if (!valid) retired = true
        return valid
    }
    internal fun requireKind(expected: Kind) { require(kind == expected) { CHANGED } }
    companion object {
        const val CHANGED = "The project, conversation or Sync session changed. Open it again."
    }
}
