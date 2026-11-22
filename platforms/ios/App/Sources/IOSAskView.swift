import KoeAppleCore
import SwiftUI

private struct IndexedAskSource: Identifiable {
    let rank: Int
    let source: SourceSnapshot

    var id: String { "\(rank):\(source.id)" }
}

struct IOSAskView: View {
    let store: HostSessionStore
    let onOpenSource: (SourceSnapshot) -> Void

    @State private var questionDraft = ""
    @State private var inspectedSource: SourceSnapshot?

    var body: some View {
        let ask = store.ask
        let records = store.records
        let providerConfigured = store.settings.provider.configured

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    scopeChip("全部记录", active: ask.scope == "all") {
                        store.send(.setAskScope(scope: "all", recordId: nil))
                    }
                    .accessibilityIdentifier("ask-scope-all")
                    Menu {
                        ForEach(records) { record in
                            Button(record.title) { store.send(.setAskScope(scope: "record", recordId: record.id)) }
                            .accessibilityIdentifier("ask-scope-\(record.id)")
                        }
                    } label: {
                        Label(ask.scope == "record" ? (records.first { $0.id == ask.recordId }?.title ?? "选择记录") : "选择记录",
                              systemImage: "chevron.down").lineLimit(1)
                    }.disabled(records.isEmpty)
                    .accessibilityIdentifier("ask-scope-picker")
                    Spacer()
                    if !providerConfigured {
                        IOSBadge("本地检索", tint: IOSColors.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(IOSColors.bgPanel)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if ask.messages.isEmpty {
                            IOSEmptyState(
                                icon: "sparkles",
                                title: "向已保存的记录提问",
                                detail: "提问讨论结论、待办或决定，回答将附带可追溯的原文出处。"
                            )
                        } else {
                            ForEach(ask.messages) { message in
                                messageCard(message)
                            }
                        }

                        if ask.phase == "pending" {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在查阅相关记录…")
                                    .font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(IOSColors.textMuted)
                            }
                            .padding(.horizontal, 8)
                        }
                        Color.clear.frame(height: 1).id("ask-bottom")
                    }
                    .frame(maxWidth: 760)
                    .padding(16)
                }
                .background(IOSColors.bgPanel)
                .onChange(of: ask.messages.last?.id, initial: true) { proxy.scrollTo("ask-bottom", anchor: .bottom) }
                .onChange(of: ask.phase) { proxy.scrollTo("ask-bottom", anchor: .bottom) }
            }

            IOSAskComposer(store: store, questionDraft: $questionDraft)
        }
        .navigationTitle("问 AI")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $inspectedSource) { source in
            IOSAskSourceEvidenceSheet(source: source) {
                inspectedSource = nil
                onOpenSource(source)
            }
        }
    }

    private func scopeChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: AppFontSizes.xs, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? IOSColors.onAccent : IOSColors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? IOSColors.accent : IOSColors.surface1, in: Capsule())
                .overlay(Capsule().stroke(active ? IOSColors.accent : IOSColors.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func messageCard(_ message: AskMessageSnapshot) -> some View {
        let isUser = message.role == "user"
        let indexedSources = zip(1..., message.sources).map {
            IndexedAskSource(rank: $0.0, source: $0.1)
        }
        return IOSCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isUser ? "person.crop.circle" : "sparkles")
                        .font(.system(size: AppFontSizes.xs))
                        .foregroundStyle(IOSColors.textMuted)
                    Text(isUser ? "你" : "Koe")
                        .font(.system(size: AppFontSizes.xs, weight: .semibold))
                        .foregroundStyle(IOSColors.textMuted)
                    if !isUser && message.mode == "retrieval" {
                        IOSBadge("原文检索", tint: IOSColors.textMuted)
                    }
                    Spacer()
                    if !isUser {
                        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                        .accessibilityIdentifier("copy-\(message.id)")
                            .labelStyle(.iconOnly)
                    }
                }

                Text(message.text)
                    .textSelection(.enabled)
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(IOSColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !indexedSources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(indexedSources) { item in
                                Button {
                                    onOpenSource(item.source)
                                } label: {
                                    Text("[S\(item.rank)]")
                                        .font(.system(size: AppFontSizes.xs, weight: .semibold))
                                        .foregroundStyle(IOSColors.accent)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(IOSColors.accentSoft, in: Capsule())
                                        .overlay(Capsule().stroke(IOSColors.border, lineWidth: 1))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("查看来源摘录") { inspectedSource = item.source }
                                }
                                .accessibilityIdentifier("ask-source-chip-\(item.rank)")
                                .accessibilityLabel("[S\(item.rank)]")
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct IOSAskSourceEvidenceSheet: View {
    let source: SourceSnapshot
    let onJumpToRecord: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IOSContentHuggingSheet(minHeight: 240, maxHeight: 460) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("原文来源")
                        .font(.system(size: AppFontSizes.md, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    Spacer()
                    IOSPrimaryButton("关闭", isPrimary: false) {
                        dismiss()
                    }
                }

                HStack(spacing: 8) {
                    Text(source.title)
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    Spacer()
                    IOSBadge(TimeLabel.duration(source.startMs), tint: IOSColors.textSecondary)
                }

                Text(source.quote)
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(IOSColors.textSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))

                IOSPrimaryButton("打开完整记录", systemImage: "arrow.up.right", isPrimary: true) {
                    onJumpToRecord()
                }
            }
            .padding(20)
        }
    }
}
