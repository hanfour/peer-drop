import Foundation
import os

/// What the app currently knows about a contact's notes binding.
public enum OutboxBindingLookup: Equatable {
    case verified(accountId: String)
    /// A (re-)exchange is in progress; wait, neither send nor fail.
    case pending
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
    public static let boundCancelledReason = "綁定已取消"

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "NoteOutboxSender")

    private let store: NoteOutboxStore
    private let send: SendFunction
    private let binding: (UUID) -> OutboxBindingLookup
    private let baseDelay: TimeInterval
    private let clock: () -> Date
    private let wakeScheduling: Bool

    private var flushing = false
    private var flushRequested = false
    private var wakeTask: Task<Void, Never>?

    public init(store: NoteOutboxStore, send: @escaping SendFunction, binding: @escaping (UUID) -> OutboxBindingLookup,
                baseDelay: TimeInterval = 30, clock: @escaping () -> Date = { Date() }, wakeScheduling: Bool = false) {
        self.store = store; self.send = send; self.binding = binding
        self.baseDelay = baseDelay; self.clock = clock; self.wakeScheduling = wakeScheduling
    }

    public convenience init(store: NoteOutboxStore, notesStore: NotesStore, binding: @escaping (UUID) -> OutboxBindingLookup,
                            baseDelay: TimeInterval = 30, clock: @escaping () -> Date = { Date() }, wakeScheduling: Bool = false) {
        self.init(store: store, send: { [notesStore] text, account, key in
            try await notesStore.sendToBound(text: text, accountId: account, expectedIdentityKey: key)
        }, binding: binding, baseDelay: baseDelay, clock: clock, wakeScheduling: wakeScheduling)
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
        // Snapshot ids: only entries that were queued when the pass started are considered.
        let ids = store.all.filter { $0.state == .queued }.map(\.id)
        for id in ids {
            let now = fixedNow ?? clock()
            guard let entry = store.all.first(where: { $0.id == id }), entry.state == .queued else { continue }

            if now.timeIntervalSince(entry.createdAt) > Self.maxAge {
                store.markFailed(id: id, reason: "超過 24 小時仍未寄出"); continue
            }
            switch binding(entry.contactID) {
            case .pending: continue
            case .none: store.markFailed(id: id, reason: Self.boundCancelledReason); continue
            case .verified(let current):
                if current != entry.accountId { store.markFailed(id: id, reason: Self.boundCancelledReason); continue }
            }
            if let next = entry.nextAttemptAt, now < next { continue }

            do {
                _ = try await send(entry.text, entry.accountId, entry.expectedIdentityKey)
                store.remove(id: id)
            } catch NotesStoreError.noAccount {
                return // account not ready: wait, no attempt consumed; all other entries would hit the same
            } catch is CancellationError {
                return
            } catch {
                handle(error, entry: entry, now: fixedNow ?? clock())
            }
        }
    }

    private func handle(_ error: Error, entry: NoteOutboxEntry, now: Date) {
        if let reason = Self.terminalReason(error) {
            store.markFailed(id: entry.id, reason: reason); return
        }
        let attempts = entry.attempts + 1
        if attempts >= Self.maxAttempts {
            store.recordAttempt(id: entry.id, nextAttemptAt: nil) // keep the count honest for the UI
            store.markFailed(id: entry.id, reason: "多次嘗試後仍無法寄出，請稍後重試")
        } else if now.timeIntervalSince(entry.createdAt) > Self.maxAge {
            store.markFailed(id: entry.id, reason: "超過 24 小時仍未寄出")
        } else {
            store.recordAttempt(id: entry.id, nextAttemptAt: now.addingTimeInterval(backoff(afterAttempts: attempts)))
        }
    }

    /// Human-readable reason for permanent failures; nil = retryable.
    static func terminalReason(_ error: Error) -> String? {
        guard let e = error as? NotesStoreError else { return nil } // URLError & co: retryable
        switch e {
        case .recipientNotFound: return "找不到對方的紙條帳號"
        case .recipientHasNoKeys: return "對方尚未準備好接收紙條"
        case .recipientMismatch: return "對方的帳號或金鑰已變更，請重新交換紙條帳號後再試"
        case .textTooLong: return "紙條太長"
        case .noteNotFound: return "紙條不存在"
        case .noAccount, .network, .rateLimited, .proofOfWorkFailed, .opkExhausted, .inboxFull: return nil
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
