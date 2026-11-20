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
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        let ask = store.ask
        let records = store.records
        let selectedRecordId = store.navigation.selectedRecordId
        let providerConfigured = store.settings.provider.configured

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    scopeChip("全部记录", active: ask.scope == "all") {
                        store.send(.setAskScope(scope: "all", recordId: nil))
                    }
                    if let recordId = ask.recordId ?? selectedRecordId,
                       let record = records.first(where: { $0.id == recordId }) {
                        scopeChip(
                            record.title,
                            active: ask.scope == "record" && ask.recordId == record.id
                        ) {
                            store.send(.setAskScope(scope: "record", recordId: record.id))
                        }
                    }
                    Spacer()
                    if !providerConfigured {
                        IOSBadge("本地检索", tint: IOSColors.textMuted)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(IOSColors.bgPanel)

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
                }
                .padding(16)
            }
            .background(IOSColors.bgPanel)

            HStack(spacing: 8) {
                TextField("问问你记下来的事…", text: $questionDraft)
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(IOSColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                    .overlay(
                        RoundedRectangle(cornerRadius: IOSRadii.control)
                            .stroke(IOSColors.border, lineWidth: 1)
                    )
                    .submitLabel(.send)
                    .focused($isQuestionFocused)
                    .accessibilityIdentifier("ask-question-input")
                    .onSubmit {
                        submitQuestion()
                    }

                IOSPrimaryButton("发送", systemImage: "arrow.up", isPrimary: true) {
                    submitQuestion()
                }
                .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ask.phase == "pending")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .iosChromeSurface(IOSColors.surface0)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(IOSColors.border)
                    .frame(height: 1)
            }
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
                }

                Text(message.text)
                    .font(.system(size: AppFontSizes.sm))
                    .foregroundStyle(IOSColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                if !indexedSources.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(indexedSources) { item in
                                Button {
                                    inspectedSource = item.source
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
                                .accessibilityIdentifier("ask-source-chip-\(item.rank)")
                                .accessibilityLabel("[S\(item.rank)]")
                            }
                        }
                    }
                }
            }
        }
    }

    private func submitQuestion() {
        let trimmed = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = store.ask
        guard !trimmed.isEmpty, ask.phase != "pending" else { return }
        isQuestionFocused = false
        store.send(.ask(question: trimmed, scope: ask.scope, recordId: ask.recordId))
        if store.navigation.effectiveError == nil {
            questionDraft = ""
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
