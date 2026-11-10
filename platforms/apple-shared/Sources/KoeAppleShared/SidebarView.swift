import SwiftUI

public struct SidebarView: View {
    let store: HostSessionStore
    private let sections = [
        ("today", "今天", "sun.max"), ("records", "所有记录", "rectangle.stack"),
        ("tasks", "待办", "checkmark.circle"), ("memory", "记忆", "square.stack.3d.up"),
        ("ask", "问 Koe", "sparkles")
    ]
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").foregroundStyle(AppColors.accent)
                    .frame(width: 30, height: 30).background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                Text("koe").font(.system(size: AppFontSizes.lg, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 26)
            ForEach(sections, id: \.0) { section in
                navigationRow(section.0, title: section.1, icon: section.2)
            }
            if !store.snapshot.records.isEmpty {
                Text("最近的记录").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                    .padding(.horizontal, 12).padding(.top, 26).padding(.bottom, 6)
                ForEach(store.snapshot.records.prefix(4)) { record in
                    Button { store.send("select_record", ["recordId": record.id]) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "doc.text").foregroundStyle(AppColors.textMuted)
                            Text(record.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textSecondary)
                        .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 30)
            Button { store.send("navigate", ["section": "settings"]) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.badge.mic").foregroundStyle(AppColors.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Soundcore Work").foregroundStyle(AppColors.textPrimary)
                        Text(store.snapshot.device.state).foregroundStyle(AppColors.textMuted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(store.snapshot.device.connected ? AppColors.success : AppColors.textMuted)
                        .frame(width: 5, height: 5)
                }
                .font(.system(size: AppFontSizes.xs)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppColors.border))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            navigationRow("settings", title: "设置", icon: "gearshape")
        }
        .padding(12).frame(width: 220).background(AppColors.bgPanel)
    }
    private func navigationRow(_ id: String, title: String, icon: String) -> some View {
        let selected = store.snapshot.section == id || (id == "records" && store.snapshot.section == "detail")
        return Button { store.send("navigate", ["section": id]) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if id == "records", !store.snapshot.records.isEmpty {
                    Text("\(store.snapshot.records.count)").font(.system(size: AppFontSizes.xs))
                }
            }
            .font(.system(size: AppFontSizes.sm, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? AppColors.accent : AppColors.textSecondary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(selected ? AppColors.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
