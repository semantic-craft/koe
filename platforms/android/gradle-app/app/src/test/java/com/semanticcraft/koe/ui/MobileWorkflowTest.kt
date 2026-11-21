package com.semanticcraft.koe.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Insets
import android.view.View
import android.view.WindowInsets
import android.provider.Settings
import androidx.compose.runtime.mutableStateOf
import androidx.compose.foundation.layout.width
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.dp
import com.semanticcraft.koe.BuildConfig
import com.semanticcraft.koe.core.*
import com.semanticcraft.koe.ui.screens.*
import com.semanticcraft.koe.ui.theme.KoeTheme
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w1024dp-h900dp-mdpi")
class MobileWorkflowTest {
    @get:Rule val ui = createRobolectricComposeRule()
    private val fixture = HostJson.json.decodeFromString<HostSnapshot>(
        checkNotNull(javaClass.getResource("/android-rich-snapshot.json")).readText(),
    )
    private val detail = fixture.detail!!
    private lateinit var bridge: KoeComposeUiTest.FakeUiBridgeClient

    private fun store(snapshot: HostSnapshot = fixture): HostSessionStore {
        bridge = KoeComposeUiTest.FakeUiBridgeClient(snapshot)
        return HostSessionStore("/tmp/koe-mobile-workflow", bridge = bridge)
    }

    private fun click(label: String) = ui.onNodeWithText(label).performSemanticsAction(SemanticsActions.OnClick)
    private fun tap(tag: String) = ui.onNodeWithTag(tag).performSemanticsAction(SemanticsActions.OnClick)
    private fun command(type: String) = bridge.dispatchedCommands.last { it["type"]?.jsonPrimitive?.content == type }
    private fun input(value: String) = ui.onNodeWithTag("editor-value").performTextReplacement(value)

    @Test fun originalTextAndSpeakerEditsKeepTheirSegmentIdentity() {
        val seg = detail.segments.first().copy(isEdited = true, originalText = "修改前的句子")
        val store = store(fixture.copy(detail = detail.copy(segments = listOf(seg))))
        ui.setContent { KoeTheme { RecordDetailScreen(store, detail.id) } }
        click("原文")
        click("改前原文")
        ui.onNodeWithText("修改前的句子").assertExists()
        click("编辑原文")
        input("修订后的原文")
        click("保存")
        assertEquals(seg.id, command("edit_segment_text")["segmentId"]!!.jsonPrimitive.content)
        assertEquals("修订后的原文", command("edit_segment_text")["text"]!!.jsonPrimitive.content)
        click("说话人")
        input("另一位")
        click("仅此段")
        assertEquals("另一位", command("set_segment_speaker")["speaker"]!!.jsonPrimitive.content)
        click("说话人")
        input("周宁")
        click("整条记录")
        val merge = command("rename_speaker")
        assertEquals(seg.speaker, merge["fromSpeaker"]!!.jsonPrimitive.content)
        assertEquals("周宁", merge["toSpeaker"]!!.jsonPrimitive.content)
        tap("segment-time-" + seg.id)
        assertEquals(seg.startMs.toString(), command("seek")["positionMs"]!!.jsonPrimitive.content)
        assertEquals(listOf("seek", "playback"), bridge.dispatchedCommands.takeLast(2).map { it["type"]!!.jsonPrimitive.content })
        assertEquals("true", command("playback")["isPlaying"]!!.jsonPrimitive.content)
    }

