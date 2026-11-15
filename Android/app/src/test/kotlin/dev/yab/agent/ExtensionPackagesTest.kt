package dev.yab.agent

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.*
import org.junit.Test

class ExtensionPackagesTest {
    @Test fun chromeCrxIsExplicitlyRefusedRatherThanRepackedOrTrusted() {
        val found = ExtensionPackages.inspect(byteArrayOf(67, 114, 50, 52, 3, 0, 0, 0))
        assertEquals(ExtensionPackages.Format.CHROME_CRX, found.format)
        assertTrue(found.reason.contains("Chromium"))
    }
    @Test fun zipManifestIsOnlyACandidateAndStillRequiresNativeSignatureValidation() {
        val bytes = ByteArrayOutputStream().also { output -> ZipOutputStream(output).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.json")); zip.write("""{"name":"Test","version":"1.0","manifest_version":2}""".toByteArray()); zip.closeEntry()
        } }.toByteArray()
        val found = ExtensionPackages.inspect(bytes)
        assertEquals(ExtensionPackages.Format.MOZILLA_XPI_CANDIDATE, found.format)
        assertEquals("Test", found.name)
        assertTrue(found.reason.contains("signature"))
    }
    @Test fun arbitraryBytesAreNotAnExtension() {
        assertEquals(ExtensionPackages.Format.UNSUPPORTED, ExtensionPackages.inspect("not an extension".toByteArray()).format)
    }
}
