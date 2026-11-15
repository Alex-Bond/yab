package dev.yab.browser.engine

/** Bounded CSS geometry from the already owned, explicitly diagnostic text reply. */
class PageViewportGeometry private constructor(
    val clientHeight: Double,
    val scrollHeight: Double,
    val innerHeight: Double,
    val dpr: Double,
    val visualViewportHeight: Double?,
) {
    companion object {
        internal fun read(value: (String) -> Any?): PageViewportGeometry? {
            fun scalar(key: String): Double? = (value(key) as? Number)?.toDouble()
                ?.takeIf { it.isFinite() && it in 0.0..1_000_000.0 }
            return PageViewportGeometry(
                scalar("clientHeight") ?: return null,
                scalar("scrollHeight") ?: return null,
                scalar("innerHeight") ?: return null,
                scalar("dpr")?.takeIf { it > 0.0 } ?: return null,
                scalar("visualViewportHeight"),
            )
        }
    }
}
