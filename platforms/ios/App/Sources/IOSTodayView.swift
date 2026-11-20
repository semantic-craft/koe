import KoeAppleCore
import SwiftUI

struct IOSTodayView: View {
    let store: HostSessionStore
    let onOpenWorkspace: (IOSModeWorkspaceRoute) -> Void

    @State private var quickNoteDraft = ""
    @FocusState private var isQuickNoteFocused: Bool

    var body: some View {
        let today = store.today
        let cards = (today.picker?.cards.isEmpty == false ? today.picker?.cards : nil)
            ?? ModePickerSnapshot.defaultCards

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(today)
                quickFlashNoteCard
                VStack(spacing: 12) {
                    ForEach(cards) { card in
                        modeCard(card)
                    }
                }
            }
            .padding(16)
        }
        .background(IOSColors.bgPanel)
        .navigationTitle("今天")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func headerSection(_ today: TodaySlice) -> some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("模式选择")
                        .font(.system(size: AppFontSizes.lg, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    IOSInfoTip(
                        "三种模式共享本地录音与转写引擎，按场景独立组织内容。进入工作区不会自动开始录音。",
                        title: "模式说明"
                    )
                    Spacer()
                    IOSBadge(
                        today.picker?.sourceBadge ?? today.captureSelectedBadge,
                        tint: IOSColors.accent
                    )
                }
                Text(today.picker?.sourceLabel ?? today.captureSelectedLabel)
                    .font(.system(size: AppFontSizes.sm, weight: .medium))
                    .foregroundStyle(IOSColors.textSecondary)
                Text("共 \(today.recordCount) 条记录  |  待确认行动 \(today.proposedActionCount) 项")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textMuted)
                    .monospacedDigit()
            }
        }
    }

    private var quickFlashNoteCard: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.accent)
                    Text("快速文字闪记")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    Spacer()
                    IOSInfoTip(
                        "输入文字后按回车或点击保存闪记，将直接写入本地 Rust 工作区。",
                        title: "文字闪记"
                    )
                }

                HStack(spacing: 8) {
                    TextField("快速记下一段想法…", text: $quickNoteDraft)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                        .overlay(
                            RoundedRectangle(cornerRadius: IOSRadii.control)
                                .stroke(IOSColors.border, lineWidth: 1)
                        )
                        .submitLabel(.done)
                        .focused($isQuickNoteFocused)
                        .accessibilityIdentifier("quick-note-input")
                        .onSubmit {
                            submitQuickNote()
                        }

                    IOSPrimaryButton("保存闪记", isPrimary: true) {
                        submitQuickNote()
                    }
                    .disabled(quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quick-note-submit")
                }
            }
        }
    }

    private func modeCard(_ card: ModePickerCardSnapshot) -> some View {
        let route = workspaceRoute(for: card.id)
        let iconName = HostSection(rawValue: card.id)?.icon ?? "waveform"
        return IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: AppFontSizes.md))
                        .foregroundStyle(IOSColors.accent)
                        .frame(width: 34, height: 34)
                        .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(card.title)
                                .font(.system(size: AppFontSizes.md, weight: .semibold))
                                .foregroundStyle(IOSColors.textPrimary)
                            IOSBadge(
                                card.statusBadge,
                                tint: card.isSessionActive ? IOSColors.success : IOSColors.textSecondary
                            )
                        }
                        Text(card.metricText)
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(IOSColors.textMuted)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    IOSInfoTip(card.subtitle, title: card.title)
                }

                Text(card.subtitle)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(IOSColors.textSecondary)
                    .lineLimit(2)

                HStack(spacing: 10) {
                    Toggle(
                        card.isSessionActive ? "录音中" : "待机",
                        isOn: Binding(
                            get: { card.isSessionActive },
                            set: { _ in store.toggleModeSession(card) }
                        )
                    )
                    .font(.system(size: AppFontSizes.xs, weight: .medium))
                    .foregroundStyle(IOSColors.textSecondary)
                    .disabled(!card.canToggleSession)
                    .accessibilityLabel("\(card.title)录音开关")

                    Spacer(minLength: 4)

                    IOSPrimaryButton(
                        "进入工作区",
                        systemImage: "arrow.right",
                        isPrimary: card.isSessionActive
                    ) {
                        onOpenWorkspace(route)
                    }
                }
            }
        }
    }

    private func workspaceRoute(for cardId: String) -> IOSModeWorkspaceRoute {
        switch cardId {
        case HostSection.allDay.rawValue: .allDay
        case HostSection.liveMinutes.rawValue: .liveMinutes
        default: .quickNote
        }
    }

    private func submitQuickNote() {
        let trimmed = quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let title = String(trimmed.prefix(24))
        isQuickNoteFocused = false
        store.send(.createNote(title: title, text: trimmed, stayOnPage: true))
        if store.navigation.effectiveError == nil {
            quickNoteDraft = ""
        }
    }
}
