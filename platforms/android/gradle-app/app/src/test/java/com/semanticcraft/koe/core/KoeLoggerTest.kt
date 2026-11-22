package com.semanticcraft.koe.core

import com.semanticcraft.koe.bridge.KoeNativeBridge
import java.nio.charset.StandardCharsets
import kotlinx.serialization.Serializable
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class KoeLoggerTest {
    @Serializable
    private data class RequiredPayload(val title: String, val count: Int)

    private class SingleSnapshotBridge(private val snapshotJson: String) : HostBridgeClient {
        override fun apiVersion(): Int = 2
        override fun sessionCreate(directory: String): Long = 501L
        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 501L
        override fun sessionDestroy(handle: Long): Boolean = true
        override fun sessionGeneration(handle: Long): Long = 0L
        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String = snapshotJson
        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String = snapshotJson
        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long = 0L
        override fun sessionIngestPcm(
            handle: Long,
            recordId: String,
            sessionId: String,
            lane: String,
            sequence: Long,
            epoch: Long,
            capturedStartNs: Long?,
            samples: ShortArray,
            sampleCount: Int,
            nowEpochSec: Long,
        ): PcmIngestReceipt = PcmIngestReceipt(0L, 0L, PcmIngestStatus.REJECTED)
        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(0L, 0L, 0L, 0L, false, false, false)
        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)
        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)
        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long = 0L
    }

    @Before
    fun setUp() {
        KoeLogger.clearForTests()
        KoeLogger.setSinkForTests(null)
    }

    @After
    fun tearDown() {
        KoeLogger.clearForTests()
        KoeLogger.setSinkForTests(null)
    }

    @Test
    fun redactScrubsSecretsAndCapsLength() {
        val raw = "auth=Bearer tok_abc.99 key=sk-secret123456 apiKey=xyz " +
            "\"deepseekApiKey\":\"ds_secret_88\" token: tok_val secret=\"s3cr3t\" password='hunter2'"
        val redacted = KoeLogger.redact(raw)

        assertFalse(redacted.contains("tok_abc"))
        assertFalse(redacted.contains("sk-secret123456"))
        assertFalse(redacted.contains("xyz"))
        assertFalse(redacted.contains("ds_secret_88"))
        assertFalse(redacted.contains("tok_val"))
        assertFalse(redacted.contains("s3cr3t"))
        assertFalse(redacted.contains("hunter2"))
        assertTrue(redacted.contains("Bearer [REDACTED]"))
        assertTrue(redacted.contains("[REDACTED]"))

        val capped = KoeLogger.redact("a".repeat(450))
        assertTrue(capped.length <= KoeLogger.MAX_MESSAGE_CHARS)
        assertTrue(capped.endsWith("..."))
    }

    @Test
    fun redactCoversTruncatedJsonPrefixedKeysAuthorizationAndDottedSk() {
        val cases = listOf(
            """...{"deepseekApiKey":"ds_secret_99...""" to listOf("ds_secret_99"),
            """"apiKey":"raw_secret_without_closing_quote""" to listOf("raw_secret_without_closing_quote"),
            "DASHSCOPE_API_KEY=ds_raw_999 DEEPSEEK_API_KEY=ds_alt_888" to listOf("ds_raw_999", "ds_alt_888"),
            """"qwenApiKey":"ds_raw_999" qwen_api_key=qwen_val_777""" to listOf("ds_raw_999", "qwen_val_777"),
            "authToken=tok_1 client_secret=sec_1 private_key=pk_secret_2" to listOf("tok_1", "sec_1", "pk_secret_2"),
            "Authorization: Basic dXNlcjpwYXNz" to listOf("dXNlcjpwYXNz"),
            """"authorization":"Basic dXNlcjpwYXNz"""" to listOf("dXNlcjpwYXNz"),
            "key=sk-proj.abc.def trailing=ok" to listOf("sk-proj", "abc", "def"),
        )

        for ((input, forbidden) in cases) {
            val redacted = KoeLogger.redact(input)
            for (secret in forbidden) {
                assertFalse("leaked $secret in $redacted", redacted.contains(secret))
            }
            assertTrue("expected [REDACTED] in $redacted", redacted.contains("[REDACTED]"))
        }

        val preserved = "keyNotFound path=config.apiKey expected=Int"
        assertEquals(preserved, KoeLogger.redact(preserved))
    }

    @Test
    fun describeExceptionSurfacesMissingFieldAndSerializationPathsWithRedaction() {
        val missingError = runCatching {
            HostJson.json.decodeFromString(RequiredPayload.serializer(), """{"count":1}""")
        }.exceptionOrNull()
        assertNotNull(missingError)
        val missingDesc = KoeLogger.describeException(requireNotNull(missingError))
        assertTrue(missingDesc.contains("title"))

        val typeError = runCatching {
            HostJson.json.decodeFromString(RequiredPayload.serializer(), """{"title":"ok","count":"oops"}""")
        }.exceptionOrNull()
        assertNotNull(typeError)
        val typeDesc = KoeLogger.describeException(requireNotNull(typeError))
        assertTrue(typeDesc.contains("count"))

        val secretError = IllegalStateException("failed with sk-leaked999 and apiKey=top_secret")
        val secretDesc = KoeLogger.describeException(secretError)
        assertFalse(secretDesc.contains("sk-leaked999"))
        assertFalse(secretDesc.contains("top_secret"))
    }

    @Test
    fun ringBufferCapsAt200EntriesAndForwardsToInjectedSink() {
        val observed = mutableListOf<Triple<DiagnosticLogLevel, String, String>>()
        KoeLogger.setSinkForTests { level, tag, msg -> observed.add(Triple(level, tag, msg)) }

        repeat(210) { idx ->
            KoeLogger.i("KoeTest", "op_$idx", "msg_$idx")
        }

        val entries = KoeLogger.recentEntries()
        assertEquals(KoeLogger.MAX_CAPACITY, entries.size)
        assertEquals("op_10", entries.first().operation)
        assertEquals("op_209", entries.last().operation)
        assertEquals(210, observed.size)
    }

    @Test
    fun hostSessionStoreLogsExactMismatchedAndMissingSnapshotFieldWithoutLeakingSecrets() {
        val richJson = checkNotNull(javaClass.classLoader?.getResourceAsStream("android-rich-snapshot.json"))
            .use { String(it.readBytes(), StandardCharsets.UTF_8) }
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-diag-android",
            bridge = SingleSnapshotBridge(richJson),
            allowDebugFixture = true,
        )

        assertFalse(store.exportTraceJson().contains("errorDetail"))

        val wrongGenerationJson = richJson.replace("\"generation\": 42,", "\"generation\": \"oops\",")
        assertFalse(store.loadDebugSnapshotFixtureJson(wrongGenerationJson))

        val typeLog = KoeLogger.recentEntries().lastOrNull()
        assertNotNull(typeLog)
        assertEquals("error", typeLog?.level)
        assertTrue("expected generation in ${typeLog?.message}", typeLog?.message?.contains("generation") == true)

        val typeTrace = store.recentTraceEntries().last()
        assertTrue(typeTrace.hasError)
        assertTrue(
            "expected generation in ${typeTrace.errorDetail}",
            typeTrace.errorDetail?.contains("generation") == true,
        )

        val missingFieldJson = """{"version":2,"generation":99,"records":[{"id":"r1","preview":"sk-secret999"}]}"""
        assertFalse(store.loadDebugSnapshotFixtureJson(missingFieldJson))

        val missingLog = KoeLogger.recentEntries().lastOrNull()
        assertNotNull(missingLog)
        assertFalse(missingLog?.message?.contains("sk-secret999") == true)
        assertTrue(
            "expected missing field name title in ${missingLog?.message}",
            missingLog?.message?.contains("title") == true,
        )
        val missingTrace = store.recentTraceEntries().last()
        assertTrue(missingTrace.hasError)
        assertTrue(
            "expected missing field name title in ${missingTrace.errorDetail}",
            missingTrace.errorDetail?.contains("title") == true,
        )

        val transcriptLeak = "Board salary review for Alice"
        val transcriptMalformedJson =
            """{"version":2,"generation":"oops","records":[{"id":"rec-9","title":"Review","preview":"$transcriptLeak"}]}"""
        assertFalse(store.loadDebugSnapshotFixtureJson(transcriptMalformedJson))

        val transcriptLog = KoeLogger.recentEntries().lastOrNull()
        assertNotNull(transcriptLog)
        assertTrue(
            "expected generation field in ${transcriptLog?.message}",
            transcriptLog?.message?.contains("generation") == true,
        )
        assertFalse(
            "must not leak transcript preview in log: ${transcriptLog?.message}",
            transcriptLog?.message?.contains(transcriptLeak) == true,
        )
        val transcriptTrace = store.recentTraceEntries().last()
        assertTrue(transcriptTrace.hasError)
        assertTrue(transcriptTrace.errorDetail?.contains("generation") == true)
        assertFalse(
            "must not leak transcript preview in trace errorDetail: ${transcriptTrace.errorDetail}",
            transcriptTrace.errorDetail?.contains(transcriptLeak) == true,
        )
    }
}
