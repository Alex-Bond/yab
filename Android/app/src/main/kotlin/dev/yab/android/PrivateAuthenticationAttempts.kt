package dev.yab.android

/** Activity-local result authority. Device authentication itself is always performed by Android. */
internal class PrivateAuthenticationAttempts {
    data class Owner(val account: String?, val device: String?, val epoch: Long, val removed: Boolean)
    class Attempt internal constructor(internal val owner: Owner)
    private var active: Attempt? = null

    fun begin(owner: Owner): Attempt? {
        active = null
        if (owner.removed) return null
        return Attempt(owner).also { active = it }
    }

    /** Consume the original identity even when its owner no longer matches. */
    fun consume(attempt: Attempt, owner: Owner): Boolean {
        if (active !== attempt) return false
        active = null
        return !owner.removed && attempt.owner == owner
    }

    fun invalidate() { active = null }
}
