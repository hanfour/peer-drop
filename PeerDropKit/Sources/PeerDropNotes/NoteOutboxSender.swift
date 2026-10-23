import Foundation
import os

/// What the app currently knows about a contact's notes binding.
public enum OutboxBindingLookup: Equatable {
    case verified(accountId: String, identityKey: Data)
    /// A (re-)exchange is in progress; wait, neither send nor fail.
    case pending
    /// The contact is blocked: nothing may be sent.
    case blocked
    /// No account bound (cleared) or the contact no longer exists.
    case none
}

/// Drains `NoteOutboxStore` through `NotesStore.sendToBound` (design §10.10).
///
/// Duplicate risk (accepted, documented): if the POST reached the server but the
/// response was lost, the client sees a network error, retries, and the
/// recipient may get the note twice. The retry budget (3 attempts / 24 h) keeps
/// this bounded; there is no server-side idempotency key.
@MainActor
public final class NoteOutboxSender {
    public typealias SendFunction = (_ text: String, _ accountId: String, _ expectedIdentityKey: Data) async throws -> NoteRecord

    public static let maxAttempts = 3
    public static let maxAge: TimeInterval = 24 * 3600
    public static let boundCancelledReason = NoteOutboxFailure.bindingCancelled.reasonText

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NoteOutboxSender")

    private let store: NoteOutboxStore
    private let send: SendFunction
    private let binding: (UUID) -> OutboxBindingLookup
    private let baseDelay: TimeInterval
    private let clock: () -> Date
    private let wakeScheduling: Bool
    private let networkSatisfied: () -> Bool
    private let accountReady: () -> Bool

    private var flushing = false
    private var flushRequested = false
    private var wakeTask: Task<Void, Never>?

    public init(store: NoteOutboxStore, send: @escaping SendFunction, binding: @escaping (UUID) -> OutboxBindingLookup,
                baseDelay: TimeInterval = 30, clock: @escaping () -> Date = { Date() }, wakeScheduling: Bool = false,
                networkSatisfied: @escaping () -> Bool = { true },
                accountReady: @escaping () -> Bool = { true }) {
        self.accountReady = accountReady
        self.networkSatisfied = networkSatisfied
        self.store = store; self.send = send; self.binding = binding
        self.baseDelay = baseDelay; self.clock = clock; self.wakeScheduling = wakeScheduling
    }

    public convenience init(store: NoteOutboxStore, notesStore: NotesStore, binding: @escaping (UUID) -> OutboxBindingLookup,
                            baseDelay: TimeInterval = 30, clock: @escaping () -> Date = { Date() }, wakeScheduling: Bool = false,
                            networkSatisfied: @escaping () -> Bool = { true },
                            accountReady: @escaping () -> Bool = { true }) {
        self.init(store: store, send: { [notesStore] text, account, key in
            try await notesStore.sendToBound(text: text, accountId: account, expectedIdentityKey: key)
        }, binding: binding, baseDelay: baseDelay, clock: clock, wakeScheduling: wakeScheduling, networkSatisfied: networkSatisfied, accountReady: accountReady)
    }

    /// Delay after the n-th failed attempt (n >= 1): base, 4x, 16x ...
    func backoff(afterAttempts n: Int) -> TimeInterval { baseDelay * pow(4, Double(max(0, n - 1))) }

    /// Single-flight: a call made while a flush runs asks for one more pass and returns.
    public func flush(now: Date? = nil) async {
        if flushing { flushRequested = true; return }
        flushing = true
        defer { flushing = false }
        repeat {
            flushRequested = false
            await pass(now: now)
        } while flushRequested
        scheduleWake()
    }

