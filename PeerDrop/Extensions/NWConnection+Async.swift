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

    /// Receive a single PeerMessage from a framed connection (internal implementation).
    private func receiveMessageInternal() async throws -> PeerMessage {
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

    /// Receive a single PeerMessage with a configurable timeout.
    /// - Parameter timeout: Maximum time to wait in seconds (default: 60 seconds).
    /// - Throws: `NWConnectionError.timeout` if no message is received in time.
    func receiveMessage(timeout: TimeInterval = 60) async throws -> PeerMessage {
        try await withThrowingTaskGroup(of: PeerMessage.self) { group in
            group.addTask {
                try await self.receiveMessageInternal()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NWConnectionError.timeout
            }
            // Wait for the first task to complete (either message received or timeout)
            guard let result = try await group.next() else {
                throw NWConnectionError.noData
            }
            // Cancel the remaining task
            group.cancelAll()
            return result
        }
    }

    /// Wait for the connection to become ready (internal implementation).
    private func waitReadyInternal() async throws {
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

    /// Wait for the connection to become ready with a configurable timeout.
    /// - Parameter timeout: Maximum time to wait in seconds (default: 15 seconds).
    /// - Throws: `NWConnectionError.timeout` if the connection doesn't become ready in time.
    func waitReady(timeout: TimeInterval = 15) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.waitReadyInternal()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NWConnectionError.timeout
            }
            // Wait for the first task to complete (either ready or timeout)
            try await group.next()
            // Cancel the remaining task
            group.cancelAll()
        }
    }
}

enum NWConnectionError: LocalizedError {
    case timeout
    case noData
    case cancelled
    case unexpectedState

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Connection timed out"
        case .noData:
            return "Connection closed by peer"
        case .cancelled:
            return "Connection was cancelled"
        case .unexpectedState:
            return "Connection entered an unexpected state"
        }
    }
}
