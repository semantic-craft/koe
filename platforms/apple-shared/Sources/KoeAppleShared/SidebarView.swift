import SwiftUI

public struct SidebarView: View {
    let store: HostSessionStore
    @State private var showUpdatePopover = false
    @State private var showBeanPopover = false

    public init(store: HostSessionStore) { self.store = store }

    public var body: some View {
        let sidebar = store.sidebar
        VStack(alignment: .leading, spacing: 4) {
            brandHeader(sidebar)

            navigationRow(HostSection.today, section: sidebar.section)
            modeRow(HostSection.notes, sidebar: sidebar)
            modeRow(HostSection.allDay, sidebar: sidebar)
            modeRow(HostSection.liveMinutes, sidebar: sidebar)

            navigationRow(HostSection.ask, section: sidebar.section)
                .padding(.top, 4)

            sectionHeader("资料")
            navigationRow(
                HostSection.records,
                section: sidebar.section,
                count: sidebar.recordCount == 0 ? nil : sidebar.recordCount
            )
            navigationRow(
                HostSection.tasks,
                section: sidebar.section,
                count: sidebar.proposedActionCount > 0 ? sidebar.proposedActionCount : nil
            )
            navigationRow(
                HostSection.memory,
                section: sidebar.section,
                count: sidebar.memoryCount > 0 ? sidebar.memoryCount : nil
            )

            sectionHeader("音频与模型")
            navigationRow(HostSection.capture, section: sidebar.section)
            navigationRow(HostSection.settings, section: sidebar.section)

            Spacer(minLength: 12)
            beanDockButton(sidebar)
        }
        .padding(12)
        .frame(width: 196)
        .background(AppColors.bgPanel)
        .onChange(of: store.updatePopoverRequestCount) { _, newValue in
            if newValue > 0 {
                showUpdatePopover = true
            }
        }
    }

    private func brandHeader(_ sidebar: SidebarSlice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(AppColors.accent)
                .frame(width: 28, height: 28)
                .background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 8))
            Text("Koe")
                .font(.system(size: AppFontSizes.md, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button {
                showUpdatePopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    if sidebar.hasAvailableUpdate {
                        Circle()
                            .fill(AppColors.warning)
                            .frame(width: 6, height: 6)
                    }
                    Text("v\(sidebar.appVersion)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(sidebar.hasAvailableUpdate ? AppColors.warning : AppColors.textMuted)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(AppColors.bgSubtle, in: Capsule())
                .overlay(Capsule().stroke(sidebar.hasAvailableUpdate ? AppColors.warning.opacity(0.4) : AppColors.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("版本 v\(sidebar.appVersion)（构建 \(sidebar.appBuild)），点击检查软件更新")
            .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
                AppUpdateSettingsCard(store: store)
                    .frame(width: 360)
                    .padding(10)
                    .background(AppColors.surface0)
                    .preferredColorScheme(.light)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppFontSizes.xs, weight: .medium))
            .foregroundStyle(AppColors.textMuted)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func beanDockButton(_ sidebar: SidebarSlice) -> some View {
        let isPhone = sidebar.beanControlOwner == "phone"
        let dotColor: Color = if isPhone {
            AppColors.textMuted
        } else if sidebar.deviceConnected {
            AppColors.success
        } else if sidebar.devicePhase == "disconnected" {
            AppColors.textMuted
        } else {
            AppColors.warning
        }

        return Button {
            showBeanPopover.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(sidebar.deviceName)
                        .font(.system(size: AppFontSizes.xs, weight: .semibold))
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                }
                HStack(spacing: 6) {
                    if isPhone {
                        Text("手机接管")
                        Text("|").foregroundStyle(AppColors.border)
                        Text("点击切回 Mac")
                    } else if sidebar.deviceConnected {
                        Text("已连接")
                        if let mic = sidebar.batteryPercent {
                            Text("|").foregroundStyle(AppColors.border)
                            Text("麦 \(mic)%")
                        }
                        if let box = sidebar.boxBatteryPercent {
                            Text("仓 \(box)%")
                        }
                    } else {
                        Text(sidebar.deviceState)
                    }
                }
                .font(.system(size: AppFontSizes.xs))
                .foregroundStyle(AppColors.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(showBeanPopover ? AppColors.accentSoft : AppColors.surface0, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(showBeanPopover ? AppColors.accent : AppColors.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("录音豆 \(sidebar.deviceName) 状态")
        .popover(isPresented: $showBeanPopover, arrowEdge: .trailing) {
            BeanDevicePopoverView(store: store)
        }
    }

    private func isSelected(_ id: String, section: String) -> Bool {
        section == id
    }

    private func navigationRow(
        _ dest: HostSection,
        section: String,
        count: Int? = nil,
        badge: String? = nil
    ) -> some View {
        let selected = isSelected(dest.rawValue, section: section)
        return Button {
            store.send(.navigate(section: dest.rawValue))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: dest.icon).frame(width: 18)
                Text(dest.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if let badge {
                    KoeBadge(badge, tint: AppColors.warning)
                } else if let count {
                    Text("\(count)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                        .monospacedDigit()
                }
            }
            .font(.system(size: AppFontSizes.sm, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeRow(_ dest: HostSection, sidebar: SidebarSlice) -> some View {
        let selected = isSelected(dest.rawValue, section: sidebar.section)
        let active = sidebar.activeModeIds.contains(dest.rawValue)
        return Button {
            store.send(.navigate(section: dest.rawValue))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: dest.icon).frame(width: 16)
                Text(dest.title)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if active {
                    Circle()
                        .fill(AppColors.success)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("进行中")
                }
            }
            .font(.system(size: AppFontSizes.sm, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
