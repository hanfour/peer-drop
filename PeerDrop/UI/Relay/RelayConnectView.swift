import SwiftUI
import CoreImage.CIFilterBuiltins

struct RelayConnectView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RelayMode = .choose
    @State private var roomCode = ""
    @State private var generatedCode = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var didAutoJoin = false
    @FocusState private var isCodeFieldFocused: Bool

    enum RelayMode {
        case choose
        case create
        case join
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .choose:
                    chooseView
                case .create:
                    createRoomView
                case .join:
                    joinRoomView
                }
            }
            .navigationTitle("Relay Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 {
                    errorMessage = nil
                    roomCode = ""
                } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
            .onChange(of: connectionManager.state) { newState in
                if case .failed(_) = newState {
                    // Reset to discovering so user can retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        connectionManager.transition(to: .discovering)
                    }
                }
            }
            .onAppear {
                if let code = connectionManager.pendingRelayJoinCode {
                    connectionManager.pendingRelayJoinCode = nil
                    roomCode = code
                    mode = .join
                    didAutoJoin = true
                    joinRoom()
                }
            }
            .sheet(item: $connectionManager.pendingRelayPIN) { request in
                PINVerificationView(pin: request.pin) {
                    connectionManager.confirmRelayPIN()
                    dismiss()
                } onReject: {
                    connectionManager.rejectRelayPIN()
                }
            }
        }
    }

    // MARK: - Choose Mode

    private var chooseView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "antenna.radiowaves.left.and.right.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Relay Connect")
                .font(.title2.bold())

            Text("Connect to devices outside your local network using a relay server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 16) {
                Button {
                    mode = .create
                    createRoom()
                } label: {
                    Label("Create Room", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    mode = .join
                } label: {
                    Label("Join Room", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Create Room

    private var createRoomView: some View {
        VStack(spacing: 24) {
            Spacer()

            if isLoading {
                ProgressView("Creating room...")
            } else if !generatedCode.isEmpty {
                VStack(spacing: 16) {
                    Text("Room Code")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    Text(generatedCode)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .tracking(8)

                    if let qrImage = generateQRCode(from: "peerdrop://relay/\(generatedCode)") {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160, height: 160)
                            .cornerRadius(8)
                    }

                    Text("Share this code or QR with the other device")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    ProgressView("Waiting for peer to join...")
                        .padding(.top)
                }
            }

            Spacer()

            Button("Back") {
                mode = .choose
                generatedCode = ""
            }
            .padding(.bottom)
        }
        .padding()
    }

    // MARK: - Join Room

    private var joinRoomView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Enter Room Code")
                .font(.headline)

            TextField("Room Code", text: $roomCode)
                .font(.system(size: 32, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($isCodeFieldFocused)
                .frame(maxWidth: 240)
                .onAppear { isCodeFieldFocused = true }

            Button {
                joinRoom()
            } label: {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Join")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(roomCode.count < 6 || isLoading)
            .padding(.horizontal, 40)

            Spacer()

            Button("Back") {
                mode = .choose
                roomCode = ""
            }
            .padding(.bottom)
        }
        .padding()
    }

    // MARK: - Actions

    private func createRoom() {
        isLoading = true
        Task {
            do {
                let signaling = WorkerSignaling()
                let roomInfo = try await signaling.createRoom()
                generatedCode = roomInfo.roomCode
                isLoading = false
                connectionManager.startWorkerRelayAsCreator(roomCode: roomInfo.roomCode, roomToken: roomInfo.roomToken, signaling: signaling)
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
                mode = .choose
            }
        }
    }

    private func joinRoom() {
        let code = roomCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 6 else { return }
        isLoading = true
        Task {
            do {
                let signaling = WorkerSignaling()
                try await connectionManager.startWorkerRelayAsJoiner(roomCode: code, signaling: signaling)
                isLoading = false
            } catch {
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - QR Code

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
