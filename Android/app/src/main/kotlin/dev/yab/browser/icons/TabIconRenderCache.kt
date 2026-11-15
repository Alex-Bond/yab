package dev.yab.browser.icons

/** The current native TabIcons policy: no new raster until the source identity or geometry changes. */
internal class TabIconRenderCache<T : Any> {
    private data class Rendered<T>(val source: Any?, val result: T)
    private val rendered = linkedMapOf<String, Rendered<T>>()
    var renders = 0
        private set
    fun clear() { rendered.clear() }
    fun image(key: String, source: Any?, render: () -> T): T {
        rendered[key]?.takeIf { it.source === source }?.let { return it.result }
        val image = render(); renders++
        if (rendered.size >= 256) rendered.clear()
        rendered[key] = Rendered(source, image)
        return image
    }
}
