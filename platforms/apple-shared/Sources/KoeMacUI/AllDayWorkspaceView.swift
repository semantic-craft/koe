import SwiftUI

public struct AllDayWorkspaceView: View {
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

    private var allDay: AllDayWorkspaceSnapshot {
        store.allDayWorkspace
    }

    private var metricsSummaryText: String {
        "已录 \(TimeLabel.duration(allDay.totalRecordedMs))  事件 \(allDay.eventCount)  暂停 \(allDay.pauseCount)  空档 \(allDay.gapCount)"
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerAndControlStrip
                dateAndExportStrip

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        timelineColumn.frame(minWidth: 440, maxWidth: .infinity)
                        AllDayReviewColumn(allDay: allDay, store: store)
                            .frame(minWidth: 360, maxWidth: 420)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        timelineColumn
                        AllDayReviewColumn(allDay: allDay, store: store)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var headerAndControlStrip: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(
                    title: "全天听记",
                    subtitle: "跨时段连续记录，按语义事件、暂停区间与未录音空档诚实回看全天脉络。"
                )
                HStack(spacing: 10) {
                    KoeBadge(allDay.sourceLabel, tint: AppColors.textSecondary)
                    if allDay.isPaused {
                        KoeBadge("已暂停", tint: AppColors.warning)
                    } else if allDay.isActive {
                        KoeBadge("听记中", tint: AppColors.success)
                    }
                    Text(metricsSummaryText)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .monospacedDigit()
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !allDay.isActive {
                    KoeActionButton("开启全天听记", systemImage: CaptureMode.allDay.icon, isPrimary: true) {
                        store.startCapture(.allDay, stayOnPage: true)
                    }
                    .disabled(!allDay.canStart)
                } else {
                    if allDay.canPause {
                        KoeActionButton("暂停", systemImage: "pause.fill") {
                            store.performCaptureAction(.pause)
                        }
                    }
                    if allDay.canResume {
                        KoeActionButton("继续", systemImage: "play.fill", isPrimary: true) {
                            store.performCaptureAction(.resume)
                        }
                    }
                    KoeActionButton("结束全天听记", systemImage: "stop.fill", isPrimary: !allDay.canResume) {
                        store.performCaptureAction(.end)
                    }
                }
            }
        }
    }

    private var dateAndExportStrip: some View {
        KoeCard {
            HStack(spacing: 10) {
                Text("日期")
                    .font(.system(size: AppFontSizes.xs, weight: .medium))
                    .foregroundStyle(AppColors.textMuted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let dates = allDay.availableDates.isEmpty ? [allDay.selectedDate] : allDay.availableDates
                        ForEach(dates, id: \.self) { date in
                            let selected = date == allDay.selectedDate
                            Button {
                                store.send(.selectAllDayDate(date: date))
                            } label: {
                                Text(date)
                                    .font(.system(size: AppFontSizes.xs, weight: selected ? .medium : .regular))
                                    .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                                    .monospacedDigit()
                                    .padding(.horizontal, 12)
                                    .frame(minHeight: 30)
                                    .background(
                                        selected ? AppColors.accentSoft : AppColors.bgSubtle,
                                        in: RoundedRectangle(cornerRadius: AppRadii.control)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppRadii.control)
                                            .stroke(selected ? AppColors.accent.opacity(0.35) : AppColors.border)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer(minLength: 8)

                Toggle("附带 AI 整理", isOn: $includeAnalysis)
                    .font(.system(size: AppFontSizes.xs))
                    .toggleStyle(.checkbox)
                Toggle("附带来源标签", isOn: $includeSources)
                    .font(.system(size: AppFontSizes.xs))
                    .toggleStyle(.checkbox)
                KoeActionButton("导出当日记录", systemImage: "square.and.arrow.up") {
                    onExportWorkspace(
                        WorkspaceExportRequest.forAllDay(
                            date: allDay.selectedDate,
                            includeAnalysis: includeAnalysis,
                            includeSources: includeSources
                        )
                    )
                }
            }
        }
    }

    private var timelineColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全天时间轴")
                .font(.system(size: AppFontSizes.md, weight: .semibold))

            if allDay.spans.isEmpty {
                KoeCard {
                    EmptyState(
                        icon: CaptureMode.allDay.icon,
                        title: "当日还没有全天听记内容",
                        detail: "开启全天听记后，这里会按语义事件聚合展示当天对话，并诚实标出暂停与未录音区间。"
                    )
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(allDay.spans) { span in
                        switch span.kind {
                        case "event":
                            AllDayEventSpanCard(span: span, store: store)
                        case "pause":
                            AllDayIntervalMarkerRow(
                                icon: "pause.circle",
                                tint: AppColors.warning,
                                text: span.statusSummaryLabel
                            )
                        default:
                            AllDayIntervalMarkerRow(
                                icon: "clock.badge.questionmark",
                                tint: AppColors.textMuted,
                                text: span.statusSummaryLabel
                            )
                        }
                    }
                }
            }
        }
    }
}