    @Test fun staleSummaryAndSourceLeadBackToTranscript() {
        val store = store(fixture.copy(detail = detail.copy(minutesStale = true)))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        click("记录")
        ui.onNode(hasText(detail.title) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
        click("重新整理")
        assertEquals(detail.id, command("summarize")["recordId"]!!.jsonPrimitive.content)
        val source = detail.summary.first().sources.first()
        val list = ui.onNode(hasScrollToIndexAction())
        list.performScrollToNode(hasTestTag("summary-source-" + source.id))
        tap("summary-source-" + source.id)
        assertEquals(source.segmentId, command("open_source")["segmentId"]!!.jsonPrimitive.content)
        list.performScrollToNode(hasText(detail.segments.first().text))
        list.performScrollToIndex(0)
        click("重命名")
        input("新会议名")
        click("保存")
        assertEquals("新会议名", command("rename_record")["title"]!!.jsonPrimitive.content)
        click("问这条记录")
        ui.onNodeWithTag("ask-question-input").assertIsDisplayed()
        assertEquals(detail.id, command("set_ask_scope")["recordId"]!!.jsonPrimitive.content)
    }

    @Test fun archivedDetailCannotBeTrashed() {
        val store = store(fixture.copy(detail = detail.copy(archived = true)))
        ui.setContent { KoeTheme { RecordDetailScreen(store, detail.id) } }
        ui.onNodeWithText("移入回收站").assertIsNotEnabled()
    }

    @Test fun savingDetailCannotBeTrashed() {
        val saving = MicrophoneSnapshot(detail.id, "s", "microphone", "mic", phase = "saving")
        val store = store(fixture.copy(microphone = saving))
        ui.setContent { KoeTheme { RecordDetailScreen(store, detail.id) } }
        ui.onNodeWithText("移入回收站").assertIsNotEnabled()
    }

    @Test fun eligibleDetailReturnsToRecordsAfterTrash() {
        val store = store()
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        click("记录")
        ui.onNode(hasText(detail.title) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
        click("移入回收站")
        assertEquals(detail.id, command("trash_record")["recordId"]!!.jsonPrimitive.content)
        ui.onNodeWithTag("records-search-input").assertExists()
    }

    @Test fun sortingFilteringAndBatchActionsOperateOnVisibleSelection() {
        val rows = listOf(
            RecordSnapshot("a", "第一条", 10, 35, project = "会议"),
            RecordSnapshot("b", "第二条", 20, 10, archived = true),
            RecordSnapshot("c", "第三条", 30, 20),
        )
        val saving = MicrophoneSnapshot("c", "s", "microphone", "mic", phase = "saving")
        val store = store(fixture.copy(records = rows, microphone = saving))
        var exported = emptyList<String>()
        store.bridgeActions = HostBridgeActions(requestExportRecords = { exported = it })
        ui.setContent { KoeTheme { RecordsScreen(store, {}) } }
        fun top(title: String) = ui.onNodeWithText(title).fetchSemanticsNode().boundsInRoot.top
        assertTrue(top("第三条") < top("第一条"))
        click("最新")
        click("最早")
        assertTrue(top("第一条") < top("第三条"))
        click("最早")
        click("最长")
        assertTrue(top("第一条") < top("第三条") && top("第三条") < top("第二条"))
        click("多选")
        rows.forEach { click(it.title) }
        click("批量操作")
        ui.onNode(hasText("移入回收站") and hasAnyAncestor(isPopup())).performClick()
        assertEquals("[\"a\"]", command("batch_trash_records")["recordIds"].toString())
        click("全部项目")
        click("未归类")
        ui.onNodeWithText("已选 2").assertExists()
        tap("records-export-batch-button")
        assertEquals(setOf("b", "c"), exported.toSet())
        click("批量操作")
        click("归档")
        assertEquals("true", command("batch_set_record_archived")["archived"]!!.jsonPrimitive.content)
        click("批量操作")
        click("取消归档")
        assertEquals("false", command("batch_set_record_archived")["archived"]!!.jsonPrimitive.content)
        click("批量操作")
        click("归类到项目")
        ui.onNode(hasText("会议") and hasAnyAncestor(isPopup())).performClick()
        assertEquals("会议", command("batch_set_record_project")["project"]!!.jsonPrimitive.content)
        click("批量操作")
        click("归类到项目")
        click("移回收件箱")
        assertNull(command("batch_set_record_project")["project"])
        click("批量操作")
        click("归类到项目")
        click("新建项目")
        input("研究")
        click("保存")
        assertEquals("研究", command("batch_set_record_project")["project"]!!.jsonPrimitive.content)
    }

    @Test fun dismissedItemsCanBeEditedAndReviewedAgain() {
        val store = store(fixture.copy(tasks = listOf(TaskSnapshot("t", "旧待办", "dismissed")),
            memories = listOf(MemorySnapshot("m", "旧记忆", "dismissed"))))
        ui.setContent { KoeTheme { ActionsScreen(store, {}) } }
        ui.onNodeWithText("旧待办").assertDoesNotExist()
        click("已完成")
        ui.onNodeWithText("旧待办").assertDoesNotExist()
        click("已忽略")
        click("编辑")
        input("新待办")
        ui.onNodeWithTag("editor-due").performTextReplacement("2026-12-01")
        click("保存")
        assertEquals("新待办", command("edit_item")["text"]!!.jsonPrimitive.content)
        assertEquals("2026-12-01", command("edit_item")["due"]!!.jsonPrimitive.content)
        click("重新审核")
        assertEquals("reset", command("review_item")["decision"]!!.jsonPrimitive.content)
        click("记忆")
        click("已忽略")
        click("重新审核")
        assertEquals("m", command("review_item")["itemId"]!!.jsonPrimitive.content)
    }

    @Config(qualifiers = "w1024dp-h460dp-land-mdpi")
    @Test fun askScopesArbitraryRecordCopiesLatestAnswerAndFitsAboveDock() {
        val messages = (1..30).map { AskMessageSnapshot("q" + it, "assistant", "回答" + it) }
        val store = store(fixture.copy(ask = AskSnapshot(messages = messages)))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        click("问 AI")
        click("选择记录")
        click(fixture.records.last().title)
        assertEquals(fixture.records.last().id, command("set_ask_scope")["recordId"]!!.jsonPrimitive.content)
        ui.onNodeWithText("回答30").assertIsDisplayed()
        tap("copy-q30")
        val clipboard = ui.activity.getSystemService(ClipboardManager::class.java)
        assertEquals("回答30", clipboard.primaryClip!!.getItemAt(0).text.toString())
        val input = ui.onNodeWithTag("ask-question-input")
        input.performTextInput("第一行\n第二行")
        assertTrue(input.fetchSemanticsNode().boundsInRoot.bottom <=
            minOf(ui.onNodeWithTag("active-capture-bar").fetchSemanticsNode().boundsInRoot.top,
                ui.onNodeWithTag("live-caption-bar").fetchSemanticsNode().boundsInRoot.top))
        val width = input.fetchSemanticsNode().boundsInRoot.width
        assertTrue(width < 840 * ui.activity.resources.displayMetrics.density)
    }

    @Config(qualifiers = "w1024dp-h460dp-land-mdpi")
    @Test fun tallLandscapeKeyboardLeavesTheComposerAboveItsTopEdge() {
        val store = store()
        lateinit var hostView: View
        ui.setContent {
            hostView = LocalView.current
            KoeTheme { KoeRootScreen(store) }
        }
        click("问 AI")
        ui.onNodeWithTag("ask-question-input").performTextInput("横屏输入")
        val keyboardTop = with(ui.density) { 72.dp.toPx() }
        ui.runOnIdle {
            val keyboard = WindowInsets.Builder()
                .setInsets(WindowInsets.Type.ime(), Insets.of(0, 0, 0, hostView.height - keyboardTop.toInt()))
                .setVisible(WindowInsets.Type.ime(), true)
                .build()
            hostView.dispatchApplyWindowInsets(keyboard)
        }
        for (tag in listOf("ask-question-input", "ask-question-submit")) {
            val bounds = ui.onNodeWithTag(tag).assertIsDisplayed().fetchSemanticsNode().boundsInRoot
            assertTrue("横屏输入控件应完整位于键盘上方: " + bounds, bounds.height > 0 && bounds.bottom <= keyboardTop)
        }
    }

    @Test fun timestampWithoutAudioShowsErrorInDock() {
        val store = store(fixture.copy(playback = PlaybackSnapshot.empty, detail = detail.copy(audioPath = null)))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        click("记录")
        ui.onNode(hasText(detail.title) and hasAnyAncestor(hasScrollToIndexAction())).performClick()
        click("原文")
        tap("segment-time-" + detail.segments.first().id)
        ui.onNodeWithText("这条记录没有可播放的音频。").assertIsDisplayed()
    }

    @Test fun detailReviewsTasksAndMemoriesWithTheirSources() {
        val source = detail.summary.first().sources.first()
        val store = store(fixture.copy(detail = detail.copy(summary = emptyList()), tasks = listOf(
            TaskSnapshot("review-task", "待完成的行动", "accepted", sources = listOf(source))),
            memories = listOf(MemorySnapshot("review-memory", "应记住的事实", "accepted", sources = listOf(source)))))
        ui.setContent { KoeTheme { RecordDetailScreen(store, detail.id) } }
        val list = ui.onNode(hasScrollToIndexAction())
        list.performScrollToNode(hasText("待完成的行动"))
        ui.onNodeWithContentDescription("标记已完成").performClick()
        assertEquals("true", command("complete_task")["completed"]!!.jsonPrimitive.content)
        list.performScrollToNode(hasText("应记住的事实"))
        click("忽略")
        assertEquals("review-memory", command("review_item")["itemId"]!!.jsonPrimitive.content)
        assertEquals("dismiss", command("review_item")["decision"]!!.jsonPrimitive.content)
    }

    @Test fun settingsRespectDistributionAndLaunchSystemDestinations() {
        val store = store(fixture.copy(platform = fixture.platform.copy(supportsSelfUpdate = BuildConfig.ALLOW_SELF_UPDATE),
            appUpdate = fixture.appUpdate.copy(availableVersion = "2.7", releaseNotes = "新增会议编辑"),
            provider = fixture.provider.copy(model = "private-provider-data")))
        val permissionState = shadowOf(ui.activity.application)
        permissionState.grantPermissions(Manifest.permission.RECORD_AUDIO)
        permissionState.denyPermissions(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.POST_NOTIFICATIONS)
        store.send(HostCommand.ConfigureProvider(model = "private-provider-data", apiKey = "test-only-marker"))
        ui.setContent { KoeTheme { SettingsSheet(store, {}) } }
        ui.onAllNodesWithText("已授权").assertCountEquals(1)
        ui.onAllNodesWithText("未授权").assertCountEquals(2)
        ui.onNodeWithText("Koe " + fixture.appUpdate.currentVersion + "（构建 " + fixture.appUpdate.currentBuild + "）").assertExists()
        for (permission in listOf("麦克风", "蓝牙", "通知")) ui.onNodeWithText(permission).assertExists()
        if (BuildConfig.ALLOW_SELF_UPDATE) {
            click("检查更新")
            command("check_app_update")
            ui.onNodeWithText("新增会议编辑").assertExists()
            click("下载更新")
            assertEquals(Intent.ACTION_VIEW, shadowOf(ui.activity).nextStartedActivity.action)
        } else {
            ui.onNodeWithText("由 Google Play 管理更新").assertExists()
            ui.onNodeWithText("检查更新").assertDoesNotExist()
        }
        click("打开系统设置")
        val settings = shadowOf(ui.activity).nextStartedActivity
        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, settings.action)
        assertEquals(ui.activity.packageName, settings.data?.schemeSpecificPart)
        click("分享诊断日志")
        val chooser = shadowOf(ui.activity).nextStartedActivity
        val share = chooser.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)!!
        assertEquals(Intent.ACTION_SEND, share.action)
        val report = share.getStringExtra(Intent.EXTRA_TEXT)!!
        assertTrue(report.contains("generation"))
        assertTrue(report.contains("configure_provider"))
        assertFalse(report.contains("private-provider-data"))
        assertFalse(report.contains("test-only-marker"))
    }

