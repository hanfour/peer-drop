import Foundation
import Network

extension NWConnection {
    /// Send a PeerMessage over a framed connection.
    func sendMessage(_ message: PeerMessage) async throws {
        let data = try message.encoded()
        let framerMessage = NWProtocolFramer.Message(peerDropMessageLength: UInt32(data.count))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(
                content: data,
                contentContext: NWConnection.ContentContext(
                    identifier: "PeerDropMessage",
                    metadata: [framerMessage]
                ),
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    /// Receive a single PeerMessage from a framed connection.
    func receiveMessage() async throws -> PeerMessage {
        try await withCheckedThrowingContinuation { continuation in
            receiveMessage { content, context, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let content else {
                    continuation.resume(throwing: NWConnectionError.noData)
                    return
                }
                do {
                    let message = try PeerMessage.decoded(from: content)
                    continuation.resume(returning: message)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Wait for the connection to become ready.
    func waitReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.stateUpdateHandler = nil
                    continuation.resume(throwing: NWConnectionError.cancelled)
                default:
                    break
                }
            }
        }
    }
}

enum NWConnectionError: LocalizedError {
    case noData
    case cancelled
    case unexpectedState

    var errorDescription: String? {
        switch self {
        case .noData:
            return "Connection closed by peer"
        case .cancelled:
            return "Connection was cancelled"
        case .unexpectedState:
            return "Connection entered an unexpected state"
        }
    }
}
