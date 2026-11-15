package dev.yab.agent

import dev.yab.core.sync.TaskRecords
import kotlinx.coroutines.flow.StateFlow

data class AgentTaskOrigin(val space: String, val tab: String? = null, val url: String? = null,
                           val title: String? = null, val isPrivate: Boolean = false)
data class TaskMac(val id: String, val name: String, val epoch: String)
data class ReadOnlyTask(val request: TaskRecords.Request, val observation: TaskRecords.Observation?, val macName: String, val macAwake: Boolean) {
    val id get() = request.id
    val title get() = observation?.title ?: request.words
    val progress get() = observation?.progress?.takeIf(String::isNotBlank) ?: when (observation?.status) {
        null -> if (macAwake) "Queued for your Mac" else "Waits for $macName"
        TaskRecords.Status.running -> "Working on your Mac"
        TaskRecords.Status.needsYou -> "Needs your attention"
        TaskRecords.Status.waits -> "Waiting on your Mac"
        TaskRecords.Status.failed -> "Failed"
        TaskRecords.Status.done -> "Completed"
        TaskRecords.Status.stopped -> "Stopped"
    }
}
interface AgentTaskPort {
    val tasks: StateFlow<List<ReadOnlyTask>>
    val taskMacs: StateFlow<List<TaskMac>>
    fun updateTaskScope(origin: AgentTaskOrigin?)
    suspend fun sendTask(words: String, origin: AgentTaskOrigin, mac: String, epoch: String): ReadOnlyTask
    suspend fun openTaskResult(task: ReadOnlyTask, url: String): String?
}
