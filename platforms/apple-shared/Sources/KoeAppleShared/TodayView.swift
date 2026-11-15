import SwiftUI

struct TodayView: View {
    let store: HostSessionStore

    private var cards: [ModePickerCardSnapshot] {
        let projected = store.snapshot.workspaces?.picker.cards ?? []
        return projected.isEmpty ? ModePickerSnapshot.defaultCards : projected
    }

    private var proposedActionCount: Int {
        store.snapshot.tasks.filter { $0.state == "proposed" }.count
            + store.snapshot.memories.filter { $0.state == "proposed" }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(
                    title: "模式选择",
                    subtitle: "选择工作模式进入对应工作区，或直接切换模式会话开关。"
                )

                sourceStrip

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(cards) { card in
                        ModePickerCardView(card: card, store: store)
                    }
                }

                behaviorRulesCard
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var sourceStrip: some View {
        HStack(spacing: 10) {
            KoeBadge(store.snapshot.capture.selectedBadge, tint: AppColors.accent)
            Text(store.snapshot.capture.selectedLabel)
                .font(.system(size: AppFontSizes.sm, weight: .medium))
            Text(store.snapshot.device.state)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
            Spacer()
            if !store.snapshot.device.connected {
                KoeActionButton("连接录音豆", systemImage: "dot.radiowaves.left.and.right") {
                    store.send("device_open_guide")
                }
            }
            KoeActionButton("设置音源", systemImage: "slider.horizontal.3") {
                store.send("navigate", ["section": "capture"])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border))
    }

    private var behaviorRulesCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("录音与导航约定")
                    .font(.system(size: AppFontSizes.sm, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ruleLine("进入左侧任意工作区仅查看内容，不会自动开始录音或改写硬件路由。")
                    ruleLine("录音豆单按默认记入随心闪记；全天听记、实时纪要与语音输入通过上方开关按会话启用。")
                    ruleLine("应用重启后不会自动恢复上次录音会话，避免后台静默收音。")
                }
                HStack(spacing: 10) {
                    KoeActionButton("浏览所有记录（\(store.snapshot.records.count)）", systemImage: "tray.full") {
                        store.send("navigate", ["section": "records"])
                    }
                    KoeActionButton(
                        proposedActionCount > 0 ? "待确认行动（\(proposedActionCount)）" : "查看行动与记忆",
                        systemImage: "checklist"
                    ) {
                        store.send("navigate", ["section": "tasks"])
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }

    private func ruleLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textMuted)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
        }
    }
}

private struct ModePickerCardView: View {
    let card: ModePickerCardSnapshot
    let store: HostSessionStore

    private var iconName: String {
        switch card.id {
        case "notes": "bolt.horizontal"
        case "all_day": "clock"
        case "live_minutes": "waveform.path.ecg"
        case "voice_input": "character.cursor.ibeam"
        default: "waveform"
        }
    }

    var body: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: AppFontSizes.md))
                        .foregroundStyle(AppColors.accent)
                        .frame(width: 32, height: 32)
                        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: 8))
                    Text(card.title)
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                    KoeBadge(
                        card.statusBadge,
                        tint: card.isSessionActive ? AppColors.success : AppColors.textSecondary
                    )
                    Spacer(minLength: 6)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { card.isSessionActive },
                            set: { _ in store.toggleModeSession(card) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!card.canToggleSession)
                    .accessibilityLabel("\(card.title)会话开关")
                }

                Text(card.subtitle)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                    .lineLimit(2)

                HStack(alignment: .center, spacing: 10) {
                    Text(card.metricText)
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    KoeActionButton("进入工作区", systemImage: "arrow.right", isPrimary: card.isSessionActive) {
                        store.send("navigate", ["section": card.id])
                    }
                }
            }
        }
    }
}

struct NotesView: View {
    let store: HostSessionStore

    var body: some View {
        let workspace = store.snapshot.workspaces?.quickNote ?? .empty
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "随心闪记", subtitle: "想到就记，原文优先，收件箱与项目自由归类。")
                if workspace.cards.isEmpty {
                    EmptyState(icon: "bolt.horizontal", title: "还没有闪记", detail: "新建文字记录或使用随心闪记录下的内容会出现在这里。")
                } else {
                    ForEach(workspace.cards) { card in
                        Button { store.send("select_record", ["recordId": card.id]) } label: {
                            KoeCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(card.title).font(.system(size: AppFontSizes.md, weight: .semibold))
                                    Text(card.gist ?? card.segments.first?.text ?? card.status)
                                        .font(.system(size: AppFontSizes.sm))
                                        .foregroundStyle(AppColors.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

struct AllDayPlaceholderView: View {
    let store: HostSessionStore

    var body: some View {
        let allDay = store.snapshot.workspaces?.allDay ?? .empty
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(title: "全天听记", subtitle: "按事件回看全天对话，自动标记暂停与未录音空档。")
                KoeCard {
                    Text("日期 \(allDay.selectedDate)  共 \(allDay.eventCount) 个事件")
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(AppColors.textSecondary)
                }
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
