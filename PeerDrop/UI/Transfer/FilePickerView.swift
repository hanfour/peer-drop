import SwiftUI
import PeerDropCore
import PeerDropTransport
import UniformTypeIdentifiers

// MARK: - Shared file-processing logic

/// Processes picked URLs (zipping directories as needed) and sends them via connectionManager.
/// Called from both the iOS UIDocumentPickerViewController coordinator and the macOS NSOpenPanel path.
@MainActor
private func processPickedURLs(_ urls: [URL], connectionManager: ConnectionManager) async {
    guard !urls.isEmpty else { return }
    connectionManager.showTransferProgress = true
    connectionManager.transition(to: .transferring(progress: 0))
    do {
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

// MARK: - FilePickerView

#if canImport(UIKit)
import UIKit

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
            Task { @MainActor in
                await processPickedURLs(urls, connectionManager: connectionManager)
            }
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct FilePickerView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        Button("Choose Files…") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowedContentTypes = [.item]
            if panel.runModal() == .OK {
                let urls = panel.urls
                Task { @MainActor in
                    await processPickedURLs(urls, connectionManager: connectionManager)
                }
            }
        }
    }
}
#endif
