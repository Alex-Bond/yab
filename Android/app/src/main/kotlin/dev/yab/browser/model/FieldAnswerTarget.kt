package dev.yab.browser.model

/** An opaque document-local editable bookmark. No original field value leaves the page. */
interface FieldAnswerTarget {
    val ready: Boolean
    suspend fun insert(value: String): Boolean
    fun revoke()
}
