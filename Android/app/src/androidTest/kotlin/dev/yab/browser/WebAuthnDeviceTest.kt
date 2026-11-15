package dev.yab.browser

import android.app.PendingIntent
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import dev.yab.android.BrowserSessionViewModel
import dev.yab.android.MainActivity
import dev.yab.android.WebAuthnResultTestActivity
import dev.yab.browser.model.*
import java.io.Closeable
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.security.KeyStore
import java.security.MessageDigest
import java.util.Collections
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Native browser/provider capability evidence, distinct from production passkey acceptance. */
@RunWith(AndroidJUnit4::class)
class WebAuthnDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test(timeout = 180_000)
    fun verifiedTlsPageInvokesWebAuthnAndRecordsTheRealProviderOutcome(): Unit = runBlocking {
        withMain { _, owner, directory ->
            val environment = JSONObject(File(directory, "fixture.json").readText())
            val trust = KeyStore.getInstance("AndroidCAStore").apply { load(null) }
            val expected = environment.getString("caSha256")
            assertTrue("The disposable AVD test CA is absent from Android's actual trust store",
                Collections.list(trust.aliases()).any { alias -> trust.getCertificate(alias)?.encoded?.let(::sha256) == expected })
            val previous = main { owner.engine.runtime.settings.enterpriseRootsEnabled }
            main { owner.engine.runtime.settings.enterpriseRootsEnabled = true }
            try {
                HttpsFixture(File(directory, "untrusted.p12")).use { untrusted ->
                    main { owner.browser.openUrl(untrusted.url) }
                    await("native rejection of an untrusted TLS certificate") { owner.browser.state.value.page.error != null }
                }
                HttpsFixture(File(directory, "server.p12")).use { server ->
                    main { owner.browser.openUrl(server.url) }
                    await("certificate-verified localhost WebAuthn page") {
                        owner.browser.state.value.page.let { !it.loading && it.title == "WebAuthn fixture" && it.error == null }
                    }
                    val text = main { owner.engine.readText(owner.browser.state.value.tab!!) }.text
                    assertTrue(text.contains("SecureContext=true"))
                    assertTrue(text.contains("PublicKeyCredential=true"))
                    click("Invalid relying party")
                    await("native invalid RP rejection") { owner.browser.state.value.page.title == "InvalidRP=SecurityError" }
                    val observations = JSONObject().put("tlsCertificateVerified", true).put("untrustedCertificateRejected", true)
                        .put("secureContext", true).put("publicKeyCredential", true).put("invalidRp", "SecurityError")
                        .put("productionPasskeyAcceptance", false).put("providerApproval", false)
                    for ((button, prefix) in listOf("Create fixture credential" to "Create", "Get unknown fixture credential" to "Get")) {
                        click(button)
                        var providerWindow: String? = null
                        var canceledUi = false
                        await("$prefix provider completion or bounded cancellation", 35_000) {
                            val packageName = instrumentation.uiAutomation.rootInActiveWindow?.packageName?.toString()
                            if (!canceledUi && packageName != null && (packageName.startsWith("com.google.android.gms") ||
                                        packageName == "com.android.credentialmanager" || packageName == "com.google.android.permissioncontroller")) {
                                providerWindow = packageName
                                shell("input keyevent 4"); canceledUi = true
                            }
                            owner.browser.state.value.page.title?.let { it.startsWith("$prefix=") && it != "$prefix=pending" } == true
                        }
                        val status = owner.browser.state.value.page.title!!.substringAfter('=')
                        assertTrue("Unexpected WebAuthn provider outcome $status", status in setOf("Accepted", "NotAllowedError", "SecurityError", "NotSupportedError", "AbortError", "UnknownError"))
                        observations.put(prefix.lowercase(), JSONObject().put("outcome", status).put("providerWindow", providerWindow)
                            .put("userCanceledProviderUi", canceledUi).put("positiveCeremonyVerified", false))
                    }
                    evidence("webauthn-provider-probe.json", observations)
                    BrowserInstrumentedTest().shot("webauthn-provider-outcome.png")
                }
            } finally { main { owner.engine.runtime.settings.enterpriseRootsEnabled = previous } }
        }
    }

    @Test(timeout = 180_000)
    fun nativeIntentLeaseRejectsRecreationNavigationAndPrivateLock(): Unit = runBlocking {
        withMain { scenario, owner, _ ->
            BrowserInstrumentedTest.FixtureServer().use { server ->
                main { owner.browser.openUrl(server.url("/safe/fido-owner")) }
                await("native activity owner") { owner.browser.state.value.page.title == "Safe page fido-owner" && !owner.browser.state.value.page.loading }
                suspend fun request(): CompletableDeferred<Result<Intent>> {
                    await("original native FIDO page ready before external UI") { main {
                        owner.firstRun.value == null &&
                            (owner.engine.runtime.activityDelegate as? dev.yab.browser.engine.NativeWebAuthnLauncher)?.ready == true
                    } }
                    return main {
                        val answer = CompletableDeferred<Result<Intent>>()
                        val pending = PendingIntent.getActivity(context, 802, Intent(context, WebAuthnResultTestActivity::class.java), PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                        val result = requireNotNull(owner.engine.runtime.activityDelegate).onStartActivityForResult(pending)!!
                        result.accept({ value ->
                            answer.complete(if (value != null) Result.success(value) else Result.failure(IllegalStateException("Native activity returned no result")))
                        }, { answer.complete(Result.failure(it ?: IllegalStateException("Native activity failed"))) })
                        answer
                    }
                }
                // This activity returns only a fixed fixture marker, never credentials.
                // It proves ActivityResult ownership independently from provider approval.
                val matching = request()
                click("Return native activity result")
                await("matching native result") { matching.isCompleted }
                assertEquals("owned-result", matching.await().getOrThrow().getStringExtra("fixture"))

                lateinit var originalHost: MainActivity
                lateinit var originalStore: androidx.lifecycle.ViewModelStore
                var originalTask = -1
                scenario.onActivity {
                    originalHost = it; originalStore = it.viewModelStore; originalTask = it.taskId
                    assertSame(owner, ViewModelProvider(it)[BrowserSessionViewModel::class.java])
                }
                val recreated = request()
                await("external fixture activity") { node("Return native activity result") != null }
                fun coveredOriginal(): Boolean {
                    val covers = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                        .filterIsInstance<WebAuthnResultTestActivity>().filter {
                            it.packageName == context.packageName && it.taskId == originalTask && it.hasWindowFocus()
                        }
                    return covers.size == 1 && !originalHost.isDestroyed && originalHost.taskId == originalTask &&
                        originalHost.viewModelStore === originalStore &&
                        originalHost.lifecycle.currentState == androidx.lifecycle.Lifecycle.State.CREATED
                }
                await("original Main stopped behind its owned native result fixture") { main { coveredOriginal() } }
                main {
                    check(coveredOriginal())
                    // ActivityScenario.recreate first forces RESUMED, which cannot
                    // happen while this real external result activity owns the window.
                    // Recreate the exact stopped owner without changing foreground.
                    originalHost.recreate()
                }
                await("old Activity request rejected") { recreated.isCompleted }
                assertTrue(recreated.await().isFailure)
                click("Return native activity result")
                await("recreated Main resumed") { scenario.state == androidx.lifecycle.Lifecycle.State.RESUMED }
                lateinit var retained: BrowserSessionViewModel
                scenario.onActivity { retained = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
                assertSame(owner, retained)

                val navigated = request()
                await("second external fixture activity") { node("Return native activity result") != null }
                main { owner.browser.openUrl(server.url("/safe/new-document"), newTab = false) }
                await("native document identity changed") { owner.browser.state.value.page.url == server.url("/safe/new-document") }
                click("Return native activity result")
                await("stale document result rejected") { navigated.isCompleted }
                assertTrue(navigated.await().isFailure)
                await("replacement document intact") { owner.browser.state.value.page.title == "Safe page new-document" && !owner.browser.state.value.page.loading }

                main { owner.browser.openUrl(server.url("/safe/private-fido"), privately = true); owner.browser.unlockPrivate(true) }
                await("private native document") { owner.browser.state.value.page.title == "Safe page private-fido" && !owner.browser.state.value.page.loading }
                val privateResult = request()
                click("Return native activity result")
                await("Private native result denied after background lock") { privateResult.isCompleted }
                assertTrue(privateResult.await().isFailure)
                assertTrue(owner.browser.state.value.privateContentBlocked)
                evidence("webauthn-native-intent-leases.json", JSONObject().put("matching", true).put("recreateRejected", true)
                    .put("navigationRejected", true).put("privateLockRejected", true).put("passkeyProviderAcceptance", false))
            }
        }
    }

    private suspend fun withMain(block: suspend (ActivityScenario<MainActivity>, BrowserSessionViewModel, File) -> Unit) {
        check(InstrumentationRegistry.getArguments().getString("ownedEmulator") == "true")
        check(InstrumentationRegistry.getArguments().getString("requireWebAuthn") == "true")
        val directory = File(context.filesDir, "webauthn-tests")
        check(File(directory, "server.p12").isFile)
        // This is a functional owned-profile fixture. Seed its prerequisite
        // before Main can start a first-run flow, rather than changing it under
        // an already-mounted first-run cover.
        val repository = FileBrowserRepository(File(context.filesDir, "browser.json"))
        val initial = repository.load() ?: BrowserSnapshot(
                spaces = listOf(BrowserSpace(BrowserController.PERSONAL_SPACE, "Personal")),
                selectedSpaceId = BrowserController.PERSONAL_SPACE)
        repository.save(initial.copy(settings = initial.settings.copy(welcomed = true)))
        val scenario = ActivityScenario.launch(MainActivity::class.java)
        lateinit var owner: BrowserSessionViewModel
        var restore: BrowserSnapshot? = null
        try {
            scenario.onActivity { owner = ViewModelProvider(it)[BrowserSessionViewModel::class.java] }
            await("profile") { !owner.browser.state.value.loading }
            restore = owner.browser.publicSnapshot()
            main {
                owner.browser.updateSettings(owner.browser.state.value.settings.copy(welcomed = true, autoClearToday = false, lockPrivate = true))
                BrowserInstrumentedTest().ownSpace(owner.browser, "WebAuthn ${UUID.randomUUID()}")
            }
            block(scenario, owner, directory)
        } finally {
            if (restore != null) {
                main {
                    owner.browser.state.value.spaces.filter(BrowserSpace::isPrivate).flatMap { it.tabs }.forEach { owner.browser.closeTab(it.id) }
                    owner.browser.applySyncedSnapshot(restore!!)
                }
                await("restored public profile") { FileBrowserRepository(File(context.filesDir, "browser.json")).load() == restore }
            }
            scenario.close()
        }
    }

    private fun evidence(name: String, value: JSONObject) = File(context.getExternalFilesDir(null), "instrumentation").apply { mkdirs() }.resolve(name).writeText(value.toString(2))
    private fun sha256(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun node(text: String): AccessibilityNodeInfo? =
        if (text == "Return native activity result")
            OwnedWebControl.find(text, ignoreCase = true, className = "android.widget.Button")
        else OwnedWebControl.find(text)
    private suspend fun click(text: String) {
        try { await(text) { node(text) != null } }
        catch (failure: Throwable) { NativeWebControlDiagnostics.capture(text); throw failure }
        var current = requireNotNull(node(text))
        repeat(6) {
            if (current.isClickable && current.isEnabled) { assertTrue(current.performAction(AccessibilityNodeInfo.ACTION_CLICK)); return }
            current = current.parent ?: error("No native click target for $text")
        }
        error("No native click target for $text")
    }
    private suspend fun await(name: String, timeout: Long = 25_000, ready: suspend () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + timeout
        while (!ready()) {
            if (SystemClock.elapsedRealtime() >= end) {
                NativeWebControlDiagnostics.capture(name)
                error("Timed out waiting for $name")
            }
            delay(80)
        }
    }
    private suspend fun <T> main(block: suspend () -> T): T = withContext(Dispatchers.Main) { block() }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }

    private class HttpsFixture(store: File) : Closeable {
        private val keys = KeyStore.getInstance("PKCS12").apply { store.inputStream().use { load(it, "yab-owned-fixture".toCharArray()) } }
        private val managers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm()).apply { init(keys, "yab-owned-fixture".toCharArray()) }
        private val ssl = SSLContext.getInstance("TLS").apply { init(managers.keyManagers, null, null) }
        private val server = ssl.serverSocketFactory.createServerSocket(0, 8, InetAddress.getByName("127.0.0.1"))
        private val running = AtomicBoolean(true)
        private val sockets = ConcurrentHashMap.newKeySet<SSLSocket>()
        private val listener = Executors.newSingleThreadExecutor()
        private val clients = Executors.newFixedThreadPool(2)
        val url get() = "https://localhost:${server.localPort}/webauthn"
        init { listener.submit { while (running.get()) {
            val socket = try { server.accept() as SSLSocket } catch (error: IOException) { if (running.get()) throw error else break }
            sockets.add(socket)
            clients.submit { socket.use { client -> try {
                client.soTimeout = 5000
                val input = client.inputStream.bufferedReader()
                input.readLine() ?: return@use
                while (!input.readLine().isNullOrEmpty()) { }
                val html = PAGE.toByteArray()
                client.outputStream.write(("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: ${html.size}\r\nConnection: close\r\n\r\n").toByteArray())
                client.outputStream.write(html)
            } catch (_: IOException) { /* TLS rejection and canceled clients own only their socket. */ }
            finally { sockets.remove(client) } } }
        } } }
        override fun close() { running.set(false); server.close(); sockets.forEach { runCatching { it.close() } }; listener.shutdownNow(); clients.shutdownNow() }
        companion object {
            val PAGE = """<!doctype html><html lang='en'><meta name='viewport' content='width=device-width,initial-scale=1'><title>WebAuthn fixture</title><main><h1>Owned WebAuthn fixture</h1><p id='capability'></p><p id='result'>No request</p>
                <button onclick="run('InvalidRP')">Invalid relying party</button><button onclick="run('Create')">Create fixture credential</button><button onclick="run('Get')">Get unknown fixture credential</button>
                <script>document.getElementById('capability').textContent='SecureContext='+isSecureContext+' PublicKeyCredential='+(typeof PublicKeyCredential==='function');
                async function run(kind){const p=document.getElementById('result');document.title=kind+'=pending';p.textContent=kind+'=pending';const c=new AbortController();const timer=setTimeout(()=>c.abort(),10000);
                try{const challenge=crypto.getRandomValues(new Uint8Array(32));const rp=kind==='InvalidRP'?'unrelated.invalid':location.hostname;let credential;
                if(kind==='Get'){credential=await navigator.credentials.get({signal:c.signal,publicKey:{challenge,rpId:rp,timeout:10000,userVerification:'discouraged',allowCredentials:[{type:'public-key',id:crypto.getRandomValues(new Uint8Array(32))}]}});}
                else{credential=await navigator.credentials.create({signal:c.signal,publicKey:{challenge,rp:{id:rp,name:'Owned disposable RP'},user:{id:crypto.getRandomValues(new Uint8Array(16)),name:'owned-fixture',displayName:'Owned fixture'},pubKeyCredParams:[{type:'public-key',alg:-7}],timeout:10000,attestation:'none',authenticatorSelection:{residentKey:'discouraged',userVerification:'discouraged'}}});}
                document.title=kind+'='+ (credential?'Accepted':'NotAllowedError');p.textContent=document.title;
                }catch(e){document.title=kind+'='+e.name;p.textContent=document.title;}finally{clearTimeout(timer);}}</script></main></html>""".trimIndent()
        }
    }
}
