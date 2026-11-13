import SwiftUI

struct AllDayDemoView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var scene = 0
    @State private var step = 0
    @State private var replay = 0
    private var isMeeting: Bool { scene == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("全天听记与语音输入").font(.system(size: AppFontSizes.lg, weight: .semibold))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                KoeBadge("示意数据")
                Text("此演示不会开启麦克风，也不会保存记录。")
                    .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
            }
            Picker("演示场景", selection: $scene) {
                Text("双击圈定听写").tag(0)
                Text("会议中另取一句").tag(1)
            }.pickerStyle(.segmented)
            HStack(spacing: 10) {
                Circle().fill(AppColors.danger).frame(width: 8, height: 8)
                    .scaleEffect(step.isMultiple(of: 2) ? 1 : 1.3)
                Text("全天听记持续进行")
                Spacer()
                KoeBadge(step == 0 ? "语音输入未开始" : step < 3 ? "语音输入中" : "语音输入已结束")
            }.font(.system(size: AppFontSizes.sm))
            VStack(alignment: .leading, spacing: 16) {
                transcriptLine(isMeeting ? "大家继续讨论下周的会议安排。" : "今天先去书店，再回办公室。", selected: false)
                if step >= 1 {
                    transcriptLine(isMeeting ? "提醒我周五把方案发给同事。" : "帮我记一下，周末给花浇水。", selected: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if step >= 3 {
                    transcriptLine(isMeeting ? "会议继续，我们接着确认预算。" : "好了，继续记录接下来的对话。", selected: false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .padding(18).background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: step == 1 || step == 2 ? "hand.tap" : "checkmark.circle")
                    .foregroundStyle(AppColors.accent)
                VStack(alignment: .leading, spacing: 8) {
                    Text(caption).font(.system(size: AppFontSizes.md, weight: .medium))
                    Text("双击录音豆或点击“开始语音输入”圈定开头，再次双击或点击“结束语音输入”圈定结尾。全天听记保持进行。")
                        .font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary).lineSpacing(5)
                }
            }
            HStack {
                Spacer()
                KoeActionButton("重播", systemImage: "arrow.counterclockwise") { replay += 1 }
            }
        }
        .padding(28).frame(width: 660)
        .task(id: "\(scene)-\(replay)") {
            step = 0
            for next in 1...3 {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                withAnimation(.easeInOut(duration: 0.45)) { step = next }
            }
        }
    }

    private var caption: String {
        switch step {
        case 0: "先开始全天听记"
        case 1: "第一次双击，开始圈定语音输入"
        case 2: "只圈定这一句，其他对话仍在录音中"
        default: "再次双击，结束语音输入，麦克风继续录音"
        }
    }

    private func transcriptLine(_ text: String, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "text.quote" : "waveform")
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            if selected { KoeBadge(step >= 3 ? "已圈定片段" : "圈定中") }
        }
        .font(.system(size: AppFontSizes.sm))
        .foregroundStyle(selected ? AppColors.textPrimary : AppColors.textSecondary)
        .padding(12).background(selected ? AppColors.accentSoft : AppColors.surface1,
                                in: RoundedRectangle(cornerRadius: AppRadii.control))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.control).stroke(selected ? AppColors.accent : AppColors.border))
    }
}
