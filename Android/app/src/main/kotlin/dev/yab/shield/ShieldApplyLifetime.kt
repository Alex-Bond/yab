package dev.yab.shield

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** A child timeout is a failed attempt, while disposal/replacement cancels its owner. */
internal suspend fun shieldApplyFailure(apply: suspend () -> Unit): Exception? = try {
    apply()
    null
} catch (error: Exception) {
    currentCoroutineContext().ensureActive()
    error
}
