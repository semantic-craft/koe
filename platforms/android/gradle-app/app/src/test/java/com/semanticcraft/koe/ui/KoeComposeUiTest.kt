package com.semanticcraft.koe.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isDialog
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.text.AnnotatedString
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.KoeApplication
import com.semanticcraft.koe.bridge.KoeNativeBridge
import com.semanticcraft.koe.core.HostBridgeClient
import com.semanticcraft.koe.core.HostJson
import com.semanticcraft.koe.core.HostSessionStore
import com.semanticcraft.koe.core.HostSnapshot
import com.semanticcraft.koe.core.MemorySnapshot
import com.semanticcraft.koe.core.PcmIngestReceipt
import com.semanticcraft.koe.core.PcmIngestStatus
import com.semanticcraft.koe.core.PlaybackProgressReceipt
import com.semanticcraft.koe.core.RecordSnapshot
import com.semanticcraft.koe.core.TaskSnapshot
import com.semanticcraft.koe.ui.screens.ActionsScreen
import com.semanticcraft.koe.ui.screens.KoeRootScreen
import com.semanticcraft.koe.ui.theme.KoeTheme
import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h915dp-xhdpi")
class KoeComposeUiTest {
    @get:Rule
    val composeRule = createRobolectricComposeRule()

    internal class FakeUiBridgeClient(
        private var currentSnapshot: HostSnapshot = HostSnapshot.empty.copy(generation = 1L),
    ) : HostBridgeClient {
        val dispatchedCommands = mutableListOf<JsonObject>()

        override fun apiVersion(): Int = 2

        override fun sessionCreate(directory: String): Long = 101L

        override fun sessionCreateWithCredentials(
            directory: String,
            credentialBridge: KoeNativeBridge.CredentialBridge,
            isolated: Boolean,
        ): Long = 101L

        override fun sessionDestroy(handle: Long): Boolean = true

        override fun sessionGeneration(handle: Long): Long = currentSnapshot.generation

        override fun sessionSnapshotJson(handle: Long, nowEpochSec: Long): String =
            HostJson.json.encodeToString(HostSnapshot.serializer(), currentSnapshot)

        override fun sessionDispatchJson(handle: Long, commandJson: String, nowEpochSec: Long): String {
            val obj = HostJson.json.parseToJsonElement(commandJson) as JsonObject
            dispatchedCommands.add(obj)
            val cmdType = obj["type"]?.jsonPrimitive?.content
            currentSnapshot = when (cmdType) {
                "create_note" -> {
                    val title = obj["title"]?.jsonPrimitive?.content.orEmpty()
                    val text = obj["text"]?.jsonPrimitive?.content.orEmpty()
                    val nextId = "rec-note-${currentSnapshot.records.size + 1}"
                    val created = RecordSnapshot(
                        id = nextId,
                        title = title,
                        createdAtEpochSec = 1763596800L,
                        durationMs = 0L,
                        source = "文本输入",
                        status = "已保存",
                        segmentCount = 1,
                        preview = text,
                        mode = "quick_note",
                    )
                    currentSnapshot.copy(
                        generation = currentSnapshot.generation + 1L,
                        records = listOf(created) + currentSnapshot.records,
                    )
                }
                "set_meeting_audio_policy" -> {
                    val policy = obj["policy"]?.jsonPrimitive?.content ?: "local_only"
                    currentSnapshot.copy(
                        generation = currentSnapshot.generation + 1L,
                        provider = currentSnapshot.provider.copy(meetingAudioPolicy = policy),
                    )
                }
                "configure_speech" -> {
                    val engine = obj["engine"]?.jsonPrimitive?.content ?: currentSnapshot.speech.engine
                    currentSnapshot.copy(
                        generation = currentSnapshot.generation + 1L,
                        speech = currentSnapshot.speech.copy(engine = engine),
                    )
                }
                "configure_provider" -> {
                    val prev = currentSnapshot.provider
                    val hasQwen = obj["apiKey"]?.jsonPrimitive?.content?.isNotBlank() == true
                    val hasDeepSeek = obj["deepseekApiKey"]?.jsonPrimitive?.content?.isNotBlank() == true
                    val nextQwenConfigured = prev.qwenConfigured || hasQwen
                    val nextDeepSeekConfigured = prev.deepseekConfigured || hasDeepSeek
                    currentSnapshot.copy(
                        generation = currentSnapshot.generation + 1L,
                        provider = prev.copy(
                            configured = nextQwenConfigured || nextDeepSeekConfigured,
                            qwenConfigured = nextQwenConfigured,
                            deepseekConfigured = nextDeepSeekConfigured,
                            asrProvider = obj["asrProvider"]?.jsonPrimitive?.content ?: prev.asrProvider,
                            asrModel = obj["asrModel"]?.jsonPrimitive?.content ?: prev.asrModel,
                            llmProvider = obj["llmProvider"]?.jsonPrimitive?.content ?: prev.llmProvider,
                            model = obj["model"]?.jsonPrimitive?.content ?: prev.model,
                            enableThinking = obj["enableThinking"]?.jsonPrimitive?.boolean ?: prev.enableThinking,
                            qwenWorkspaceId = obj["qwenWorkspaceId"]?.jsonPrimitive?.content ?: prev.qwenWorkspaceId,
                            asrEndpoint = obj["asrEndpoint"]?.jsonPrimitive?.content ?: prev.asrEndpoint,
                            chatEndpoint = obj["chatEndpoint"]?.jsonPrimitive?.content ?: prev.chatEndpoint,
                        ),
                    )
                }
                else -> currentSnapshot.copy(generation = currentSnapshot.generation + 1L)
            }
            return HostJson.json.encodeToString(HostSnapshot.serializer(), currentSnapshot)
        }

        override fun sessionIngestBle(handle: Long, bytes: ByteArray, nowEpochSec: Long): Long =
            currentSnapshot.generation

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
        ): PcmIngestReceipt = PcmIngestReceipt(currentSnapshot.generation, sequence + 1L, PcmIngestStatus.ACCEPTED)

