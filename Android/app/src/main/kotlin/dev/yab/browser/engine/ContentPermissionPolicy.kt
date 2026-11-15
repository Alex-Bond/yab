package dev.yab.browser.engine

import java.net.URI

/**
 * What a page's content permission request turns into. Most requests never reach the person:
 * Chrome and Safari settle autoplay, DRM, storage and tracking quietly, and so does Yab.
 * Only location, notifications, cookie access for an embedded site and local devices ask,
 * and the question says what the site wants.
 */
internal sealed interface ContentPermissionAnswer {
    data object Allow : ContentPermissionAnswer
    data object Deny : ContentPermissionAnswer
    data class Ask(val title: String, val message: String) : ContentPermissionAnswer
}

internal object ContentPermissionPolicy {
    // GeckoSession.PermissionDelegate.PERMISSION_* values in GeckoView 158.
    const val GEOLOCATION = 0
    const val DESKTOP_NOTIFICATION = 1
    const val PERSISTENT_STORAGE = 2
    const val XR = 3
    const val AUTOPLAY_INAUDIBLE = 4
    const val AUTOPLAY_AUDIBLE = 5
    const val MEDIA_KEY_SYSTEM_ACCESS = 6
    const val TRACKING = 7
    const val STORAGE_ACCESS = 8
    const val LOCAL_DEVICE_ACCESS = 9
    const val LOCAL_NETWORK_ACCESS = 10

    fun answer(permission: Int, uri: String?, thirdPartyOrigin: String?): ContentPermissionAnswer {
        val site = host(uri) ?: "This site"
        return when (permission) {
            AUTOPLAY_INAUDIBLE, MEDIA_KEY_SYSTEM_ACCESS -> ContentPermissionAnswer.Allow
            // Audible autoplay waits for a tap on the page; storage stays best effort; no XR yet.
            AUTOPLAY_AUDIBLE, PERSISTENT_STORAGE, TRACKING, XR -> ContentPermissionAnswer.Deny
            GEOLOCATION -> ContentPermissionAnswer.Ask("Use your location?", "$site wants to know where you are.")
            DESKTOP_NOTIFICATION -> ContentPermissionAnswer.Ask("Allow notifications?", "$site wants to send you notifications.")
            STORAGE_ACCESS -> {
                val embedded = host(thirdPartyOrigin) ?: "An embedded site"
                ContentPermissionAnswer.Ask("Allow cookies?", "$embedded wants to use its cookies on $site, for example to keep you signed in.")
            }
            LOCAL_DEVICE_ACCESS, LOCAL_NETWORK_ACCESS ->
                ContentPermissionAnswer.Ask("Find devices on your network?", "$site wants to reach devices on your local network.")
            else -> ContentPermissionAnswer.Ask("Website permission", "$site asks for access.")
        }
    }

    private fun host(uri: String?): String? = uri?.let { runCatching { URI(it).host }.getOrNull() ?: it.takeIf(String::isNotBlank) }
        ?.removePrefix("www.")
}
