package com.semanticcraft.koe.ui

import androidx.activity.ComponentActivity
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.semanticcraft.koe.core.*
import com.semanticcraft.koe.ui.leaves.AndroidPlayerBar
import com.semanticcraft.koe.ui.screens.*
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h915dp-xhdpi")
class AndroidSystemUxTest {
    @get:Rule val ui = createAndroidComposeRule<ComponentActivity>()
    private val fixture: HostSnapshot get() {
        val json = checkNotNull(javaClass.getResource("/android-rich-snapshot.json")).readText()
        return HostJson.json.decodeFromString(HostSnapshot.serializer(), json)
    }

    private lateinit var bridge: KoeComposeUiTest.FakeUiBridgeClient
    private fun store(snapshot: HostSnapshot = fixture): HostSessionStore {
        bridge = KoeComposeUiTest.FakeUiBridgeClient(snapshot)
        return HostSessionStore("/tmp/koe-system-ux", bridge = bridge)
    }
    private fun commands(type: String) = bridge.dispatchedCommands.filter { it["type"]?.jsonPrimitive?.content == type }

    @Test fun systemBackPopsRestoredDetailStack() {
        val store = store()
        val state = StateRestorationTester(ui)
        state.setContent { KoeTheme { KoeRootScreen(store) } }
        ui.onNodeWithText("记录").performClick()
        ui.onNode(hasText("Android 架构同步会") and hasClickAction() and hasAnyAncestor(hasScrollAction()))
            .performClick()
        ui.onNodeWithContentDescription("返回").assertExists()
        state.emulateSavedInstanceStateRestore()
        ui.onNodeWithContentDescription("返回").assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        ui.onNodeWithTag("records-search-input").assertIsDisplayed()
        assertFalse(ui.activity.isFinishing)
    }

    @Test fun noticeCanCloseAndMiniPlayerOpensItsRecord() {
        val store = store(fixture.copy(notice = "保存成功"))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        ui.onNodeWithText("保存成功").assertIsDisplayed()
        ui.onNodeWithContentDescription("关闭提示").performClick()
        ui.onNodeWithText("保存成功").assertDoesNotExist()
        ui.onNodeWithContentDescription("开始播放").performClick()
        assertEquals(1, commands("playback").size)
        ui.onNodeWithTag("mini-player-bar").performClick()
        ui.onNodeWithTag("android-player-bar").assertIsDisplayed()
        ui.onNodeWithTag("mini-player-bar").assertDoesNotExist()
    }

    @Test fun confirmationCancelsOrPurgesOnlyAfterConfirming() {
        val store = store(fixture.copy(trashRecords = listOf(TrashRecordSnapshot("old", "旧录音"))))
        ui.setContent { KoeTheme { RecordsScreen(store, {}) } }
        ui.onNodeWithTag("records-trash-button").performClick()
        for ((action, command) in listOf("彻底删除" to "purge_record", "清空" to "empty_trash")) {
            ui.onNodeWithText(action).performScrollTo().performSemanticsAction(SemanticsActions.OnClick)
            assertTrue(commands(command).isEmpty())
            ui.onNodeWithText("取消").performSemanticsAction(SemanticsActions.OnClick)
            ui.onNodeWithText("旧录音").assertExists()
            ui.onNodeWithText(action).performScrollTo().performSemanticsAction(SemanticsActions.OnClick)
            ui.onNodeWithText("确认删除").performSemanticsAction(SemanticsActions.OnClick)
            assertEquals(1, commands(command).size)
        }
    }

    @Test fun protectedRowsCannotSwipeToTrash() {
        val records = listOf(RecordSnapshot("archive", "归档条目", archived = true),
            RecordSnapshot("saving", "保存条目"), RecordSnapshot("busy", "整理条目", status = "整理中"))
        val snapshot = fixture.copy(records = records, microphone = MicrophoneSnapshot("saving", "session", "microphone", "input", phase = "saving"))
        val store = store(snapshot)
        ui.setContent { KoeTheme { RecordsScreen(store, {}) } }
        for (record in records) {
            ui.onNodeWithText(record.title).performTouchInput { swipeLeft() }
            ui.waitForIdle()
            assertTrue(commands("trash_record").isEmpty())
            ui.onNodeWithText(record.title).assertIsDisplayed()
        }
    }

    @Test fun draggingPreviewsBeforeDispatchingOneSeekOnRelease() {
        val store = store()
        ui.setContent { KoeTheme { AndroidPlayerBar(store) } }
        val slider = ui.onNodeWithContentDescription("播放进度")
        slider.performTouchInput {
            down(Offset(width * 0.25f, centerY))
            for (i in 1..20) moveTo(Offset(width * (0.25f + i * 0.025f), centerY))
        }
        assertTrue(commands("seek").isEmpty())
        slider.performTouchInput { up() }
        assertEquals(1, commands("seek").size)
        val position = commands("seek").single()["positionMs"]!!.jsonPrimitive.content.toLong()
        assertTrue(position in 29000..35000)
    }

    @Test fun rotationRetainsSettingsDraftAndDiscardsTypedKey() {
        val store = store()
        val state = StateRestorationTester(ui)
        state.setContent { KoeTheme { SettingsSheet(store, {}) } }
        ui.onNodeWithTag("settings-qwen-workspace-input").performScrollTo().performTextInput("qa-space")
        ui.onNodeWithTag("settings-deepseek-key-input").performScrollTo().performTextInput("test-key")
        state.emulateSavedInstanceStateRestore()
        ui.onNodeWithTag("settings-save-button").performScrollTo().performSemanticsAction(SemanticsActions.OnClick)
        val saved = commands("configure_provider").single()
        assertTrue(saved["qwenWorkspaceId"]!!.jsonPrimitive.content.contains("qa-space"))
        assertFalse(saved.containsKey("deepseekApiKey"))
    }

    @Test fun oldNativeErrorDoesNotKeepSubmittedQuestion() {
        val store = store()
        // A platform adapter can republish an unrelated error while the ask result is delivered.
        store.onSnapshotChanged = { store.reportNativeError("蓝牙连接中断") }
        ui.setContent { KoeTheme { AskScreen(store, {}) } }
        ui.onNodeWithTag("ask-question-input").performTextInput("现在的问题")
        ui.onNodeWithTag("ask-question-submit").performClick()
        assertEquals(1, commands("ask").size)
        ui.onNodeWithTag("ask-question-input").assert(
            SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText,
                androidx.compose.ui.text.AnnotatedString("")),
        )
    }

    @Test fun sourceChipOpensAndScrollsToDistantTranscriptSegment() {
        val base = fixture
        val segments = (1..40).map { SegmentSnapshot("earlier-$it", "先前段落 $it") } + base.detail!!.segments
        val store = store(base.copy(detail = base.detail.copy(segments = segments), focusSegmentId = "seg-1"))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        ui.onNodeWithText("问 AI").performClick()
        ui.onNodeWithTag("ask-source-chip-1").performClick()
        assertEquals("seg-1", commands("open_source").single()["segmentId"]?.jsonPrimitive?.content)
        ui.onNodeWithText("定位段落").assertIsDisplayed()
        ui.onNodeWithText(segments[40].text).assertIsDisplayed()
    }
}
