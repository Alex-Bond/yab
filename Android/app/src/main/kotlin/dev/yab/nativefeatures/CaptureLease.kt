package dev.yab.nativefeatures

import java.util.concurrent.atomic.AtomicLong

/** Permission dialogs and sensor callbacks cannot borrow a replacement page or dialog. */
class CaptureLease {
    data class Token(val owner: String, val generation: Long)
    private val generation = AtomicLong()
    fun begin(owner: String): Token = Token(owner, generation.incrementAndGet())
    fun current(token: Token, owner: String): Boolean = token.owner == owner && token.generation == generation.get()
    fun retire() { generation.incrementAndGet() }
}