    private func pass(now fixedNow: Date?) async {
        store.reloadIfNeeded()
        store.retrySaveIfNeeded()
        guard !store.isLoadFailed else { return }   // outbox unreadable: send nothing, retry load next trigger
        // Already delivered (sentNoteID set) but not yet removed, e.g. a failed removal save: never resend.
        for e in store.all where e.sentNoteID != nil { store.remove(id: e.id) }
        // Snapshot ids: only entries that were queued when the pass started are considered.
        let ids = store.all.filter { $0.state == .queued }.map(\.id)
        for id in ids {
            let now = fixedNow ?? clock()
            guard let entry = store.all.first(where: { $0.id == id }), entry.state == .queued else { continue }

            // Attempts are persisted before the await, so reaching the cap here
            // means earlier launches died mid-send: stop instead of looping.
            if entry.attempts >= Self.maxAttempts {
                store.markFailed(id: id, reason: Self.exhaustedReason(nil)); continue
            }
            if now.timeIntervalSince(entry.createdAt) > Self.maxAge {
                store.markFailed(id: id, reason: NoteOutboxFailure.tooOld.reasonText); continue
            }
            switch binding(entry.contactID) {
            case .pending: continue
            case .none: store.markFailed(id: id, reason: Self.boundCancelledReason); continue
            case .blocked: store.markFailed(id: id, reason: NoteOutboxFailure.blocked.reasonText); continue
            case .verified(let current, let currentKey):
                // Same account with a different key (re-bound after a key change) must not
                // send either: sendToBound would burn one of the recipient's OPKs first.
                if current != entry.accountId || currentKey != entry.expectedIdentityKey {
                    store.markFailed(id: id, reason: Self.boundCancelledReason); continue
                }
            }
            if let next = entry.nextAttemptAt, now < next { continue }

            // Account not ready: wait with NO write (begin/revert would burn an attempt on a kill).
            guard accountReady() else { return }
            let prior = (attempts: entry.attempts, next: entry.nextAttemptAt)
            store.beginAttempt(id: id, nextAttemptAt: now.addingTimeInterval(backoff(afterAttempts: prior.attempts + 1)))
            do {
                let record = try await send(entry.text, entry.accountId, entry.expectedIdentityKey)
                store.markSent(id: id, noteID: record.id)
                store.remove(id: id)
            } catch {
                store.endSending(id: id)
                if error as? NotesStoreError == .noAccount || Self.isCancellation(error) || Task.isCancelled {
                    store.setAttemptState(id: id, attempts: prior.attempts, nextAttemptAt: prior.next)
                    return   // wait: no attempt consumed
                }
                handle(error, entry: entry, prior: prior, now: fixedNow ?? clock())
            }
        }
    }

    private func handle(_ error: Error, entry: NoteOutboxEntry, prior: (attempts: Int, next: Date?), now: Date) {
        if let reason = Self.terminalReason(error) {
            store.setAttemptState(id: entry.id, attempts: prior.attempts, nextAttemptAt: nil)
            store.markFailed(id: entry.id, reason: reason); return
        }
        if Self.isNetworkError(error) && !networkSatisfied() {
            // Offline: the attempt never had a chance; do not burn the budget.
            store.setAttemptState(id: entry.id, attempts: prior.attempts, nextAttemptAt: prior.next)
            return
        }
        let attempts = prior.attempts + 1
        if attempts >= Self.maxAttempts {
            store.markFailed(id: entry.id, reason: Self.exhaustedReason(error))
        } else if now.timeIntervalSince(entry.createdAt) > Self.maxAge {
            store.markFailed(id: entry.id, reason: NoteOutboxFailure.tooOld.reasonText)
        } else {
            store.setAttemptState(id: entry.id, attempts: attempts, nextAttemptAt: now.addingTimeInterval(backoff(afterAttempts: attempts)))
        }
    }

    static func exhaustedReason(_ error: Error?) -> String {
        if (error as? NotesStoreError) == .inboxFull { return NoteOutboxFailure.inboxFull.reasonText }
        return NoteOutboxFailure.exhausted.reasonText
    }

    /// The real NotesStore maps URLError to `.network(String(describing:))`, so a
    /// cancelled request is recognised both structurally and by its description.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        if case .network(let d)? = error as? NotesStoreError {
            return d.contains("Code=-999") || d.contains("CancellationError") || d.contains("NSURLErrorCancelled")
        }
        return false
    }

    static func isNetworkError(_ error: Error) -> Bool {
        if case .network? = error as? NotesStoreError { return true }
        return !(error is NotesStoreError)
    }

    /// Human-readable reason for permanent failures; nil = retryable.
    static func terminalReason(_ error: Error) -> String? {
        guard let e = error as? NotesStoreError else { return nil } // URLError & co: retryable
        switch e {
        case .recipientNotFound: return NoteOutboxFailure.recipientNotFound.reasonText
        case .recipientHasNoKeys: return NoteOutboxFailure.recipientHasNoKeys.reasonText
        case .recipientMismatch: return NoteOutboxFailure.recipientChanged.reasonText
        case .textTooLong: return NoteOutboxFailure.tooLong.reasonText
        case .noteNotFound: return NoteOutboxFailure.noteNotFound.reasonText
        case .noAccount, .network, .rateLimited, .proofOfWorkFailed, .opkExhausted, .inboxFull: return nil // .inboxFull: retryable
        }
    }

    private func scheduleWake() {
        wakeTask?.cancel(); wakeTask = nil
        guard wakeScheduling else { return }
        let now = clock()
        let times = store.all.filter { $0.state == .queued }.compactMap(\.nextAttemptAt).filter { $0 > now }
        guard let earliest = times.min() else { return }
        let delay = earliest.timeIntervalSince(now)
        wakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000) + 100_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func cancelWake() { wakeTask?.cancel(); wakeTask = nil }
}