    @Test fun deviceShowsMeasuredProgressAndOpensSyncedRecording() {
        val device = fixture.device.copy(progress = .42, storageUsedRatio = .63, files = listOf(
            DeviceFileSnapshot(1, "已同步", synced = true, recordId = detail.id),
            DeviceFileSnapshot(2, "同步中", downloading = true)))
        val store = store(fixture.copy(device = device))
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        tap("device-status-pill")
        for ((tag, expected) in listOf("transfer-progress" to .42f, "storage-progress" to .63f)) {
            assertEquals(expected, ui.onNodeWithTag(tag).fetchSemanticsNode()
                .config[SemanticsProperties.ProgressBarRangeInfo].current, .001f)
        }
        ui.onNodeWithText("42%").assertExists()
        click("查看记录")
        ui.onNodeWithText("查看记录").assertDoesNotExist()
        assertEquals(detail.id, command("select_record")["recordId"]!!.jsonPrimitive.content)
        assertTrue(ui.onNodeWithTag("android-player-bar").fetchSemanticsNode().boundsInRoot.bottom <=
            minOf(ui.onNodeWithTag("active-capture-bar").fetchSemanticsNode().boundsInRoot.top,
                ui.onNodeWithTag("live-caption-bar").fetchSemanticsNode().boundsInRoot.top))
    }

    @Test fun meetingUsesTwoIndependentColumnsAtSixHundredDp() {
        val store = store()
        val width = mutableStateOf(600.dp)
        ui.setContent { KoeTheme { LiveMinutesWorkspaceScreen(store, {}, {}, {}, {}, Modifier.width(width.value)) } }
        val left = ui.onNodeWithText("实时覆盖率").fetchSemanticsNode().boundsInRoot
        val right = ui.onNodeWithText("实时原文").fetchSemanticsNode().boundsInRoot
        assertTrue("原文应位于纪要右侧", right.left >= left.right)
        ui.runOnIdle { width.value = 599.dp }
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("实时原文"))
        assertTrue(ui.onNodeWithText("实时原文").fetchSemanticsNode().boundsInRoot.left < right.left)
    }
}
