import SwiftUI

struct ConsentSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    let request: IncomingRequest

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            PeerAvatar(name: request.peerIdentity.displayName)
                .scaleEffect(1.5)

            VStack(spacing: 8) {
                Text(request.peerIdentity.displayName)
                    .font(.title2.bold())

                Text("wants to connect")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            if let fingerprint = request.peerIdentity.certificateFingerprint {
                VStack(spacing: 4) {
                    Text("Certificate Fingerprint")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(fingerprint.prefix(32) + "...")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    connectionManager.acceptConnection()
                } label: {
                    Text("Accept")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    connectionManager.rejectConnection()
                } label: {
                    Text("Decline")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .presentationDetents([.medium])
    }
}
