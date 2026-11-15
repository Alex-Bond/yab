package dev.yab.browser.model

/** RAM-only one-shot identity. Matching field values after an ABA change cannot revive it. */
class FieldPrivateUnlockLease internal constructor(internal val input: FieldInputLease)
