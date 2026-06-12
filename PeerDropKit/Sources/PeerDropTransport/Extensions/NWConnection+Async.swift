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

    /// Wait for the connection to become ready (internal implementation).
    ///
    /// Lost-wakeup guard: `stateUpdateHandler` only fires on state CHANGES —
    /// NWConnection does not replay the current state to a freshly installed
    /// handler. A connection that turned `.ready` before this call (common on
    /// loopback, where start→ready completes in microseconds) would otherwise
    /// hang until the caller's timeout. After installing the handler we check
    /// the current state once; `ResumeOnce` makes handler-vs-check resumption
    /// race-safe.
    private func waitReadyInternal() async throws {
        let resumeOnce = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                resumeOnce.bind(continuation)
                let settle: (NWConnection.State) -> Bool = { state in
                    switch state {
                    case .ready:
                        self.stateUpdateHandler = nil
                        resumeOnce.resume(nil)
                        return true
                    case .failed(let error):
                        self.stateUpdateHandler = nil
                        resumeOnce.resume(error)
                        return true
                    case .cancelled:
                        self.stateUpdateHandler = nil
                        resumeOnce.resume(NWConnectionError.cancelled)
                        return true
                    default:
                        return false
                    }
                }
                stateUpdateHandler = { state in _ = settle(state) }
                // Cover the already-transitioned case the handler will never see.
                _ = settle(state)
            }
        } onCancel: {
            // waitReady's timeout arm cancels this task; without resuming
            // here the continuation leaks and withThrowingTaskGroup waits
            // for this child forever — the timeout path itself deadlocked.
            resumeOnce.resume(CancellationError())
        }
    }

    /// Resumes a continuation at most once, from whichever of three racers
    /// gets there first: the state handler, the current-state check, or the
    /// cancellation handler (which can fire before bind). Double-resume
    /// traps at runtime, so all paths funnel through this gate.
    private final class ResumeOnce {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled: Error??  // .some(nil) success / .some(err) / nil pending

        func bind(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let result = settled {
                lock.unlock()
                if let error = result {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ error: Error?) {
            lock.lock()
            guard settled == nil else {
                lock.unlock()
                return
            }
            settled = .some(error)
            let cont = continuation
            continuation = nil
            lock.unlock()
            guard let cont else { return }
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
            }
        }
    }

    /// Wait for the connection to become ready with a configurable timeout.
    /// - Parameter timeout: Maximum time to wait in seconds (default: 15 seconds).
    /// - Throws: `NWConnectionError.timeout` if the connection doesn't become ready in time.
    public func waitReady(timeout: TimeInterval = 15) async throws {
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
