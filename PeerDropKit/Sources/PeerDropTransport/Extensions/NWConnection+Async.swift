import Foundation
import PeerDropProtocol
import Network

extension NWConnection {
    /// Send a PeerMessage over a framed connection.
    public func sendMessage(_ message: PeerMessage) async throws {
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
    public func receiveMessage(timeout: TimeInterval = 60) async throws -> PeerMessage {
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

    /// Wait for the connection to become ready.
    ///
    /// Polls `state`; it never touches `stateUpdateHandler`. The previous
    /// implementation swapped in its own handler after `start()` (and set it
    /// to nil when done). Measured on loopback (2026-09-27, 600 connections
    /// per variant, serial queues): a handler installed after `start()` was
    /// never invoked for a later `.ready` in 8 of 600 (installed from another
    /// thread) and 36 of 600 (installed on the connection's own queue) cases,
    /// although `state` did reach `.ready` — the dial/accept then stalled
    /// until this timeout. Polling `state` lost 0 of 600, and leaves the
    /// caller's own handler (installed before `start()`, as NWConnection
    /// expects) in place.
    ///
    /// Start the connection on a SERIAL queue. On a concurrent queue
    /// (`.global()`) Network can run the `.preparing` and `.ready` callbacks
    /// concurrently; `state` can then stay `.preparing` forever (8 of 600
    /// loopback server sockets on `.global()`, 0 of 600 on serial queues).
    ///
    /// - Parameter timeout: Maximum time to wait in seconds (default: 15 seconds).
    /// - Throws: the connection's error if it fails, `NWConnectionError.cancelled`
    ///   if it is cancelled, `NWConnectionError.timeout` if it doesn't become
    ///   ready in time, `CancellationError` if the calling task is cancelled.
    public func waitReady(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .ready:
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw NWConnectionError.cancelled
            default:
                break
            }
            guard Date() < deadline else { throw NWConnectionError.timeout }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

public enum NWConnectionError: LocalizedError {
    case timeout
    case noData
    case cancelled
    case unexpectedState

    public var errorDescription: String? {
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
