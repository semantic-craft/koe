import SwiftUI
import UIKit

struct IOSFileExportPresentation: ViewModifier {
    let actions: IOSFileActions

    func body(content: Content) -> some View {
        let urls = actions.exportURLs
        let presented = Binding(
            get: { !urls.isEmpty },
            set: { if !$0 { actions.finishExport() } }
        )
        content.sheet(isPresented: presented) {
            IOSFilePicker(urls: urls, onFinish: actions.finishExport(delivered:))
        }
    }
}

private struct IOSFilePicker: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void

        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish(false)
        }
    }
}
