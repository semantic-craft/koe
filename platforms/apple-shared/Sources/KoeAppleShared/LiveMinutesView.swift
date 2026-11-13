import SwiftUI

struct LiveMinutesView: View {
    let store: HostSessionStore

    private var minutes: LiveMinutesSnapshot? { store.snapshot.liveMinutes }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                PageHeading(title: "实时纪要", subtitle: subtitle)
                Spacer()
                if let minutes {
                    KoeBadge(phaseLabel(minutes.phase), tint: minutes.phase == .recording ? AppColors.danger : AppColors.textSecondary)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                panel("实时原文", icon: "waveform") { transcript }
                panel("AI 纪要", icon: "doc.text") { summaries }
            }
        }
        .padding(22)
        .frame(maxWidth: 1320, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("live-minutes-page")
    }

    private var subtitle: String {
        switch minutes?.scope.kind {
        case .allDay: "全天听记会持续转写和整理，停止后补齐最后的内容。"
        case .record, .beanStarting: "原文确认后持续整理纪要，停止录音后补齐最后的内容。"
        case nil: "从今天开始录音，这里会显示本次采集的原文和纪要。"
        }
    }

    private func phaseLabel(_ phase: LiveMinutesSnapshot.Phase) -> String {
        switch phase {
        case .starting: "正在启动"
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .finishing: "正在收尾"
        case .ended: "录音已结束"
        }
    }

    private func panel<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(title, systemImage: icon)
                .font(.system(size: AppFontSizes.md, weight: .semibold))
                .padding(16)
            Rectangle().fill(AppColors.border).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20, content: content)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.surface1, in: RoundedRectangle(cornerRadius: AppRadii.cardOuter))
        .overlay(RoundedRectangle(cornerRadius: AppRadii.cardOuter).stroke(AppColors.border).allowsHitTesting(false))
    }

    @ViewBuilder private var transcript: some View {
        if let minutes {
            if minutes.parts.isEmpty {
                hint(minutes.phase == .ended ? "本次录音没有可显示的原文。" : "等待录音原文。")
            }
            ForEach(minutes.parts) { part in
                VStack(alignment: .leading, spacing: 14) {
                    partHeader(part, showRecordLink: true)
                    if part.segments.isEmpty && part.drafts.isEmpty {
                        hint(minutes.phase == .ended ? "这段录音没有转写原文。" : "等待转写结果。")
                    }
                    ForEach(part.segments) { segment in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(TimeLabel.duration(segment.startMs)).monospacedDigit()
                                if let speaker = segment.speaker { Text(speaker) }
                            }
                            .font(.system(size: AppFontSizes.xs))
                            .foregroundStyle(AppColors.textMuted)
                            paragraph(segment.text)
                        }
                    }
                    ForEach(part.drafts.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            KoeBadge("识别中")
                            paragraph(part.drafts[index])
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.bgSubtle, in: RoundedRectangle(cornerRadius: AppRadii.control))
                    }
                }
            }
        } else {
            hint("还没有本次录音的原文。")
            KoeActionButton("前往今天", systemImage: "sun.max") {
                store.send("navigate", ["section": "today"])
            }
        }
    }

    @ViewBuilder private var summaries: some View {
        if let minutes {
            if minutes.parts.isEmpty {
                if !minutes.configured {
                    hint("尚未配置文字整理服务。")
                    settingsButton
                } else if minutes.phase == .ended {
                    hint("本次录音没有可整理的原文。")
                } else {
                    hint("等待已确认的原文，纪要会在录音中持续更新。")
                }
            }
            ForEach(minutes.parts) { part in
                VStack(alignment: .leading, spacing: 12) {
                    partHeader(part, showRecordLink: false)
                    if let label = analysisLabel(part.analysis) {
                        hint(part.error.map { "\(label)：\($0)" } ?? label)
                    }
                    if part.minutesStale && part.analysis != .stale {
                        hint("下方纪要基于旧原文。")
                    }
                    if part.analysis == .unconfigured { settingsButton }
                    ForEach(part.summary.indices, id: \.self) { index in
                        let section = part.summary[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.title).font(.system(size: AppFontSizes.sm, weight: .semibold))
                            paragraph(section.text)
                            ForEach(section.sources) { source in
                                SourceLink(source: source, store: store)
                            }
                        }
                    }
                }
            }
        } else {
            hint("有录音原文后，这里会显示整理结果。")
        }
    }

    private func analysisLabel(_ state: LiveMinutesSnapshot.Part.Analysis) -> String? {
        switch state {
        case .unconfigured: "尚未配置文字整理服务。"
        case .awaitingTranscript: "等待已确认的原文。"
        case .waiting: "等待下一轮整理。"
        case .queued: "等待整理。"
        case .summarizing: "正在整理纪要。"
        case .ready: nil
        case .stale: "下方纪要尚未包含最新原文，正在等待更新。"
        case .failed: "处理失败"
        case .interrupted: "处理已中断。"
        }
    }

    private func partHeader(_ part: LiveMinutesSnapshot.Part, showRecordLink: Bool) -> some View {
        HStack(alignment: .center) {
            Text(part.ordinal.map { "第 \($0) 段" } ?? part.title)
                .font(.system(size: AppFontSizes.sm, weight: .semibold))
                .lineLimit(1)
            if showRecordLink {
                Spacer(minLength: 8)
                KoeActionButton("查看记录", systemImage: "arrow.up.right") {
                    store.send("select_record", ["recordId": part.recordId])
                }
            }
        }
    }

    private var settingsButton: some View {
        KoeActionButton("打开设置", systemImage: "gearshape") {
            store.send("navigate", ["section": "settings"])
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: AppFontSizes.sm)).foregroundStyle(AppColors.textSecondary)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppFontSizes.sm))
            .lineSpacing(4)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
