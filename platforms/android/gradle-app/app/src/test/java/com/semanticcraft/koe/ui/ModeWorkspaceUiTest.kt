package com.semanticcraft.koe.ui

import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.*
import com.semanticcraft.koe.core.*
import com.semanticcraft.koe.ui.screens.KoeRootScreen
import com.semanticcraft.koe.ui.theme.KoeTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w412dp-h915dp-xhdpi")
class ModeWorkspaceUiTest {
    @get:Rule val ui = createRobolectricComposeRule()
    private lateinit var bridge: KoeComposeUiTest.FakeUiBridgeClient
    private val source = SourceSnapshot("rec", "seg", "预算出处", "预算已通过")
    private val task = WorkspaceSourcedItemSnapshot("t", "task", "核对预算", "proposed", sources = listOf(source))
    private val studio = CaptureStudioSnapshot(
        inputs = listOf(AudioInputSnapshot("usb", "input:mic-42", "桌面话筒", badge = "USB", isDefault = true)),
        audioStorage = AudioStorageSnapshot("audio", 2_000_000, 7),
    )

    private fun render(snapshot: HostSnapshot): HostSessionStore {
        bridge = KoeComposeUiTest.FakeUiBridgeClient(snapshot.copy(generation = 1))
        val store = HostSessionStore("/tmp/koe-m7-ui", bridge = bridge)
        ui.setContent { KoeTheme { KoeRootScreen(store) } }
        return store
    }

    private fun enter(mode: CaptureMode, workspaces: ModeWorkspacesSnapshot, error: String? = null): HostSessionStore {
        val card = ModePickerSnapshot.defaultCards.single { it.mode == mode.rawValue }
        val store = render(HostSnapshot.empty.copy(
            workspaces = workspaces.copy(picker = ModePickerSnapshot(cards = listOf(card))), error = error,
        ))
        find(hasText("进入工作区")).performClick()
        return store
    }

    private fun find(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(matcher)
        return ui.onNode(matcher)
    }

    private fun click(label: String) = find(hasText(label)).performClick()
    private fun command(expected: HostCommand) {
        assertEquals(HostJson.json.parseToJsonElement(expected.toJsonString()), bridge.dispatchedCommands.last())
    }

    @Test fun chooseEverySourceAndReadStorage() {
        render(HostSnapshot.empty.copy(capture = studio))
        ui.onNodeWithTag("today-capture-source-button").performClick()
        for (key in listOf("auto", "bean", "input:mic-42")) {
            ui.onNodeWithTag("source-" + key).performScrollTo().assertIsDisplayed().performSemanticsAction(SemanticsActions.OnClick)
            command(HostCommand.SelectCaptureSource(key))
        }
        ui.onNodeWithText("USB  |  默认", substring = true).assertExists()
        ui.onNodeWithText("7 个", substring = true).assertExists()
        ui.onNodeWithText("MB", substring = true).assertExists()
    }

    @Test fun activeRecordingLocksAllSources() {
        render(HostSnapshot.empty.copy(capture = studio, activeCapture = ActiveCaptureSnapshot(
            CaptureMode.MEETING, "recording", "桌面话筒",
        )))
        ui.onNodeWithTag("today-capture-source-button").performClick()
        ui.onNodeWithText("正在录音", substring = true).assertExists()
        listOf("auto", "bean", "input:mic-42").forEach { ui.onNodeWithTag("source-" + it).assertIsNotEnabled() }
    }

    private val live = LiveMinutesWorkspaceSnapshot(
        selectedRecordId = "current", selectedTitle = "预算会", minutesStale = true, canSummarize = true,
        segments = listOf(SegmentSnapshot("seg", "会议原文", speaker = "王宁")), drafts = listOf("增量草稿"),
        liveSections = listOf(SummarySnapshot("讨论", "实时要点", listOf(source))),
        finalSections = listOf(SummarySnapshot("结论", "终版要点")),
        error = "转写连接失败", actionItems = listOf(task, task.copy(id = "a", state = "accepted")),
        pastMeetings = listOf(PastMeetingSnapshot("old", "上周会议")),
    )

