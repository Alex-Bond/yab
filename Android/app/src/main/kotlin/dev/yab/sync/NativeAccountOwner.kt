package dev.yab.sync

/** A publication is a browser owner only while the immediate native identity still agrees. */
internal fun nativeAccountOwnerCurrent(
    expected: AccountRecordsSnapshot, published: AccountRecordsSnapshot,
    identity: SyncIdentityLease?, epoch: Long, closing: Boolean,
): Boolean = !closing && !expected.removed && !published.removed && epoch == expected.epoch &&
    published.account == expected.account && published.device == expected.device && published.epoch == expected.epoch &&
    identity?.account == expected.account && identity?.device == expected.device && (identity == null || identity.epoch == expected.epoch)
