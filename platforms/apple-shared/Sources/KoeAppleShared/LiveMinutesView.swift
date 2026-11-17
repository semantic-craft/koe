import SwiftUI

public struct LiveMinutesView: View {
    public let store: HostSessionStore
    private let onExportWorkspace: (WorkspaceExportRequest) -> Void

    @State private var includeAnalysis = true
    @State private var includeSources = true

    public init(
        store: HostSessionStore,
        onExportWorkspace: @escaping (WorkspaceExportRequest) -> Void = { _ in }
    ) {
        self.store = store
        self.onExportWorkspace = onExportWorkspace
    }

    private var lm: LiveMinutesWorkspaceSnapshot {
        store.liveMinutesWorkspace
    }

    private var activeActions: [CaptureAction] {
        guard lm.isActive else { return [] }
        let actions = store.activeCaptureActions
        return actions.isEmpty ? [.end] : actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerAndControlStrip

                if let recordId = lm.selectedRecordId {
                    selectedMeetingActionStrip(recordId: recordId)
                }

                LiveMinutesCoverageSlotView(store: store)

                if !lm.pastMeetings.isEmpty {
                    pastMeetingsStrip
                }

                if !lm.isActive && lm.selectedRecordId == nil && lm.pastMeetings.isEmpty {
                    KoeCard {
                        EmptyState(
                            icon: "waveform.path.ecg",
                            title: "暂无进行中或往期会议",
                            detail: "开启实时纪要后，这里会并排呈现实时转写与有原文依据的结构化纪要。"
                        )
                    }
                } else {
                    LiveMinutesSplitBody(lm: lm, store: store)
                }
            }
            .padding(30)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .accessibilityIdentifier("live-minutes-page")
    }

    private var headerAndControlStrip: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(
                    title: "实时纪要",
                    subtitle: "会议与深度讨论期间并排对照实时原文与有据纪要，结束后保留完整纪要与行动。"
                )
                HStack(spacing: 10) {
                    KoeBadge(lm.sourceLabel, tint: AppColors.textSecondary)
                    KoeBadge(
                        lm.phaseBadgeLabel,
                        tint: lm.isActive ? AppColors.success : AppColors.textSecondary
                    )
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !lm.isActive {
                    KoeActionButton("开始实时纪要", systemImage: "waveform.path.ecg", isPrimary: true) {
                        store.startCapture(.meeting, stayOnPage: true)
                    }
                    .disabled(!lm.canStart)
                } else {
                    ForEach(activeActions, id: \.self) { action in
                        KoeActionButton(
                            actionLabel(action),
                            systemImage: actionIcon(action),
                            isPrimary: action == .end || action == .resume
                        ) {
                            store.performCaptureAction(action)
                        }
                    }
                }
            }
        }
    }

    private func selectedMeetingActionStrip(recordId: String) -> some View {
        KoeCard {
            HStack(spacing: 10) {
                Text(lm.selectedTitle ?? "当前会议")
                    .font(.system(size: AppFontSizes.md, weight: .semibold))
                    .lineLimit(1)

                if lm.minutesStale {
                    KoeBadge("原文已改，待更新", tint: AppColors.warning)
                }

                Spacer(minLength: 8)

                KoeActionButton(
                    lm.liveSections.isEmpty && lm.finalSections.isEmpty ? "生成完整纪要" : "重新整理",
                    systemImage: "sparkles"
                ) {
                    store.send(.summarize(recordId: recordId))
                }
                .disabled(!lm.canSummarize)

                KoeActionButton("问本场会议", systemImage: "bubble.left.and.text.bubble.right") {
                    store.send(.setAskScope(scope: "record", recordId: recordId))
                    store.send(.navigate(section: "ask"))
                }

                KoeActionButton("完整校对与播放", systemImage: "slider.horizontal.below.rectangle") {
                    store.send(.selectRecord(recordId: recordId))
                }

                Toggle("附带 AI 整理", isOn: $includeAnalysis)
                    .font(.system(size: AppFontSizes.xs))
                    .toggleStyle(.checkbox)
                Toggle("附带来源标签", isOn: $includeSources)
                    .font(.system(size: AppFontSizes.xs))
                    .toggleStyle(.checkbox)

                KoeActionButton("导出纪要", systemImage: "square.and.arrow.up") {
                    onExportWorkspace(
                        WorkspaceExportRequest.forMeeting(
                            recordId: recordId,
                            title: lm.selectedTitle,
                            includeAnalysis: includeAnalysis,
                            includeSources: includeSources
                        )
                    )
                }
            }
        }
    }

    private var pastMeetingsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("往期会议")
                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                .foregroundStyle(AppColors.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(lm.pastMeetings) { meeting in
                        let selected = lm.selectedRecordId == meeting.id
                        Button {
                            store.send(.selectLiveMinutesRecord(recordId: meeting.id))
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(meeting.title)
                                        .font(.system(size: AppFontSizes.sm, weight: selected ? .semibold : .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    KoeBadge(meeting.status, tint: AppColors.textSecondary)
                                }
                                Text("\(TimeLabel.date(meeting.createdAtEpochSec))  \(TimeLabel.duration(meeting.durationMs))")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textMuted)
                                    .monospacedDigit()
                                Text("\(meeting.segmentCount) 段原文  \(meeting.decisionCount) 项决定")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textMuted)
                            }
                            .padding(12)
                            .frame(width: 248, alignment: .leading)
                            .background(
                                selected ? AppColors.accentSoft : AppColors.surface1,
                                in: RoundedRectangle(cornerRadius: AppRadii.cardOuter)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppRadii.cardOuter)
                                    .stroke(selected ? AppColors.accent : AppColors.border)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(lm.isActive)
                    }
                }
            }
        }
    }

    private func actionLabel(_ action: CaptureAction) -> String {
        switch action {
        case .pause: "暂停"
        case .resume: "继续"
        case .end: "结束会议"
        case .retryStop: "重试停止"
        case .retrySave: "重试保存"
        case .cancel: "取消录音"
        }
    }

    private func actionIcon(_ action: CaptureAction) -> String {
        switch action {
        case .pause: "pause.fill"
        case .resume: "play.fill"
        default: "stop.fill"
        }
    }
}
