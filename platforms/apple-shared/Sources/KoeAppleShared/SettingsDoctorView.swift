import SwiftUI

public struct SettingsDoctorView: View {
    let store: HostSessionStore
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "设置", subtitle: "管理录音音源、语音识别和文字整理服务。")
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(store.snapshot.device.deviceName, systemImage: "waveform.badge.mic")
                                .font(.system(size: AppFontSizes.md, weight: .medium))
                            Spacer()
                            KoeBadge(store.snapshot.device.state, tint: deviceStatusTint)
                        }
                        Text(store.snapshot.device.statusDetail)
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                        if store.snapshot.device.connected {
                            HStack(spacing: 12) {
                                telemetryTile(
                                    label: "麦克风电量",
                                    value: store.snapshot.device.batteryPercent.map {
                                        store.snapshot.device.charging ? "\($0)% 充电中" : "\($0)%"
                                    } ?? "—"
                                )
                                telemetryTile(
                                    label: "充电仓电量",
                                    value: store.snapshot.device.boxBatteryPercent.map {
                                        store.snapshot.device.boxCharging ? "\($0)% 充电中" : "\($0)%"
                                    } ?? "—"
                                )
                                telemetryTile(
                                    label: "设备存储",
                                    value: store.snapshot.device.storageLabel
                                )
                                telemetryTile(
                                    label: "固件版本",
                                    value: store.snapshot.device.firmwareVersion.isEmpty ? "—" : store.snapshot.device.firmwareVersion
                                )
                            }
                            HStack(spacing: 10) {
                                if store.snapshot.device.recording {
                                    KoeActionButton("结束录音", systemImage: "stop.circle", isPrimary: true) {
                                        store.send("device_stop")
                                        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                                    }
                                } else {
                                    KoeActionButton("开始录音", systemImage: "record.circle", isPrimary: true) {
                                        store.send("device_start")
                                        NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                                    }.disabled(store.snapshot.device.busy)
                                }
                                KoeActionButton("刷新状态", systemImage: "arrow.clockwise") {
                                    store.send("device_refresh")
                                    NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                                }.disabled(store.snapshot.device.busy)
                                KoeActionButton("使用引导", systemImage: "questionmark.circle") {
                                    store.send("device_open_guide")
                                }
                                KoeActionButton("断开连接", systemImage: "xmark.circle") {
                                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleDisconnect"), object: nil)
                                }
                            }
                        } else {
                            Text("将麦克风放入充电仓，短按充电仓下方按钮开启蓝牙广播后点击连接。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            HStack(spacing: 10) {
                                KoeActionButton("连接录音豆", systemImage: "antenna.radiowaves.left.and.right", isPrimary: true) {
                                    store.send("device_open_guide")
                                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                                }.disabled(store.snapshot.device.busy)
                                KoeActionButton("重新扫描", systemImage: "arrow.clockwise") {
                                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                                }.disabled(store.snapshot.device.busy)
                            }
                        }
                        if store.snapshot.device.busy { ProgressView(value: store.snapshot.device.progress) }
                        ForEach(store.snapshot.device.files) { file in
                            HStack {
                                Text(file.title).font(.system(size: AppFontSizes.sm))
                                Text(TimeLabel.duration(file.durationMs)).font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textMuted)
                                Spacer()
                                KoeActionButton("取回") {
                                    store.send("device_download", ["fileId": file.id])
                                    NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                                }
                                .disabled(store.snapshot.device.busy)
                            }.padding(.vertical, 5)
                        }
                    }
                }
                CompanionSettingsCard(store: store)
                SpeechSettingsCard(store: store)
                TextServiceSettingsCard(store: store)
                KoeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("外部应用接入", systemImage: "app.connected.to.app.below.fill")
                                .font(.system(size: AppFontSizes.md, weight: .medium))
                            InfoTip("外部应用通过本机桥接协议请求语音输入并读取圈定片段。开始、结束语音输入与全天听记相互独立；是否将文字插入其他应用由接入方处理。")
                        }
                        Text("全天听记保留完整对话，外部应用可单独使用圈定的听写片段。")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                    }
                }
                Text("记录与确认结果保存在本机工作区。导出时可选择保存位置。")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(30).frame(maxWidth: 850, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func telemetryTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            Text(value).font(.system(size: AppFontSizes.sm, weight: .medium)).foregroundStyle(AppColors.textPrimary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }
    private var deviceStatusTint: Color {
        if store.snapshot.device.connected { return AppColors.success }
        if store.snapshot.device.phase == "disconnected" { return AppColors.textMuted }
        return AppColors.warning
    }
}