        override fun sessionReportPlaybackProgress(
            handle: Long,
            recordId: String,
            requestId: Long,
            positionMs: Long,
            isPlaying: Boolean,
            lastProjectedNowSec: Long,
            nowEpochSec: Long,
        ): PlaybackProgressReceipt = PlaybackProgressReceipt(
            generation = currentSnapshot.generation,
            prevGeneration = currentSnapshot.generation,
            positionMs = positionMs,
            nowEpochSec = nowEpochSec,
            isPlaying = isPlaying,
            applied = true,
            needsFullSnapshot = false,
        )

        override fun sessionDrainBleTx(handle: Long): ByteArray = ByteArray(0)

        override fun sessionDrainLocalAsr(handle: Long): ByteArray = ByteArray(0)

        override fun sessionPollTimers(handle: Long, elapsedMs: Long, nowEpochSec: Long): Long =
            currentSnapshot.generation
    }

    private fun loadRichFixtureJson(): String {
        val stream = checkNotNull(javaClass.classLoader?.getResourceAsStream("android-rich-snapshot.json"))
        return stream.use { String(it.readBytes(), StandardCharsets.UTF_8) }
    }

    @Test
    fun fixtureSnapshotRendersDeviceTelemetryDockedCaptureAndAskSourceSheet() {
        val bridge = FakeUiBridgeClient()
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-fixture",
            bridge = bridge,
            allowDebugFixture = true,
        )
        assertTrue(store.loadDebugSnapshotFixtureJson(loadRichFixtureJson()))

        composeRule.setContent {
            KoeTheme {
                KoeRootScreen(store = store)
            }
        }

        composeRule.onNodeWithText("85%", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("模式选择").assertIsDisplayed()
        composeRule.onNodeWithTag("active-capture-bar").assertIsDisplayed()

        composeRule.onNodeWithTag("device-status-pill").performClick()
        composeRule.waitForIdle()
        composeRule.onNode(hasAnyAncestor(isDialog()) and hasText("Soundcore Work")).assertIsDisplayed()
        composeRule.onNode(hasAnyAncestor(isDialog()) and hasText("72%", substring = true)).assertIsDisplayed()
        composeRule.onNode(hasAnyAncestor(isDialog()) and hasText("让出控制权")).assertIsDisplayed()

        composeRule.onNodeWithTag("device-sheet-close").performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()
        composeRule.onNodeWithText("让出控制权").assertDoesNotExist()

        composeRule.onNodeWithText("问 AI").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("[S1]").assertIsDisplayed()

        composeRule.onNodeWithText("查看摘录").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("原文来源").assertIsDisplayed()
        composeRule.onNodeWithText("打开完整记录").assertIsDisplayed()
    }

    @Test
    fun liveQuickNoteDispatchesCreateNoteAndAppearsInRecordsTab() {
        val bridge = FakeUiBridgeClient()
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-live",
            bridge = bridge,
            allowDebugFixture = false,
        )

        composeRule.setContent {
            KoeTheme {
                KoeRootScreen(store = store)
            }
        }

        composeRule.onNodeWithText("模式选择").assertIsDisplayed()
        composeRule.runOnIdle { store.reportNativeError("蓝牙连接已断开") }
        composeRule.onNodeWithTag("quick-note-input").performTextInput("RobolectricSmokeNote")
        composeRule.onNodeWithTag("quick-note-submit").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("quick-note-input").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("")),
        )
        val createCmd = bridge.dispatchedCommands.firstOrNull {
            it["type"]?.jsonPrimitive?.content == "create_note"
        }
        assertTrue("expected create_note command dispatch", createCmd != null)
        assertEquals("RobolectricSmokeNote", createCmd!!["text"]?.jsonPrimitive?.content)
        assertEquals(true, createCmd["stayOnPage"]?.jsonPrimitive?.boolean)

        composeRule.onNodeWithText("记录").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("RobolectricSmokeNote", substring = true).assertIsDisplayed()
    }

    @Test
    fun proposedTasksHaveNoCompletionButton() {
        val snapshot = HostSnapshot.empty.copy(tasks = listOf(TaskSnapshot("t", "评审待办", "proposed")))
        val store = HostSessionStore("/tmp/koe-actions", bridge = FakeUiBridgeClient(snapshot))
        composeRule.setContent { KoeTheme { ActionsScreen(store, onOpenSource = {}) } }
        composeRule.onNodeWithText("评审待办").assertExists()
        composeRule.onNodeWithContentDescription("标记已完成").assertDoesNotExist()
    }

    @Test
    fun proposedItemsDispatchRustReviewDecisions() {
        val snapshot = HostSnapshot.empty.copy(
            tasks = listOf(TaskSnapshot("t", "评审待办", "proposed")),
            memories = listOf(MemorySnapshot("m", "评审记忆", "proposed")),
        )
        val bridge = FakeUiBridgeClient(snapshot)
        val store = HostSessionStore("/tmp/koe-actions", bridge = bridge)
        composeRule.setContent { KoeTheme { ActionsScreen(store, onOpenSource = {}) } }

        composeRule.onNodeWithText("采纳").performClick()
        composeRule.onNodeWithText("忽略").performClick()
        composeRule.onNodeWithText("记忆").performClick()
        composeRule.onNodeWithText("记住").performClick()
        composeRule.onNodeWithText("忽略").performClick()
        val reviews = bridge.dispatchedCommands.map {
            it["itemId"]?.jsonPrimitive?.content to it["decision"]?.jsonPrimitive?.content
        }
        assertEquals(listOf("t" to "accept", "t" to "dismiss", "m" to "accept", "m" to "dismiss"), reviews)
    }

    @Test
    fun androidSpeechSettingsTranslateStateAndHideUnsupportedEngineAfterSwitch() {
        val snapshot = HostSnapshot.empty.copy(generation = 1L)
        val store = HostSessionStore("/tmp/koe-speech", bridge = FakeUiBridgeClient(snapshot))
        composeRule.setContent { KoeTheme { KoeRootScreen(store = store) } }
        composeRule.onNodeWithTag("settings-button").performClick()
        composeRule.onNodeWithText("本机引擎状态：暂不可用").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithTag("settings-speech-cloud").performScrollTo().performSemanticsAction(SemanticsActions.OnClick)
        assertEquals("cloud", store.settings.value.speech.engine)
        composeRule.onNodeWithTag("settings-speech-native").assertDoesNotExist()
        composeRule.onNodeWithText("unavailable", substring = true).assertDoesNotExist()
    }

    @Test
    fun launchPathSanitizersKeepWorkspaceAndFixtureStrictlyInsideFilesDir() {
        val baseDir = Files.createTempDirectory("koe-filesdir-test").toFile()
        try {
            val defaultDir = File(baseDir, KoeApplication.DEFAULT_WORKSPACE_DIR)
            assertEquals(
                File(baseDir, "verify-workspaces/live-1").canonicalFile,
                KoeApplication.resolveSafeWorkspaceDir(baseDir, "verify-workspaces/live-1"),
            )
            assertEquals(defaultDir, KoeApplication.resolveSafeWorkspaceDir(baseDir, "../escape"))
            assertEquals(defaultDir, KoeApplication.resolveSafeWorkspaceDir(baseDir, "/tmp/absolute"))

            val fixture = File(baseDir, "koe-active-fixture.json")
            fixture.writeText("{}", StandardCharsets.UTF_8)
            assertEquals(
                fixture.canonicalFile,
                KoeApplication.resolveSafeFixtureFile(baseDir, "koe-active-fixture.json"),
            )
            assertNull(KoeApplication.resolveSafeFixtureFile(baseDir, "../outside.json"))
            assertNull(KoeApplication.resolveSafeFixtureFile(baseDir, "/etc/hosts"))
        } finally {
            baseDir.deleteRecursively()
        }
    }

    @Test
    fun editableSettingsDispatchesPolicyAndProviderWithoutLeakingSecretToTrace() {
        val bridge = FakeUiBridgeClient()
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-settings",
            bridge = bridge,
            allowDebugFixture = false,
        )

        composeRule.setContent {
            KoeTheme {
                KoeRootScreen(store = store)
            }
        }

        val secretKey = "sk-ds-robolectric-secret-98765"

        composeRule.onNodeWithTag("settings-button").performClick()
        composeRule.waitForIdle()
        composeRule.onNodeWithText("Android").assertIsDisplayed()
        composeRule.onNodeWithText(BuildConfig.KOE_DISTRIBUTION).assertIsDisplayed()

        composeRule.onNodeWithTag("settings-meeting-audio-switch")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        val policyCmd = bridge.dispatchedCommands.firstOrNull {
            it["type"]?.jsonPrimitive?.content == "set_meeting_audio_policy"
        }
        assertTrue("expected set_meeting_audio_policy command", policyCmd != null)
        assertEquals("cloud_allowed", policyCmd!!["policy"]?.jsonPrimitive?.content)

        composeRule.onNodeWithTag("settings-llm-option-deepseek-v4-pro")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.onNodeWithTag("settings-thinking-switch")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.onNodeWithTag("settings-deepseek-key-input")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.RequestFocus)
        composeRule.onNodeWithTag("settings-deepseek-key-input")
            .performTextInput(secretKey)
        composeRule.onNodeWithTag("settings-save-button")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()

        composeRule.onNodeWithText("已保存模型配置").assertIsDisplayed()

        val providerCmd = bridge.dispatchedCommands.lastOrNull {
            it["type"]?.jsonPrimitive?.content == "configure_provider"
        }
        assertTrue("expected configure_provider command", providerCmd != null)
        assertEquals("deepseek-v4-pro", providerCmd!!["model"]?.jsonPrimitive?.content)
        assertEquals(true, providerCmd["enableThinking"]?.jsonPrimitive?.boolean)
        assertEquals(secretKey, providerCmd["deepseekApiKey"]?.jsonPrimitive?.content)

        composeRule.onNodeWithTag("settings-save-button")
            .performScrollTo()
            .performSemanticsAction(SemanticsActions.OnClick)
        composeRule.waitForIdle()
        val secondProviderCmd = bridge.dispatchedCommands.lastOrNull {
            it["type"]?.jsonPrimitive?.content == "configure_provider"
        }
        assertTrue("expected second configure_provider command", secondProviderCmd != null)
        assertFalse("typed API key must clear after save", secondProviderCmd!!.containsKey("deepseekApiKey"))

        val traceJson = store.exportTraceJson()
        assertTrue(traceJson.contains("configure_provider"))
        assertFalse("trace must not contain API secret", traceJson.contains(secretKey))
    }

    @Test
    fun asyncSubmitGuardsPreventDuplicateDispatchAndPreserveNewDraftEdits() {
        val queued = ArrayDeque<Runnable>()
        val bridge = FakeUiBridgeClient()
        val store = HostSessionStore(
            workspacePath = "/tmp/koe-ui-submit-guard",
            bridge = bridge,
            commandExecutor = java.util.concurrent.Executor { queued.addLast(it) },
        )

        composeRule.setContent {
            KoeTheme {
                KoeRootScreen(store = store)
            }
        }
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("quick-note-input").performTextInput("第一条想法")
        composeRule.onNodeWithTag("quick-note-submit").performClick()
        composeRule.onNodeWithTag("quick-note-submit").performClick()
        composeRule.waitForIdle()

        assertEquals("double-tapping QuickNote submit must queue only one command", 1, queued.size)

        composeRule.onNodeWithTag("quick-note-input").performTextInput("补充内容")
        composeRule.waitForIdle()

        while (queued.isNotEmpty()) queued.removeFirst().run()
        composeRule.waitForIdle()

        assertEquals(1, bridge.dispatchedCommands.count { it["type"]?.jsonPrimitive?.content == "create_note" })
        composeRule.onNodeWithTag("quick-note-input").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("第一条想法补充内容")),
        )

        composeRule.onNodeWithTag("tab-ask").performClick()
        composeRule.waitForIdle()

        composeRule.onNodeWithTag("ask-question-input").performTextInput("问题一")
        composeRule.onNodeWithTag("ask-question-submit").performClick()
        composeRule.onNodeWithTag("ask-question-submit").performClick()
        composeRule.waitForIdle()

        assertEquals("double-tapping Ask submit must queue only one command", 1, queued.size)

        composeRule.onNodeWithTag("ask-question-input").performTextInput("追问")
        composeRule.waitForIdle()

        while (queued.isNotEmpty()) queued.removeFirst().run()
        composeRule.waitForIdle()

        assertEquals(1, bridge.dispatchedCommands.count { it["type"]?.jsonPrimitive?.content == "ask" })
        composeRule.onNodeWithTag("ask-question-input").assert(
            SemanticsMatcher.expectValue(SemanticsProperties.EditableText, AnnotatedString("问题一追问")),
        )
    }
}
