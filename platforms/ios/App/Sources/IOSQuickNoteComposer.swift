import KoeAppleCore
import SwiftUI

struct IOSQuickNoteComposer: View {
    let store: HostSessionStore
    @State private var quickNoteDraft = ""
    @FocusState private var isQuickNoteFocused: Bool

    var body: some View {
        IOSCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal")
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.accent)
                    Text("快速文字闪记")
                        .font(.system(size: AppFontSizes.sm, weight: .semibold))
                        .foregroundStyle(IOSColors.textPrimary)
                    Spacer()
                    IOSInfoTip(
                        "输入文字后按回车或点击保存闪记，将直接写入本地 Rust 工作区。",
                        title: "文字闪记"
                    )
                }

                HStack(spacing: 8) {
                    TextField("快速记下一段想法…", text: $quickNoteDraft)
                        .font(.system(size: AppFontSizes.sm))
                        .foregroundStyle(IOSColors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(IOSColors.bgSubtle, in: RoundedRectangle(cornerRadius: IOSRadii.control))
                        .overlay(
                            RoundedRectangle(cornerRadius: IOSRadii.control)
                                .stroke(IOSColors.border, lineWidth: 1)
                        )
                        .submitLabel(.done)
                        .focused($isQuickNoteFocused)
                        .accessibilityIdentifier("quick-note-input")
                        .onSubmit {
                            submitQuickNote()
                        }

                    IOSPrimaryButton("保存闪记", isPrimary: true) {
                        submitQuickNote()
                    }
                    .disabled(quickNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("quick-note-submit")
                }
            }
        }
    }

    private func submitQuickNote() {
        isQuickNoteFocused = false
        IOSTodayView.submitQuickNote(draft: &quickNoteDraft, store: store)
    }

}
