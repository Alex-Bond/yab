package dev.yab.agent

enum class FieldChatGroupId(val title: String) { CHATS("Chats"), TASKS("Tasks"), ROUTINES("Routines") }
data class FieldChatGroup(val id: FieldChatGroupId, val chats: List<AgentChat>)

/** Phone NewTabSpaces.ChatGroup, separate from the full chat list's date sections.
 * Caller supplies an already owner/private/search/archive-filtered list in its displayed order.
 * A present empty/unknown origin or routine remains present, exactly as Swift optional String.
 */
object FieldChatGroups {
    fun read(orderedChats: List<AgentChat>, searching: Boolean = false, archived: Boolean = false): List<FieldChatGroup> {
        if (searching || archived) return listOf(FieldChatGroup(FieldChatGroupId.CHATS, orderedChats))
        val yours = mutableListOf<AgentChat>()
        val tasks = mutableListOf<AgentChat>()
        val routines = mutableListOf<AgentChat>()
        val seen = mutableSetOf<String>()
        for (chat in orderedChats) {
            val routine = chat.routine ?: chat.title.takeIf { chat.origin == "routine" }
            if (routine != null) {
                if (seen.add(routine)) routines += chat
            } else if (chat.origin == null || chat.pinned) yours += chat
            else tasks += chat
        }
        return buildList {
            add(FieldChatGroup(FieldChatGroupId.CHATS, yours))
            if (tasks.isNotEmpty()) add(FieldChatGroup(FieldChatGroupId.TASKS, tasks))
            if (routines.isNotEmpty()) add(FieldChatGroup(FieldChatGroupId.ROUTINES, routines))
        }
    }

    fun projectCards(yours: List<AgentChat>, listed: List<AgentChat>, projects: List<dev.yab.core.sync.SyncProject>): List<FieldProjectCard> {
        val visible = projects.filterNot { it.archived }
        val known = visible.map { it.id }.toSet()
        val within = listed.filter { it.project in known }.groupBy { it.project }
        val rank = buildMap<String, Int> { listed.forEachIndexed { index, chat -> if (chat.id !in this) put(chat.id, index) } }
        val cards = yours.filter { it.project !in known }.map { (rank[it.id] ?: Int.MAX_VALUE) to FieldProjectCard.Chat(it) } +
            visible.filterNot { it.pinned }.map { project ->
                val chats = within[project.id].orEmpty()
                (chats.minOfOrNull { rank[it.id] ?: Int.MAX_VALUE } ?: Int.MAX_VALUE) to FieldProjectCard.Project(project, chats)
            }
        return cards.withIndex().sortedWith(compareBy({ it.value.first }, { it.index })).map { it.value.second }
    }

}
