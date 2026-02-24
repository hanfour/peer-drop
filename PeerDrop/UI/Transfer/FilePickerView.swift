import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilePickerView: UIViewControllerRepresentable {
    @EnvironmentObject var connectionManager: ConnectionManager

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
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
            guard !urls.isEmpty else { return }

            Task { @MainActor in
                connectionManager.showTransferProgress = true
                connectionManager.transition(to: .transferring(progress: 0))
                do {
                    // Process URLs - zip directories if needed
                    var processedURLs: [URL] = []

                    var directoryFlags: [URL: Bool] = [:]

                    for url in urls {
                        guard url.startAccessingSecurityScopedResource() else { continue }
                        defer { url.stopAccessingSecurityScopedResource() }

                        if url.hasDirectoryPath {
                            let zippedURL = try await url.zipDirectory()
                            processedURLs.append(zippedURL)
                            directoryFlags[zippedURL] = true
                        } else {
                            processedURLs.append(url)
                            directoryFlags[url] = false
                        }
                    }

                    try await connectionManager.fileTransfer?.sendFiles(at: processedURLs, directoryFlags: directoryFlags)
                    connectionManager.transition(to: .connected)
                } catch {
                    connectionManager.transition(to: .failed(reason: error.localizedDescription))
                }
                connectionManager.showTransferProgress = false
            }
        }
    }
}
