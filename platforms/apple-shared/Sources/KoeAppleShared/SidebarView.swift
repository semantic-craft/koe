import SwiftUI

public struct SidebarView: View {
    let store: HostSessionStore

    public init(store: HostSessionStore) { self.store = store }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(AppColors.accent)
                    .frame(width: 30, height: 30).background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                Text("Koe").font(.system(size: AppFontSizes.lg, weight: .semibold))
            }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 26)
            navigationRow("today", title: "今天", icon: "sun.max")
            navigationRow("notes", title: "随心记", icon: "text.alignleft")
            navigationRow("tasks", title: "行动", icon: "checkmark.circle")
            Spacer(minLength: 30)
            navigationRow("records", title: "所有记录", icon: "rectangle.stack")
            navigationRow("settings", title: "设置", icon: "gearshape")
        }
        .padding(12).frame(width: 186).background(AppColors.bgPanel)
    }

    private func navigationRow(_ id: String, title: String, icon: String) -> some View {
        let selected = store.snapshot.section == id || (id == "settings" && store.snapshot.section == "capture")
        return Button { store.send("navigate", ["section": id]) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
            }
            .font(.system(size: AppFontSizes.sm, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
