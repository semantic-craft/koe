import SwiftUI

public struct SettingsDoctorView: View {
    let store: HostSessionStore
    @State private var showAllDayDemo = false
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        let device = store.device
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "设置", subtitle: "管理录音音源、语音识别和文字整理服务。")
                KoeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Label("录音与保存", systemImage: "mic")
                                .font(.system(size: AppFontSizes.md, weight: .medium))
                            InfoTip("录音保存在本机。随手记与全天听记暂不支持只留文字。")
                        }
                        HStack(spacing: 10) {
                            KoeActionButton("录音管理", systemImage: "mic") {
                                store.send(.navigate(section: "capture"))
                            }
                            KoeActionButton("全天听记演示", systemImage: "play.rectangle") { showAllDayDemo = true }
                        }
                    }
                }
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(device.deviceName, systemImage: "waveform.badge.mic")
                                .font(.system(size: AppFontSizes.md, weight: .medium))
                            Spacer()
                            KoeBadge(device.state, tint: deviceStatusTint(device))
                        }
                        Text(device.statusDetail)
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
                        if device.connected {
                            HStack(spacing: 12) {
                                telemetryTile(
                                    label: "麦克风电量",
                                    value: device.batteryPercent.map {
                                        device.charging ? "\($0)% 充电中" : "\($0)%"
                                    } ?? "—"
                                )
                                telemetryTile(
                                    label: "充电仓电量",
                                    value: device.boxBatteryPercent.map {
                                        device.boxCharging ? "\($0)% 充电中" : "\($0)%"
                                    } ?? "—"
                                )
                                telemetryTile(
                                    label: "设备存储",
                                    value: device.storageLabel
                                )
                                telemetryTile(
                                    label: "固件版本",
                                    value: device.firmwareVersion.isEmpty ? "—" : device.firmwareVersion
                                )
                            }
                            HStack(spacing: 10) {
                                KoeActionButton("刷新状态", systemImage: "arrow.clockwise") {
                                    store.send(.deviceRefresh)
                                    NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                                }.disabled(device.busy)
                                KoeActionButton("使用引导", systemImage: "questionmark.circle") {
                                    store.send(.deviceOpenGuide)
                                }
                                KoeActionButton("切回手机", systemImage: "iphone") {
                                    store.send(.deviceRelease)
                                }.disabled(!store.canReleaseToPhone)
                            }
                        } else {
                            Text("将麦克风放入充电仓，短按充电仓下方按钮开启蓝牙广播后点击连接。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            HStack(spacing: 10) {
                                KoeActionButton("连接录音豆", systemImage: "antenna.radiowaves.left.and.right", isPrimary: true) {
                                    store.send(.deviceOpenGuide)
                                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                                }.disabled(device.busy)
                                KoeActionButton("重新扫描", systemImage: "arrow.clockwise") {
                                    NotificationCenter.default.post(name: Notification.Name("KoeRequestBleScan"), object: nil)
                                }.disabled(device.busy)
                                if device.autoConnect {
                                    KoeActionButton("切回手机", systemImage: "iphone") {
                                        store.send(.deviceRelease)
                                    }.disabled(!store.canReleaseToPhone)
                                }
                            }
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
                KoeActionButton("管理记忆", systemImage: "square.stack.3d.up") {
                    store.send(.navigate(section: "memory"))
                }
            }.padding(30).frame(maxWidth: 850, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAllDayDemo) { AllDayDemoView() }
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
    private func deviceStatusTint(_ device: DeviceSnapshot) -> Color {
        if device.connected { return AppColors.success }
        if device.phase == "disconnected" { return AppColors.textMuted }
        return AppColors.warning
    }
}
