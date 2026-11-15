package dev.yab.android

import org.junit.Test

/** Historical before-shot only: its folder-first expectation deliberately describes
 * the older APK. Run against that artifact, never as acceptance of the fixed app. */
class MixedKeptTreeBaselineDeviceTest : MixedKeptTreeScenario() {
    @Test(timeout = 180_000) fun beforeMixedOrder() = runScenario(false)
}
