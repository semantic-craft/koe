import KoeAppleCore
import SwiftUI

struct IOSAskComposer: View {
    let store: HostSessionStore
    @Binding var questionDraft: String
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("问问你记下来的事…", text: $questionDraft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: AppFontSizes.sm))
                .foregroundStyle(IOSColors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(IOSColors.surface1, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                .overlay(
                    RoundedRectangle(cornerRadius: IOSRadii.control)
                        .stroke(IOSColors.border, lineWidth: 1)
                )
                .focused($isQuestionFocused)
                .onSubmit(submitQuestion)
                .accessibilityIdentifier("ask-question-input")
                .toolbar {
                    if isQuestionFocused {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("收起键盘") { isQuestionFocused = false }
                                .accessibilityIdentifier("ask-dismiss-keyboard")
                        }
                    }
                }

            IOSPrimaryButton("发送", systemImage: "arrow.up", minimumHeight: 44) {
                submitQuestion()
            }
            .disabled(questionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.ask.phase == "pending")
            .accessibilityIdentifier("ask-question-submit")
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

    private func submitQuestion() {
        let trimmed = questionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let ask = store.ask
        guard !trimmed.isEmpty, ask.phase != "pending" else { return }
        if store.sendReturningError(.ask(question: trimmed, scope: ask.scope, recordId: ask.recordId)) == nil {
            isQuestionFocused = false
            questionDraft = ""
        }
    }
}
