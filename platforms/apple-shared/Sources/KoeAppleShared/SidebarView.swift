import SwiftUI

public struct SidebarView: View {
    let store: HostSessionStore
    private let sections = [
        ("today", "今天", "sun.max"), ("capture", "录音", "mic"),
        ("records", "所有记录", "rectangle.stack"),
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
                navigationRow(
                    section.0,
                    title: section.1,
                    icon: section.2,
                    count: section.0 == "records" ? store.snapshot.records.count : 0
                )
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
            Button {
                store.send("navigate", ["section": "capture"])
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: store.snapshot.microphone == nil && store.snapshot.capture.selectedSource == "bean" ? "waveform.badge.mic" : "mic.fill")
                        .foregroundStyle(AppColors.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.snapshot.microphone?.inputLabel ?? store.snapshot.capture.selectedLabel).foregroundStyle(AppColors.textPrimary).lineLimit(1)
                        Text(deviceSummaryText).foregroundStyle(AppColors.textMuted).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(deviceDotColor)
                        .frame(width: 6, height: 6)
                }
                .font(.system(size: AppFontSizes.xs)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(AppColors.border))
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            navigationRow("trash", title: "回收站", icon: "trash", count: store.snapshot.trashRecords.count)
            navigationRow("settings", title: "设置", icon: "gearshape")
        }
        .padding(12).frame(width: 220).background(AppColors.bgPanel)
    }
    public var deviceSummaryText: String {
        if let mic = store.snapshot.microphone {
            return "\(mic.phaseSummaryLabel)  \(TimeLabel.duration(mic.durationMs))"
        }
        let dev = store.snapshot.device
        if dev.recording || dev.stopping || dev.transferPhase == "streaming_realtime" {
            return "正在录音  \(TimeLabel.duration(dev.liveDurationMs))"
        }
        let cap = store.snapshot.capture
        if cap.selectedSource == "bean" {
            if dev.connected {
                if dev.busy && dev.transferPhase == "pulling_offline" { return "正在取回录音" }
                if dev.companionMode == "collar_standby" { return "领口待命中" }
                if let micPct = dev.batteryPercent {
                    return "已连接  \(micPct)%"
                }
                return dev.state
            }
            if dev.phase == "disconnected" {
                return "未连接  点击选择音源"
            }
            return dev.state
        }
        return "\(cap.selectedBadge)  点击录音"
    }
    public var deviceDotColor: Color {
        if let mic = store.snapshot.microphone {
            return mic.phase == "paused" ? AppColors.warning : KoeColors.danger
        }
        let dev = store.snapshot.device
        if dev.recording || dev.stopping || dev.transferPhase == "streaming_realtime" {
            return KoeColors.danger
        }
        let cap = store.snapshot.capture
        if cap.selectedSource == "bean" {
            if dev.connected {
                if dev.busy && dev.transferPhase == "pulling_offline" { return AppColors.warning }
                if dev.companionMode == "collar_standby" { return AppColors.accent }
                return AppColors.success
            }
            if dev.phase == "disconnected" { return AppColors.textMuted }
            return AppColors.warning
        }
        return cap.canStart ? AppColors.success : AppColors.textMuted
    }
    private func navigationRow(_ id: String, title: String, icon: String, count: Int = 0) -> some View {
        let selected = store.snapshot.section == id || (id == "records" && store.snapshot.section == "detail")
        return Button { store.send("navigate", ["section": id]) } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if count > 0 {
                    Text("\(count)").font(.system(size: AppFontSizes.xs))
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
