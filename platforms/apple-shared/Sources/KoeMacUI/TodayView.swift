import SwiftUI

struct TodayView: View {
    let store: HostSessionStore

    var body: some View {
        let today = store.today
        let projected = today.picker?.cards ?? []
        let cards = projected.isEmpty ? ModePickerSnapshot.defaultCards : projected

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeading(
                    title: "模式选择",
                    subtitle: "先确认下方录音音源，再打开模式开关。单按录音豆侧键默认记入随心闪记。"
                )

                sourceStrip(today)

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14),
                        GridItem(.flexible(), spacing: 14)
                    ],
                    spacing: 14
                ) {
                    ForEach(cards) { card in
                        ModePickerCardView(card: card, store: store)
                            .equatable()
                    }
                }

                behaviorRulesCard(today)
            }
            .padding(30)
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func sourceStrip(_ today: TodaySlice) -> some View {
        let picker = today.picker
        let beanBadge = picker?.beanBadge ?? "录音豆 \(today.deviceState)"
        let guidanceText = picker?.guidanceText ?? "当前使用电脑麦克风，也可将录音豆放入充电仓按键连接后再选模式。"
        return KoeCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    KoeBadge(picker?.sourceBadge ?? today.captureSelectedBadge, tint: AppColors.accent)
                    Text(picker?.sourceLabel ?? today.captureSelectedLabel)
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    KoeBadge(
                        beanBadge,
                        tint: beanBadgeTint(today, picker: picker)
                    )
                    Spacer()
                    beanOwnershipSwitch(today, picker: picker)
                        .fixedSize()
                    if picker?.canSwitchToBean == true {
                        KoeActionButton("切换为录音豆", systemImage: "wave.3.right") {
                            store.send(.selectCaptureSource(source: "bean"))
                        }
                    }
                    KoeActionButton("设置音源", systemImage: "slider.horizontal.3") {
                        store.send(.navigate(section: "capture"))
                    }
                }
                Text(guidanceText)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func beanBadgeTint(_ today: TodaySlice, picker: ModePickerSnapshot?) -> Color {
        switch picker?.beanBadgeTone {
        case "success": return AppColors.success
        case "warning": return AppColors.warning
        case "muted": return AppColors.textMuted
        default:
            if today.deviceConnected { return AppColors.success }
            switch store.device.phase {
            case "scanning", "connecting", "handshaking": return AppColors.warning
            default: return AppColors.textMuted
            }
        }
    }

    private func beanOwnershipSwitch(_ today: TodaySlice, picker: ModePickerSnapshot?) -> some View {
        let isMacOwner = (picker?.beanControlOwner ?? "mac") != "phone"
        let canRelease = store.canReleaseToPhone
        return HStack(spacing: 2) {
            OwnershipSegmentButton(title: "Mac 使用", active: isMacOwner) {
                if !isMacOwner {
                    store.send(.deviceOpenGuide)
                    store.bridgeActions.requestBleScan()
                } else if !today.deviceConnected, store.device.phase == "disconnected" {
                    store.bridgeActions.requestBleScan()
                }
            }
            OwnershipSegmentButton(title: "手机接管", active: !isMacOwner) {
                if isMacOwner {
                    store.send(.deviceRelease)
                }
            }
            .disabled(!canRelease)
            .opacity(canRelease ? 1.0 : 0.45)
        }
        .padding(2)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(AppColors.border))
    }

    private func behaviorRulesCard(_ today: TodaySlice) -> some View {
        KoeCard {
            HStack(spacing: 10) {
                KoeActionButton(
                    "浏览所有记录 (\(today.recordCount))",
                    systemImage: "tray.full"
                ) {
                    store.send(.navigate(section: "records"))
                }
                KoeActionButton(
                    "待确认行动 (\(today.proposedActionCount))",
                    systemImage: "checklist"
                ) {
                    store.send(.navigate(section: "tasks"))
                }
                Spacer(minLength: 12)
                Text("进入左侧工作区仅查看内容，不会自动开始录音。")
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
            }
        }
    }
}

private struct ModePickerCardView: View, Equatable {
    let card: ModePickerCardSnapshot
    let store: HostSessionStore

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.card == rhs.card && lhs.store === rhs.store
    }

    private var iconName: String {
        HostSection(rawValue: card.id)?.icon ?? "waveform"
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
                        store.send(.navigate(section: card.id))
                    }
                }
            }
        }
    }
}

private struct OwnershipSegmentButton: View {
    @Environment(\.isFocused) private var isFocused
    let title: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? AppColors.onAccent : AppColors.textSecondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 28)
                .background(
                    active ? AppColors.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: AppRadii.control - 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadii.control - 2)
                        .stroke(isFocused ? AppColors.accent : Color.clear, lineWidth: 1.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
