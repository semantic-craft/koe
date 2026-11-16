import SwiftUI

public struct SidebarView: View {
    let store: HostSessionStore

    public init(store: HostSessionStore) { self.store = store }

    public var body: some View {
        let sidebar = store.sidebar
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(AppColors.accent)
                    .frame(width: 28, height: 28)
                    .background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                Text("Koe")
                    .font(.system(size: AppFontSizes.md, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 18)

            navigationRow("today", title: "模式选择", icon: "square.grid.2x2", section: sidebar.section)
            modeRow("notes", title: "随心闪记", icon: "bolt.horizontal", sidebar: sidebar)
            modeRow("all_day", title: "全天听记", icon: "clock", sidebar: sidebar)
            modeRow("live_minutes", title: "实时纪要", icon: "waveform.path.ecg", sidebar: sidebar)
            modeRow("voice_input", title: "语音输入", icon: "character.cursor.ibeam", sidebar: sidebar)

            navigationRow("ask", title: "问 AI", icon: "bubble.left.and.text.bubble.right", section: sidebar.section)
                .padding(.top, 4)

            Text("资料")
                .font(.system(size: AppFontSizes.xs, weight: .medium))
                .foregroundStyle(AppColors.textMuted)
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 2)

            navigationRow(
                "records",
                title: "所有记录",
                icon: "tray.full",
                section: sidebar.section,
                count: sidebar.recordCount == 0 ? nil : sidebar.recordCount
            )
            navigationRow(
                "tasks",
                title: "行动",
                icon: "checklist",
                section: sidebar.section,
                count: sidebar.proposedActionCount > 0 ? sidebar.proposedActionCount : nil
            )

            Spacer(minLength: 16)
            navigationRow("settings", title: "设置", icon: "gearshape", section: sidebar.section)
        }
        .padding(12)
        .frame(width: 196)
        .background(AppColors.bgPanel)
    }

    private func isSelected(_ id: String, section: String) -> Bool {
        if id == "settings" {
            return section == "settings" || section == "capture"
        }
        if id == "tasks" {
            return section == "tasks" || section == "memory"
        }
        return section == id
    }

    private func navigationRow(
        _ id: String,
        title: String,
        icon: String,
        section: String,
        count: Int? = nil
    ) -> some View {
        let selected = isSelected(id, section: section)
        return Button {
            store.send(.navigate(section: id))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer(minLength: 4)
                if let count {
                    Text("\(count)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(selected ? AppColors.accent : AppColors.textMuted)
                        .monospacedDigit()
                }
            }
            .font(.system(size: AppFontSizes.sm, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func modeRow(_ id: String, title: String, icon: String, sidebar: SidebarSlice) -> some View {
        let selected = isSelected(id, section: sidebar.section)
        let active = sidebar.activeModeIds.contains(id)
        return Button {
            store.send(.navigate(section: id))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 16)
                Text(title)
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
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
