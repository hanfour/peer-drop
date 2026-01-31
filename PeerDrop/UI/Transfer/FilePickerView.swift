import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilePickerView: UIViewControllerRepresentable {
    @EnvironmentObject var connectionManager: ConnectionManager

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(connectionManager: connectionManager)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let connectionManager: ConnectionManager

        init(connectionManager: ConnectionManager) {
            self.connectionManager = connectionManager
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            Task { @MainActor in
                connectionManager.showTransferProgress = true
                connectionManager.transition(to: .transferring(progress: 0))
                do {
                    try await connectionManager.fileTransfer?.sendFile(at: url)
                    connectionManager.transition(to: .connected)
                } catch {
                    connectionManager.transition(to: .failed(reason: error.localizedDescription))
                }
                connectionManager.showTransferProgress = false
            }
        }
    }
}
