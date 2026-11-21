import KoeAppleCore
import SwiftUI

struct IOSCaptureSourceButton: View {
    let store: HostSessionStore
    let title: String
    @State private var showingSources = false

    var body: some View {
        Button {
            showingSources = true
        } label: {
            Label(title, systemImage: "mic")
                .font(.subheadline)
                .multilineTextAlignment(.leading)
        }
        .accessibilityIdentifier("capture-source-picker")
        .accessibilityHint("选择录音输入源")
        .sheet(isPresented: $showingSources) {
            IOSCaptureSourceSheet(store: store)
        }
    }
}

struct IOSCaptureSourceSheet: View {
    let store: HostSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectionError: String?

    private var studio: CaptureStudioSnapshot { store.captureStudio.studio }
    private var effectiveSource: String { studio.activeSource ?? studio.selectedSource }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourceRow("自动优先", key: "auto", selected: studio.selectionMode == "auto")
                    sourceRow("Soundcore Work 录音豆", key: "bean", selected: effectiveSource == "bean")
                    if studio.inputs.isEmpty {
                        sourceRow("系统默认麦克风", key: "system_default", selected: effectiveSource == "system_default")
                    }
                    ForEach(studio.inputs) { input in
                        sourceRow(input.name, key: input.sourceKey,
                                  selected: effectiveSource == input.sourceKey || (effectiveSource == "system_default" && input.isDefault),
                                  detail: input.isDefault ? "\(input.badge)  |  系统默认" : input.badge)
                    }
                } header: {
                    Text("录音输入源")
                } footer: {
                    if store.captureStudio.isRecordingLocked {
                        Text("正在录音，请先结束当前录音再切换输入源。")
                    } else if let selectionError {
                        Text(selectionError).foregroundStyle(IOSColors.danger)
                    }
                }
                Section("本机音频存储") {
                    if let storage = studio.audioStorage {
                        LabeledContent("音频文件", value: "\(storage.fileCount) 个")
                        LabeledContent("占用空间", value: ByteCountFormatter.string(
                            fromByteCount: Int64(clamping: storage.totalBytes), countStyle: .file))
                    } else {
                        Text("暂无音频存储统计").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("录音输入源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func sourceRow(_ title: String, key: String, selected: Bool, detail: String? = nil) -> some View {
        Button {
            selectionError = store.sendReturningError(.selectCaptureSource(source: key))
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(IOSColors.accent)
                }
            }
        }
        .foregroundStyle(.primary)
        .disabled(store.captureStudio.isRecordingLocked)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
