import SwiftUI

public struct SettingsDoctorView: View {
    let store: HostSessionStore
    @State private var apiKey = ""
    @State private var model = "qwen-plus"
    @State private var chatEndpoint = ""
    @State private var asrEndpoint = ""
    public init(store: HostSessionStore) { self.store = store }
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                PageHeading(title: "设置", subtitle: "连接录音豆，管理当前使用的 AI 服务。")
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
                KoeCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("AI 服务", systemImage: "sparkles").font(.system(size: AppFontSizes.md, weight: .medium))
                            Spacer()
                            KoeBadge(store.snapshot.provider.configured ? "已配置" : "未配置",
                                     tint: store.snapshot.provider.configured ? AppColors.success : AppColors.textMuted)
                        }
                        Text("使用阿里云百炼完成转写、整理与问答。未配置时，原文、待办、记忆和本地检索仍可使用。")
                            .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary).lineSpacing(5)
                        HStack {
                            Toggle("会议录音只留本机", isOn: Binding(
                                get: { store.snapshot.provider.meetingAudioPolicy == "local_only" },
                                set: { store.send("set_meeting_audio_policy", ["policy": $0 ? "local_only" : "cloud_allowed"]) }
                            ))
                            InfoTip("开启后停止会议音频云端转写，保留本地录音。此前已发送的音频无法撤回。文字纪要与问答仍可发云；关闭后需手动重试已取消的任务。")
                        }
                        if let status = store.snapshot.provider.meetingAudioStatus {
                            Text(status).font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                        }
                        SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder).onSubmit { configure() }
                        TextField("文本模型", text: $model).textFieldStyle(.roundedBorder).onSubmit { configure() }
                        DisclosureGroup("自定义服务地址（可选）") {
                            VStack(spacing: 10) {
                                TextField("对话服务完整地址，留空使用默认", text: $chatEndpoint)
                                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                                TextField("转写服务完整地址，留空使用默认", text: $asrEndpoint)
                                    .textFieldStyle(.roundedBorder).onSubmit { configure() }
                            }.padding(.top, 10)
                        }.font(.system(size: AppFontSizes.xs))
                        HStack {
                            Text(store.snapshot.provider.isolated ? "隔离运行，密钥仅在本次会话使用。" : "密钥保存在系统安全存储中，留空保留已存密钥。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            Spacer()
                            KoeActionButton("保存配置", isPrimary: true) { configure() }

                        }
                        HStack {
                            KoeActionButton("清除密钥") {
                                apiKey = ""
                                store.send("clear_provider_credential")
                            }
                            KoeActionButton("重试读取安全配置") { store.send("retry_provider_credentials", ["authorize": true]) }
                        }
                        if store.snapshot.provider.credentialState == "reopen_required" {
                            Text("工作区保存结果尚未确认，请退出并重新打开 Koe。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                        }
                        if store.snapshot.provider.credentialState == "missing_saved" {
                            Text("已保存的密钥在当前安全存储中不存在，请重新输入或清除。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                        }
                        if store.snapshot.provider.credentialState == "unavailable" {
                            Text("安全凭据暂不可读取，云端处理已停用。")
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.warning)
                        }
                    }
                }
                KoeCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("旧版资料迁移").font(.system(size: AppFontSizes.md, weight: .medium))
                        KoeActionButton("选择旧版资料目录", systemImage: "folder") {
                            NotificationCenter.default.post(name: Notification.Name("KoeImportFlutterLibrary"), object: nil)
                        }
                        ForEach(store.snapshot.migrationReports ?? []) { report in
                            Text("已迁入 \(report.recordCount) 条基础记录，尚未完成全部迁移。")
                                .font(.system(size: AppFontSizes.sm))
                            Text("保全副本：\(report.archivePath)").textSelection(.enabled)
                                .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                            ForEach(report.pending, id: \.self) { item in
                                Text(item).font(.system(size: AppFontSizes.xs))
                            }
                        }
                    }
                }
                Text("记录与确认结果保存在本机工作区。导出时可选择保存位置。")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }.padding(30).frame(maxWidth: 850, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            model = store.snapshot.provider.model
            chatEndpoint = store.snapshot.provider.chatEndpoint
            asrEndpoint = store.snapshot.provider.asrEndpoint
        }
        .onDisappear { apiKey = "" }
    }
    private func configure() {
        var fields: [String: Any] = ["model": model]
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["apiKey"] = apiKey }
        let chat = chatEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let asr = asrEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        fields["chatEndpoint"] = chat
        fields["asrEndpoint"] = asr
        store.send("configure_provider", fields)
        apiKey = ""
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