    @Test fun meetingVersionsTranscriptReviewAndSources() {
        val store = enter(CaptureMode.MEETING, ModeWorkspacesSnapshot(liveMinutes = live))
        var exported: WorkspaceExportOptions? = null
        store.bridgeActions = HostBridgeActions(requestExportWorkspace = { recordId, _, _, options ->
            assertEquals("current", recordId)
            exported = options
        })
        find(hasText("终版要点")).assertIsDisplayed()
        click("实时纪要草稿")
        find(hasText("实时要点")).assertIsDisplayed()
        find(hasText("会议原文")).assertIsDisplayed()
        find(hasText("增量草稿")).assertIsDisplayed()
        find(hasText("王宁", substring = true)).assertIsDisplayed()
        click("重新生成")
        command(HostCommand.Summarize("current"))
        find(hasTestTag("review-accept-t")).performClick()
        command(HostCommand.ReviewItem("t", ReviewDecision.ACCEPT))
        ui.onNodeWithTag("complete-t").assertDoesNotExist()
        find(hasTestTag("review-dismiss-t")).performClick()
        command(HostCommand.ReviewItem("t", ReviewDecision.DISMISS))
        find(hasTestTag("complete-a")).performClick()
        command(HostCommand.CompleteTask("a", true))
        find(hasTestTag("review-reset-a")).performClick()
        command(HostCommand.ReviewItem("a", ReviewDecision.RESET))
        click("附带来源引用")
        click("导出会议 Markdown")
        assertEquals(WorkspaceExportOptions(includeSources = false), exported)
        click("上周会议")
        command(HostCommand.SelectLiveMinutesRecord("old"))
        click("实时纪要草稿")
        val citation = hasTestTag("minutes-source-rec:seg")
        find(citation).performClick()
        command(HostCommand.OpenSource("rec", "seg"))
    }

    @Test fun activeMeetingKeepsSelectionAndShowsSettingsForMissingModel() {
        enter(CaptureMode.MEETING, ModeWorkspacesSnapshot(liveMinutes = live.copy(isActive = true)))
        find(hasText("上周会议")).assertIsNotEnabled()
        find(hasText("转写连接失败")).assertIsDisplayed()
        find(hasText("未配置模型")).assertIsDisplayed()
        click("配置模型")
        ui.onNodeWithTag("settings-sheet-close").assertExists()
    }

    private val quick = QuickNoteWorkspaceSnapshot(
        selectedRecordId = "q", projects = listOf(QuickNoteProjectCountSnapshot("研发", 1)),
        cards = listOf(QuickNoteCardSnapshot("q", "第一条", gist = "闪记摘要",
            topics = listOf(QuickNoteTopicSnapshot("预算主题", "预算细节", listOf(source))),
            nextSteps = listOf(task), segments = listOf(SegmentSnapshot("q-seg", "闪记原文"))),
            QuickNoteCardSnapshot("q2", "第二条")),
    )

    @Test fun failedInlineNoteKeepsItsDraft() {
        enter(CaptureMode.QUICK_NOTE, ModeWorkspacesSnapshot(quickNote = quick), error = "写入失败")
        find(hasTestTag("quick-note-input")).performTextInput("保留文字")
        find(hasTestTag("quick-note-submit")).performClick()
        command(HostCommand.CreateNote("保留文字", "保留文字", stayOnPage = true))
        ui.onNodeWithTag("quick-note-input").assertTextContains("保留文字")
    }

