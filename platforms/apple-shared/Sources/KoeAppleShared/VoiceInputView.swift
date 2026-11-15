import SwiftUI

public struct VoiceInputView: View {
    public let store: HostSessionStore

    @State private var testText = ""
    @State private var baselineEpoch = ""
    @State private var baselineAudioFrames: UInt64 = 0
    @State private var baselineDictationText: String?

    public init(store: HostSessionStore) {
        self.store = store
    }

    private var vi: VoiceInputWorkspaceSnapshot {
        store.snapshot.workspaces?.voiceInput ?? .empty
    }

    private var evaluation: VoiceInputTestEvaluation {
        vi.evaluateCursorTest(
            text: testText,
            baselineEpoch: baselineEpoch,
            baselineAudioFrames: baselineAudioFrames,
            baselineDictationText: baselineDictationText
        )
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerAndControlStrip
                stepsListCard
                cursorInputTestCard

                Text(vi.boundaryNote)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textMuted)
                    .padding(.top, 2)
            }
            .padding(30)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear {
            if testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncBaseline(vi)
            }
        }
        .onChange(of: testText) { _, updated in
            if updated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncBaseline(vi)
            }
        }
        .onChange(of: vi) { _, updated in
            if testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncBaseline(updated)
            }
        }
    }

    private var headerAndControlStrip: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                PageHeading(
                    title: "语音输入",
                    subtitle: "将 soundcore Work 作为领夹麦待命音源桥接给 Responsay，在任意输入框光标处语音听写。"
                )
                HStack(spacing: 8) {
                    KoeBadge(
                        vi.deviceConnected ? vi.deviceName : "等待录音豆连接",
                        tint: vi.deviceConnected ? AppColors.success : AppColors.textSecondary
                    )
                    if let battery = vi.batteryPercent {
                        KoeBadge("电量 \(battery)%", tint: AppColors.textSecondary)
                    }
                    KoeBadge(
                        vi.standbyReady ? "待命流已就绪" : (vi.sessionEnabled ? "待命已开启" : "待命未开启"),
                        tint: vi.standbyReady ? AppColors.success : AppColors.textSecondary
                    )
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if !vi.deviceConnected {
                    KoeActionButton("连接录音豆指南", systemImage: "dot.radiowaves.left.and.right") {
                        store.send(.deviceOpenGuide)
                    }
                }
                KoeActionButton(
                    vi.sessionEnabled ? "关闭待命会话" : "开启待命会话",
                    systemImage: "character.cursor.ibeam",
                    isPrimary: !vi.sessionEnabled
                ) {
                    store.send(.setVoiceInputSession(
                        enabled: !vi.sessionEnabled,
                        openResponsay: false
                    ))
                    NotificationCenter.default.post(name: Notification.Name("KoeFlushBleOutbound"), object: nil)
                }
                .disabled(!vi.canToggleSession)
            }
        }
    }

    private var stepsListCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("联动检查步骤")
                    .font(.system(size: AppFontSizes.md, weight: .semibold))

                ForEach(vi.steps) { step in
                    stepRow(step)
                }
            }
        }
    }

    private func stepRow(_ step: VoiceInputStepSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(step.number)")
                .font(.system(size: AppFontSizes.xs, weight: .semibold))
                .foregroundStyle(AppColors.accent)
                .frame(width: 24, height: 24)
                .background(AppColors.accentSoft, in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                    KoeBadge(step.statusLabel, tint: statusTint(step.status))
                }
                Text(step.detail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)

                if step.id == "responsay_bridge", let socketPath = vi.bridgeSocketPath {
                    Text("桥接通道：\(socketPath)")
                        .font(.system(size: AppFontSizes.xs, design: .monospaced))
                        .foregroundStyle(AppColors.textMuted)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            if let label = step.actionLabel, let command = step.actionCommand {
                KoeActionButton(label) {
                    store.performVoiceInputStepAction(command)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.bgPanel, in: RoundedRectangle(cornerRadius: AppRadii.control))
    }

    private var cursorInputTestCard: some View {
        KoeCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("光标输入测试")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                    KoeBadge(evaluation.statusBadge, tint: evaluationTint(evaluation.state))
                    if vi.captureActive {
                        KoeBadge("正在收音转发", tint: AppColors.success)
                    }
                    Spacer()
                    KoeActionButton("重置测试", systemImage: "arrow.counterclockwise") {
                        testText = ""
                        syncBaseline(vi)
                    }
                }

                Text(evaluation.detail)
                    .font(.system(size: AppFontSizes.xs))
                    .foregroundStyle(AppColors.textSecondary)

                TextField("在此处测试语音光标输入，回车保留状态", text: $testText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {}

                if let lastDictation = vi.lastDictationText, !lastDictation.isEmpty {
                    Text("最近伴侣听写回执：\(lastDictation)")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(AppColors.textMuted)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func syncBaseline(_ snapshot: VoiceInputWorkspaceSnapshot) {
        baselineEpoch = snapshot.companionEpoch
        baselineAudioFrames = snapshot.forwardedAudioFrames
        baselineDictationText = snapshot.lastDictationText
    }

    private func statusTint(_ status: String) -> Color {
        switch status {
        case "ready": AppColors.success
        case "blocked": AppColors.danger
        case "external": AppColors.accent
        default: AppColors.warning
        }
    }

    private func evaluationTint(_ state: VoiceInputTestEvaluation.State) -> Color {
        switch state {
        case .streamVerified: AppColors.success
        case .manualInputOnly: AppColors.warning
        case .idle: AppColors.textSecondary
        }
    }
}
