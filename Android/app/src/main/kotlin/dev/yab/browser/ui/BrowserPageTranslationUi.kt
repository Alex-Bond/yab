package dev.yab.browser.ui

import dev.yab.nativefeatures.TranslationMenuLease
import dev.yab.nativefeatures.TranslationPhase
import java.util.Locale

/** Rendered facts and original-document callbacks; this UI never starts a model download. */
data class BrowserPageTranslationUi(val title: String, val subtitle: String, val alwaysTitle: String,
    val checked: Boolean, val showAlways: Boolean, val onToggle: () -> Unit, val onAlways: () -> Unit)

fun pageTranslationMenu(lease: TranslationMenuLease, onToggle: () -> Unit, onAlways: () -> Unit): BrowserPageTranslationUi {
    val page = lease.page
    fun language(code: String?) = Locale.forLanguageTag(checkNotNull(code)).getDisplayLanguage(Locale.getDefault())
    val source = language(page.source); val target = language(page.target)
    val offered = page.phase in setOf(TranslationPhase.ORIGINAL, TranslationPhase.FAILED)
    val subtitle = when (page.phase) {
        TranslationPhase.ORIGINAL -> "This page is in $source"
        TranslationPhase.READING -> "Reading this page…"
        TranslationPhase.NEED_MODEL -> "Language models are needed"
        TranslationPhase.DOWNLOADING -> "Downloading language models…"
        TranslationPhase.TRANSLATING -> "Translating…"
        TranslationPhase.TRANSLATED -> "Translated from $source"
        TranslationPhase.FAILED -> page.error ?: "The page could not be translated"
    }
    return BrowserPageTranslationUi(if (offered) "Translate to $target" else "Show Original", page.error ?: subtitle,
        "Always Translate $source", page.always, page.always || !offered, onToggle, onAlways)
}
