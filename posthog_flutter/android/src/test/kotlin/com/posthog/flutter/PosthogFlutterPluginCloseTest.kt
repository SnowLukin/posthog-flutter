package com.posthog.flutter

import com.posthog.PostHog
import com.posthog.PostHogConfig
import com.posthog.internal.PostHogNetworkStatus
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import org.mockito.Mockito
import java.io.File
import java.nio.file.Files
import java.util.Collections
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

internal class PosthogFlutterPluginCloseTest {
    private val storage: File = Files.createTempDirectory("posthog-queue").toFile()
    private var hostCount = 0

    @AfterTest
    fun tearDown() {
        PostHog.close()
        storage.deleteRecursively()
    }

    @Test
    fun close_keepsQueueForNextSetupInsteadOfSendingIt() {
        val abandoned = fakeHost(status = 403)
        val next = fakeHost(status = 200)
        PostHog.setup(config(abandoned))
        PostHog.capture("queued-before-close")
        waitUntil { queuedFiles().isNotEmpty() }

        val result = Mockito.mock(MethodChannel.Result::class.java)
        PosthogFlutterPlugin().onMethodCall(MethodCall("close", null), result)
        Mockito.verify(result).success(null)
        Thread.sleep(500)

        assertTrue(abandoned.batches.isEmpty())
        assertEquals(1, queuedFiles().size)

        PostHog.setup(config(next))
        PostHog.flush()
        waitUntil { next.batches.isNotEmpty() && queuedFiles().isEmpty() }

        assertTrue(next.batches.single().contains("queued-before-close"))
    }

    @Test
    fun close_withoutSetupSucceeds() {
        val result = Mockito.mock(MethodChannel.Result::class.java)
        PosthogFlutterPlugin().onMethodCall(MethodCall("close", null), result)

        Mockito.verify(result).success(null)
    }

    @Test
    fun offlineNetworkStatus_reportsOfflineAndKeepsOriginalSubscription() {
        var registered = 0
        var unregistered = 0
        val original =
            object : PostHogNetworkStatus {
                override fun isConnected() = true

                override fun register(callback: () -> Unit) {
                    registered++
                }

                override fun unregister() {
                    unregistered++
                }
            }
        val status = OfflineNetworkStatus(original)

        assertFalse(status.isConnected())
        status.register {}
        status.unregister()
        assertEquals(1, registered)
        assertEquals(1, unregistered)
        assertFalse(OfflineNetworkStatus(null).isConnected())
    }

    private fun config(host: FakeHost) =
        PostHogConfig(apiKey = API_KEY, host = host.url).apply {
            httpClient = host.client
            storagePrefix = storage.absolutePath
            flushAt = 100
            preloadFeatureFlags = false
            remoteConfig = false
            networkStatus =
                object : PostHogNetworkStatus {
                    override fun isConnected() = true

                    override fun register(callback: () -> Unit) = Unit

                    override fun unregister() = Unit
                }
        }

    private fun queuedFiles(): List<File> = File(storage, API_KEY).listFiles()?.filter { it.isFile }.orEmpty()

    private fun fakeHost(status: Int): FakeHost {
        val batches = Collections.synchronizedList(mutableListOf<String>())
        val client =
            OkHttpClient
                .Builder()
                .addInterceptor { chain ->
                    val request = chain.request()
                    if (request.url.encodedPath.startsWith("/batch")) {
                        batches += Buffer().also { request.body?.writeTo(it) }.readUtf8()
                    }
                    Response
                        .Builder()
                        .request(request)
                        .protocol(Protocol.HTTP_1_1)
                        .code(status)
                        .message("")
                        .body("{}".toResponseBody())
                        .build()
                }.build()
        return FakeHost("https://host-${hostCount++}.example.invalid", client, batches)
    }

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("Condition not met within 5 seconds")
            Thread.sleep(50)
        }
    }

    private class FakeHost(
        val url: String,
        val client: OkHttpClient,
        val batches: List<String>,
    )

    private companion object {
        const val API_KEY = "test-key"
    }
}
