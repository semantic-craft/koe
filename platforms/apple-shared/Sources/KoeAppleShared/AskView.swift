import SwiftUI

struct AskView: View {
    let store: HostSessionStore
    @State private var draft = ""
    private var latestSources: [SourceSnapshot] {
        store.snapshot.ask.messages.last(where: { $0.role == "assistant" })?.sources ?? []
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(title: "问 Koe", subtitle: "从记下来的事情中，找到有出处的回答。")
                    HStack {
                        scopeButton("all", title: "所有记录")
                        if let recordId = store.snapshot.ask.recordId,
                           let record = store.snapshot.records.first(where: { $0.id == recordId }) {
                            scopeButton("record", title: record.title, recordId: record.id)
                        }
                        if let recordId = store.snapshot.selectedRecordId,
                           recordId != store.snapshot.ask.recordId,
                           let record = store.snapshot.records.first(where: { $0.id == recordId }) {
                            scopeButton("record", title: record.title, recordId: record.id)
                        }
                        Spacer()
                        if !store.snapshot.provider.configured {
                            KoeBadge("本地检索", tint: AppColors.textMuted)
                        }
                    }
                }.padding(28)
                Divider().overlay(AppColors.border)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 26) {
                            if store.snapshot.ask.messages.isEmpty {
                                EmptyState(icon: "sparkles", title: "有些事，不必再从头想起", detail: "提问一段讨论、一项决定，或接下来要做的事。回答会连接到真实的原文。")
                                if !store.snapshot.provider.configured {
                                    Text("尚未配置 AI 服务。现在可以搜索原文，配置后可以生成回答。")
                                        .font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            ForEach(store.snapshot.ask.messages) { message in
                                messageView(message).id(message.id)
                            }
                            if store.snapshot.ask.phase == "pending" {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("正在查阅相关记录…").font(.system(size: AppFontSizes.xs)).foregroundStyle(AppColors.textMuted)
                                }.id("pending")
                            }
                        }.padding(28)
                    }
                    .onChange(of: store.snapshot.ask.messages.count) { _, _ in
                        if let last = store.snapshot.ask.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("问问你记下来的事…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).lineLimit(1...5).font(.system(size: AppFontSizes.sm))
                        .onSubmit { submit() }
                    KoeActionButton("发送", systemImage: "arrow.up", isPrimary: true) { submit() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.snapshot.ask.phase == "pending")
                }.padding(14).background(AppColors.surface1, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(AppColors.border)).padding(24)
            }
            if !latestSources.isEmpty {
                Rectangle().fill(AppColors.border).frame(width: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("回答的来源").font(.system(size: AppFontSizes.sm, weight: .semibold))
                        ForEach(latestSources) { source in
                            VStack(alignment: .leading, spacing: 8) {
                                SourceLink(source: source, store: store)
                                Text(source.quote).font(.system(size: AppFontSizes.xs))
                                    .foregroundStyle(AppColors.textSecondary).lineSpacing(5)
                            }
                        }
                    }.padding(20)
                }.frame(width: 250)
            }
        }
    }
    private func scopeButton(_ scope: String, title: String, recordId: String? = nil) -> some View {
        let isSelected = store.snapshot.ask.scope == scope
            && (scope != "record" || store.snapshot.ask.recordId == recordId)
        return Button {
            store.send(.setAskScope(scope: scope, recordId: recordId))
        } label: {
            Text(title).lineLimit(1).font(.system(size: AppFontSizes.xs))
                .foregroundStyle(isSelected ? AppColors.accent : AppColors.textMuted)
                .padding(.horizontal, 10).frame(minHeight: 30)
                .background(isSelected ? AppColors.accentSoft : AppColors.bgSubtle,
                            in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(store.snapshot.ask.phase == "pending")
    }
    private func messageView(_ message: AskMessageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: message.role == "user" ? "person.crop.circle" : "sparkles")
                Text(message.role == "user" ? "你" : "Koe")
                if message.role != "user", message.mode == "retrieval" {
                    KoeBadge("原文检索", tint: AppColors.textMuted)
                }
            }.font(.system(size: AppFontSizes.xs, weight: .medium)).foregroundStyle(AppColors.textMuted)
            Text(message.text).font(.system(size: AppFontSizes.sm)).lineSpacing(7).textSelection(.enabled)
            ForEach(message.sources) { source in SourceLink(source: source, store: store) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func submit() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, store.snapshot.ask.phase != "pending" else { return }
        store.send(.ask(
            question: question,
            scope: store.snapshot.ask.scope,
            recordId: store.snapshot.ask.recordId
        ))
        if store.snapshot.error == nil && store.nativeError == nil { draft = "" }
    }
}
