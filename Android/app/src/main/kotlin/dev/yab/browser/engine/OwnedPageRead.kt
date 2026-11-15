package dev.yab.browser.engine

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.withTimeoutOrNull

internal enum class PageReadStage { IDLE, WAITING_BRIDGE, REQUEST_SENT, RECEIVED, OWNER_REVOKED, TIMED_OUT, CANCELLED, FAILED }

/** Native load completion and the content port's connection are independent callbacks.
 * The original owner must remain current throughout one shared response budget. */
internal suspend fun <Port : Any, Result : Any> readOwnedPage(
    current: () -> Boolean,
    connection: () -> Port?,
    request: suspend (Port) -> Result,
    stage: (PageReadStage) -> Unit = {},
): Result {
    var lastStage = PageReadStage.IDLE
    fun note(next: PageReadStage) { lastStage = next; stage(next) }
    fun requireOwner() {
        if (!current()) {
            note(PageReadStage.OWNER_REVOKED)
            error("The page changed")
        }
    }
    note(PageReadStage.WAITING_BRIDGE)
    try {
        val answer = withTimeoutOrNull(3_000) {
            var port: Port? = null
            while (port == null) {
                requireOwner()
                port = connection()
                if (port == null) delay(16)
            }
            requireOwner()
            note(PageReadStage.REQUEST_SENT)
            val response = request(port)
            requireOwner()
            note(PageReadStage.RECEIVED)
            response
        }
        if (answer == null) {
            note(PageReadStage.TIMED_OUT)
            error("The page did not answer")
        }
        return answer
    } catch (cancelled: CancellationException) {
        note(PageReadStage.CANCELLED)
        throw cancelled
    } catch (failure: Exception) {
        if (lastStage !in setOf(PageReadStage.OWNER_REVOKED, PageReadStage.TIMED_OUT)) note(PageReadStage.FAILED)
        throw failure
    }
}
