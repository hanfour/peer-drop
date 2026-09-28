import Foundation
import PeerDropProtocol
import Network
import ObjectiveC

/// How an outstanding send reacts to its connection's state (#161 I-B).
///
/// - `.failed` / `.cancelled`: terminal.
/// - `.waiting` on a connection that has NEVER been `.ready` (refused, no
///   route): terminal at once — it was never usable.
/// - `.waiting` on a connection that WAS ready (path loss, AP switch) is often
///   transient and recovers, so it is tolerated for `waitingGrace` seconds
///   without the connection being seen `.ready` again. Only `.ready` resets
///   the clock — `.preparing` is not recovery, and resetting on it let a
///   connection cycling `.waiting → .preparing → .waiting` hold a send forever.
/// - Overall cap: a send gives up once the connection has not been `.ready`
///   for `notReadyCap` seconds in total (whatever mix of `.setup` /
///   `.preparing` / `.waiting` it shows), with `NWConnectionError.timeout`.
struct SendStatePolicy {
    static let defaultWaitingGrace: TimeInterval = 10
    static let defaultNotReadyCap: TimeInterval = 30
    let waitingGrace: TimeInterval
    let notReadyCap: TimeInterval
    private(set) var everReady: Bool
    private var waitingSince: Date?
    private var notReadySince: Date?

    init(everReady: Bool,
         waitingGrace: TimeInterval = SendStatePolicy.defaultWaitingGrace,
         notReadyCap: TimeInterval = SendStatePolicy.defaultNotReadyCap) {
        self.everReady = everReady
        self.waitingGrace = waitingGrace
        self.notReadyCap = notReadyCap
    }

    /// The error the send should fail with, or nil to keep waiting.
    mutating func verdict(_ state: NWConnection.State, now: Date = Date()) -> Error? {
        if case .ready = state {
            everReady = true
            waitingSince = nil
            notReadySince = nil
            return nil
        }
        switch state {
        case .failed, .cancelled:
            break
        default:
            let since = notReadySince ?? now
            notReadySince = since
            if now.timeIntervalSince(since) >= notReadyCap {
                return NWConnectionError.timeout
            }
        }
        switch state {
        case .ready, .preparing, .setup:
            return nil
        case .failed(let error):
            return error
        case .cancelled:
            return NWConnectionError.cancelled
        case .waiting(let error):
            guard everReady else { return error }
            guard let since = waitingSince else {
                waitingSince = now
                return nil
            }
            return now.timeIntervalSince(since) >= waitingGrace ? error : nil
        @unknown default:
            return nil
        }
    }
}

/// The send watcher's view of a connection. Production uses the connection
/// itself (see `sendMessage(_:)`); tests inject a scripted state source.
struct SendWatch {
    var state: () -> NWConnection.State
    var everReady: Bool
    var waitingGrace: TimeInterval
    var notReadyCap: TimeInterval = SendStatePolicy.defaultNotReadyCap
    /// Called when the watcher fails a send: makes the failure final so the
    /// abandoned data cannot still go out later.
    var giveUp: () -> Void
    /// Called when the connection is seen `.ready`.
    var markReady: () -> Void
    var pollNanoseconds: UInt64 = 20_000_000
}

/// Per-connection "has been `.ready`" flag, attached to the NWConnection
/// object (so it lives exactly as long as the connection). Set by
/// `waitReady()` and by sends that observe `.ready`.
private final class EverReadyFlag {}
private var everReadyKey: UInt8 = 0

extension NWConnection {
    /// Whether this connection has ever been observed `.ready`.
    var hasBeenReady: Bool {
        if case .ready = state { return true }
        return objc_getAssociatedObject(self, &everReadyKey) != nil
    }

    func markEverReady() {
        objc_setAssociatedObject(self, &everReadyKey, EverReadyFlag(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Send a PeerMessage over a framed connection.
    ///
    /// Bounded by the connection's state (see `SendStatePolicy`): Network
    /// withholds a send's `.contentProcessed` completion while the connection
    /// sits in `.waiting` — until it recovers, or is cancelled (measured
    /// 2026-09-28; see SendMessageBoundTests) — so awaiting the completion
    /// alone could hang a file transfer forever. When the watcher gives up on
    /// a send it also cancels the connection, so the failure is final and no
    /// "failed" chunk/offer can still be delivered later.
    public func sendMessage(_ message: PeerMessage) async throws {
        try await sendMessage(message, watch: SendWatch(
            state: { [weak self] in self?.state ?? .cancelled },
            everReady: hasBeenReady,
            waitingGrace: SendStatePolicy.defaultWaitingGrace,
            giveUp: { [weak self] in self?.cancel() },
            markReady: { [weak self] in self?.markEverReady() }
        ))
    }

    func sendMessage(_ message: PeerMessage, watch: SendWatch) async throws {
        var policy = SendStatePolicy(everReady: watch.everReady, waitingGrace: watch.waitingGrace,
                                     notReadyCap: watch.notReadyCap)
        if let error = policy.verdict(watch.state()) {
            watch.giveUp()
            throw error
        }
        if policy.everReady { watch.markReady() }
        let data = try message.encoded()
        let framerMessage = NWProtocolFramer.Message(peerDropMessageLength: UInt32(data.count))

        let gate = SendGate()
        let watcher = Task { [policy] in
            var policy = policy
            // Most sends complete within a few ms; only a withheld completion
            // keeps this polling.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: watch.pollNanoseconds)
                if Task.isCancelled { return }
                let state = watch.state()
                if case .ready = state { watch.markReady() }
                if let error = policy.verdict(state) {
                    if gate.resume(error) { watch.giveUp() }
                    return
                }
            }
        }
        defer { watcher.cancel() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            gate.bind(continuation)
            send(
                content: data,
                contentContext: NWConnection.ContentContext(
                    identifier: "PeerDropMessage",
                    metadata: [framerMessage]
                ),
                isComplete: true,
                completion: .contentProcessed { error in
                    gate.resume(error)
                }
            )
        }
    }

    /// Resumes a continuation at most once — from the send completion or the
    /// state watcher, whichever comes first (a later call is ignored).
    private final class SendGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled: Error??  // .some(nil) success / .some(err) / nil pending

        func bind(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if let result = settled {
                lock.unlock()
                if let error = result { continuation.resume(throwing: error) } else { continuation.resume() }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        /// Returns whether this call settled the send.
        @discardableResult
        func resume(_ error: Error?) -> Bool {
            lock.lock()
            guard settled == nil else { lock.unlock(); return false }
            settled = .some(error)
            let cont = continuation
            continuation = nil
            lock.unlock()
            if let cont {
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
            return true
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
                markEverReady()
                return
            case .failed(let error):
                throw error
            case .cancelled:
                throw NWConnectionError.cancelled
            default:
                break
            }
            guard Date() < deadline else { throw NWConnectionError.timeout }
            try await Task.sleep(nanoseconds: 20_000_000)
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
