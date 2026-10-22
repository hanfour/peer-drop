import Foundation
import os

/// Phase-0 measurement for the MainActor-offload refactor
/// (docs/plans/2026-08-11-mainactor-offload-design.md).
///
/// Wraps a *synchronous* hot section in an `os_signpost` interval (visible in
/// Instruments → os_signpost, subsystem `com.hanfour.peerdrop`, category
/// `perf`) and accumulates per-path stats, including how much of the time was
/// spent on the main thread. Only wrap synchronous work: timing a section that
/// contains an `await` would count suspension, not CPU.
public enum PerfSignpost {
    public enum Path: String, CaseIterable, Sendable {
        case proofOfWork
        case fileHash
        case fileChunkReceive
        case fileChunkSend
        case messageEncode      // PeerMessage -> JSON (+ secure envelope wrapping)
        case messageDecode      // JSON -> PeerMessage
        case ratchetEncrypt     // LocalSecureChannel.encrypt (stateful, order-critical)
        case ratchetDecrypt     // LocalSecureChannel.decrypt (stateful, order-critical)
        case chatLoad
        case chatPersist
        case chatUpdateStatus
    }

    public struct Stats: Equatable, Sendable {
        public var count = 0
        public var totalSeconds: Double = 0
        public var maxSeconds: Double = 0
        /// Time spent in sections that *started* on the main thread.
        public var mainThreadSeconds: Double = 0
        public var mainThreadCount = 0
    }

    private static let signposter = OSSignposter(subsystem: "com.hanfour.peerdrop", category: "perf")
    private static let lock = NSLock()
    private static var table: [Path: Stats] = [:]

    @discardableResult
    public static func measure<T>(_ path: Path, _ body: () throws -> T) rethrows -> T {
        let onMain = Thread.isMainThread
        let state = signposter.beginInterval("hot-path", id: signposter.makeSignpostID(), "\(path.rawValue, privacy: .public) main=\(onMain)")
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            signposter.endInterval("hot-path", state)
            record(path, seconds: elapsed, onMain: onMain)
        }
        return try body()
    }

    static func record(_ path: Path, seconds: Double, onMain: Bool) {
        lock.lock(); defer { lock.unlock() }
        var s = table[path] ?? Stats()
        s.count += 1
        s.totalSeconds += seconds
        s.maxSeconds = max(s.maxSeconds, seconds)
        if onMain {
            s.mainThreadSeconds += seconds
            s.mainThreadCount += 1
        }
        table[path] = s
    }

    public static func snapshot() -> [Path: Stats] {
        lock.lock(); defer { lock.unlock() }
        return table
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        table.removeAll()
    }

    /// One line per path that has samples; for debug logs and benchmark output.
    public static func report() -> String {
        let snap = snapshot()
        return Path.allCases.compactMap { p in
            guard let s = snap[p] else { return nil }
            return String(format: "%@ n=%d total=%.1fms max=%.1fms main=%.1fms (%d/%d on main)",
                          p.rawValue, s.count, s.totalSeconds * 1000, s.maxSeconds * 1000,
                          s.mainThreadSeconds * 1000, s.mainThreadCount, s.count)
        }.joined(separator: "\n")
    }
}
