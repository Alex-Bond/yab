package dev.yab.update

import kotlinx.serialization.Serializable

enum class UpdateStage { NONE, DOWNLOADING, READY, INSTALLING, NEEDS_PROMPT, PROMPTED }

/** A version that failed: it waits for a newer one, or a later launch after [notBefore]. */
@Serializable
data class UpdateFailure(val versionCode: Int, val attempts: Int, val notBefore: Long, val launch: Long)

/** Everything that survives the process. [prompt] is the system's confirm intent as a URI. */
@Serializable
data class UpdateRecord(val offer: UpdateOffer? = null, val stage: UpdateStage = UpdateStage.NONE, val session: Int = -1,
    val prompt: String? = null, val promptLaunch: Long = 0, val failure: UpdateFailure? = null, val launch: Long = 0)

enum class UpdateAction { NOTHING, DOWNLOAD, APPLY }

/** What a valid manifest changes. [discard] drops the files of work that no longer stands. */
data class UpdateDecision(val record: UpdateRecord, val action: UpdateAction, val discard: Boolean = false)

object UpdatePolicy {
    const val CHECK_PERIOD_MILLIS = 4 * 60 * 60 * 1000L
    const val QUIET_MILLIS = 10 * 60 * 1000L
    const val RETRY_BASE_MILLIS = 6 * 60 * 60 * 1000L
    const val RETRY_CAP_MILLIS = 7 * 24 * 60 * 60 * 1000L
    const val MAX_APK_BYTES = 512L * 1024 * 1024
    private val inSystemHands = setOf(UpdateStage.INSTALLING, UpdateStage.NEEDS_PROMPT, UpdateStage.PROMPTED)

    fun isNewer(offer: UpdateOffer, installed: Long, sdk: Int) = offer.versionCode > installed && offer.minSdk <= sdk

    fun retryDelay(attempts: Int): Long {
        val doublings = (attempts.coerceAtLeast(1) - 1).coerceAtMost(16)
        return (RETRY_BASE_MILLIS shl doublings).coerceAtMost(RETRY_CAP_MILLIS)
    }

    fun failed(previous: UpdateFailure?, versionCode: Int, now: Long, launch: Long): UpdateFailure {
        val attempts = if (previous?.versionCode == versionCode) previous.attempts + 1 else 1
        return UpdateFailure(versionCode, attempts, now + retryDelay(attempts), launch)
    }

    fun mayTry(failure: UpdateFailure?, versionCode: Int, now: Long, launch: Long) =
        failure == null || versionCode > failure.versionCode || versionCode == failure.versionCode && launch > failure.launch && now >= failure.notBefore

    /** Work on a version ends and the failure is remembered, so nothing below retries it. */
    fun fail(record: UpdateRecord, now: Long): UpdateRecord {
        val offer = record.offer ?: return record
        return record.copy(offer = null, stage = UpdateStage.NONE, session = -1, prompt = null, failure = failed(record.failure, offer.versionCode, now, record.launch))
    }

    /** A malformed manifest never reaches this: it changes nothing. A valid older one withdraws waiting work. */
    fun afterManifest(record: UpdateRecord, offer: UpdateOffer, installed: Long, sdk: Int, now: Long, manual: Boolean): UpdateDecision {
        val working = record.offer
        if (!isNewer(offer, installed, sdk)) {
            val waiting = record.stage == UpdateStage.DOWNLOADING || record.stage == UpdateStage.READY
            return if (waiting) UpdateDecision(record.copy(offer = null, stage = UpdateStage.NONE), UpdateAction.NOTHING, discard = true)
            else UpdateDecision(record, UpdateAction.NOTHING)
        }
        if (record.stage in inSystemHands) return UpdateDecision(record, UpdateAction.NOTHING)
        val failure = record.failure?.takeUnless { manual && it.versionCode <= offer.versionCode }
        if (!mayTry(failure, offer.versionCode, now, record.launch)) {
            val stale = working != null
            return UpdateDecision(record.copy(offer = null, stage = UpdateStage.NONE), UpdateAction.NOTHING, discard = stale)
        }
        if (working == offer) return UpdateDecision(record.copy(failure = failure), if (record.stage == UpdateStage.READY) UpdateAction.APPLY else UpdateAction.DOWNLOAD)
        return UpdateDecision(UpdateRecord(offer, UpdateStage.DOWNLOADING, failure = failure, launch = record.launch), UpdateAction.DOWNLOAD, discard = working != null)
    }

    /** At process start. [sessionCommitted] says whether the system still holds the committed session. */
    fun reconcile(record: UpdateRecord, installed: Long, sessionCommitted: Boolean, now: Long): UpdateDecision {
        val offer = record.offer
        val failure = record.failure?.takeIf { it.versionCode > installed }
        if (offer != null && offer.versionCode <= installed) return UpdateDecision(UpdateRecord(launch = record.launch), UpdateAction.NOTHING, discard = true)
        if (record.stage in inSystemHands && !sessionCommitted) return UpdateDecision(fail(record, now), UpdateAction.NOTHING, discard = true)
        return UpdateDecision(record.copy(failure = failure), if (record.stage == UpdateStage.READY) UpdateAction.APPLY else UpdateAction.NOTHING)
    }

    /** The prompt was shown in an earlier launch and nothing answered: it counts as declined, once. */
    fun promptExpired(record: UpdateRecord) = record.stage == UpdateStage.PROMPTED && record.launch > record.promptLaunch
}