    @Test fun selectInlineNoteAndFollowTopicSource() {
        val store = enter(CaptureMode.QUICK_NOTE, ModeWorkspacesSnapshot(quickNote = quick))
        var exported: WorkspaceExportOptions? = null
        store.bridgeActions = HostBridgeActions(requestExportWorkspace = { id, _, _, options ->
            assertEquals("q", id)
            exported = options
        })
        click("第一条")
        command(HostCommand.SelectQuickNoteRecord("q"))
        find(hasText("闪记原文")).assertIsDisplayed()
        find(hasText("预算主题")).assertIsDisplayed()
        find(hasText("核对预算")).assertIsDisplayed()
        find(hasTestTag("review-accept-t")).performClick()
        command(HostCommand.ReviewItem("t", ReviewDecision.ACCEPT))
        click("附带 AI 分析")
        click("附带来源引用")
        click("导出闪记 Markdown")
        assertEquals(WorkspaceExportOptions(false, false), exported)
        find(hasTestTag("topic-source-rec:seg")).performClick()
        command(HostCommand.OpenSource("rec", "seg"))
    }

    @Test fun assignSingleAndBatchToExistingNewOrInbox() {
        enter(CaptureMode.QUICK_NOTE, ModeWorkspacesSnapshot(quickNote = quick))
        find(hasTestTag("assign-q")).performClick()
        ui.onNodeWithText("研发").performSemanticsAction(SemanticsActions.OnClick)
        command(HostCommand.SetRecordProject("q", "研发"))
        click("批量归类")
        click("第一条")
        click("第二条")
        click("归类所选")
        ui.onNodeWithTag("project-name").performTextInput("调研")
        ui.onNodeWithText("使用新项目").performSemanticsAction(SemanticsActions.OnClick)
        command(HostCommand.BatchSetRecordProject(listOf("q", "q2"), "调研"))
        find(hasTestTag("assign-q")).performClick()
        ui.onNodeWithText("移回收件箱").performSemanticsAction(SemanticsActions.OnClick)
        command(HostCommand.SetRecordProject("q", null))
    }

    @Test fun dailyReviewAndTimelineNavigateToExactSegment() {
        val spans = listOf(AllDaySpanSnapshot("event", "e", "午间讨论", recordId = "fallback", firstSegment = source,
            speakers = listOf("王宁"), summaryPoints = listOf("审批预算")),
            AllDaySpanSnapshot("pause", "p"), AllDaySpanSnapshot("unrecorded_gap", "g"))
        val day = AllDayWorkspaceSnapshot(spans = spans, dailyReview = AllDayDailyReviewSnapshot("今日概览", listOf("亮点")),
            reviewTasks = listOf(task), reviewMemories = listOf(task.copy(id = "m", kind = "memory", text = "记忆")),
            reviewDecisions = listOf(AllDayDecisionSnapshot("d", "rec", "确认支出", listOf(source))))
        enter(CaptureMode.ALL_DAY, ModeWorkspacesSnapshot(allDay = day))
        for (label in listOf("今日概览", "亮点", "确认支出", "记忆", "审批预算")) find(hasText(label)).assertExists()
        find(hasTestTag("review-dismiss-m")).performClick()
        command(HostCommand.ReviewItem("m", ReviewDecision.DISMISS))
        for (id in listOf("p", "g")) {
            val height = find(hasTestTag("span-" + id)).getUnclippedBoundsInRoot().let { it.bottom - it.top }
            org.junit.Assert.assertTrue("separator height " + height, height.value < 64f)
        }
        click("定位原文")
        command(HostCommand.OpenSource("rec", "seg"))
    }

    @Test fun dailyExportAllowsIndependentOptions() {
        val store = enter(CaptureMode.ALL_DAY, ModeWorkspacesSnapshot(allDay = AllDayWorkspaceSnapshot(selectedDate = "2026-11-21")))
        var exported: WorkspaceExportOptions? = null
        store.bridgeActions = HostBridgeActions(requestExportWorkspace = { _, date, _, options ->
            assertEquals("2026-11-21", date)
            exported = options
        })
        click("附带 AI 分析")
        find(hasText("附带 AI 分析")).assertIsOff()
        find(hasText("附带来源引用")).assertIsOn()
        click("导出当日")
        assertEquals(WorkspaceExportOptions(includeAnalysis = false), exported)
    }
}
