package dev.yab.agent

import androidx.test.platform.app.InstrumentationRegistry
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Root preloads the immutable catalog model and passes -e requireModel true for release evidence. */
class LocalInferenceTest {
    @Test(timeout = 180_000) fun actualCpuInferenceAnswersFromPrivatePage(): Unit = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val models = LocalModelManager(instrumentation.targetContext)
        val required = InstrumentationRegistry.getArguments().getString("requireModel") == "true"
        if (required) assertTrue("The proof requires a preloaded model", models.modelFile.isFile)
        else assumeTrue("No test model has been installed", models.modelFile.isFile)
        val expected = when (InstrumentationRegistry.getArguments().getString("modelCatalog", "smokeTest")) {
            "compact" -> LocalModelCatalog.compact
            "full" -> LocalModelCatalog.full
            "smokeTest" -> LocalModelCatalog.smokeTest
            else -> error("Unknown pinned model selected by the owned-device runner")
        }
        assertEquals(expected.bytes, models.modelFile.length())
        val digest = MessageDigest.getInstance("SHA-256")
        models.modelFile.inputStream().use { input -> val buffer = ByteArray(1024 * 1024); while (true) { val read = input.read(buffer); if (read == -1) break; digest.update(buffer, 0, read) } }
        assertEquals(expected.sha256, digest.digest().joinToString("") { "%02x".format(it) })
        val result = LiteRtLocalAiAdapter(models).answer(LocalQuestion(
            "What city is the delivery going to? Answer with the city name.",
            PageContext("Delivery confirmation", "https://fixture.invalid/delivery", "Delivery confirmation. The delivery city is Oslo. The parcel arrives on Friday.", isPrivate = true),
            emptyList(),
        ))
        assertTrue("Native inference returned no text", result.isNotBlank())
        assertTrue("Native inference did not answer the supplied page fact: $result", result.contains("Oslo", ignoreCase = true))
    }
}
